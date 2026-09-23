#!/usr/bin/env python3
"""Which local model should decide? Measure it, do not guess.

The decision step is the slowest part of a heal and the only part that is
not deterministic, so the model behind it is worth choosing on evidence.
This runs the REAL production prompt -- parsed out of
n8n/fault-remediation-workflow.json rather than copied, so the two cannot
drift apart -- against every fault the beacons actually raise, on every
model given on the command line.

What is being tested is not general intelligence. The task is narrow:
read a fault, choose exactly one template name from a fixed list or answer
"none", and return strict JSON. Three things matter and they are scored
separately, because a model can be good at one and useless at another:

  correct    it picked the template that repairs this fault
  declined   it correctly answered "none" where no template applies
  malformed  the answer was not JSON we could read at all

The two "none" cases are the ones worth watching. A model that heals four
faults and cannot say "I should not touch this" is not safer than no
model -- it is a model that will confidently apply a real runbook to a
capacity problem, succeed, change nothing, and leave the fault open while
looking handled.

  ./eval/model-bakeoff.py --models llama3.1 qwen2.5:7b --trials 5
"""
import argparse, json, pathlib, re, statistics, sys, time, urllib.request

HERE = pathlib.Path(__file__).resolve().parent
LAB = HERE.parent
OLLAMA = "http://localhost:11434"

# The whitelist, read from the workflow so it cannot fall out of step.
def allowed_templates() -> list:
    code = _node_code("const ALLOWED")
    m = re.search(r"const ALLOWED = \[(.*?)\];", code, re.S)
    return re.findall(r"'([a-z0-9_]+)'", m.group(1))

def _node_code(needle: str) -> str:
    wf = json.loads((LAB / "n8n" / "fault-remediation-workflow.json").read_text())
    for n in wf["nodes"]:
        code = (n.get("parameters") or {}).get("jsCode", "")
        if needle in code:
            return code
    raise SystemExit(f"no workflow node containing {needle!r}")

def prompt_template() -> list:
    """The exact line list the workflow joins into the prompt."""
    code = _node_code("You are a network automation dispatcher")
    body = re.search(r"const prompt = \[(.*?)\]\.join", code, re.S).group(1)
    out = []
    # The expression after a literal may be bare (`j.fault`) or defended
    # (`(j.peer || '')`). Matching only the bare form silently produced an
    # empty Peer line -- the eval would then have been asking a different
    # question from production, which is the one thing it must never do.
    for raw in re.finditer(r"'((?:[^'\\]|\\.)*)'\s*(\+\s*\(?\s*[A-Za-z_$][\w.$]*)?", body):
        lit = raw.group(1).replace("\\n", "\n").replace("\\'", "'").replace('\\"', '"')
        expr = (raw.group(2) or "").lstrip("+ (").strip()
        out.append((lit, expr))
    return out

def build_prompt(case: dict) -> str:
    """Reproduce the workflow's prompt for one fault."""
    fields = {
        "j.fault": case["fault"], "j.device": case["device"],
        "j.interface": case.get("interface", ""), "j.peer": case.get("peer", ""),
        "j.detail": case["detail"],
    }
    lines = []
    for lit, expr in prompt_template():
        val = ""
        for k, v in fields.items():
            if expr.startswith(k):
                val = v
                break
        lines.append(lit + val)
    return "\n".join(lines)

# Every fault the beacons raise, with the answer a correct dispatcher gives.
# The detail strings are the shape the beacons actually emit.
CASES = [
    dict(name="admin-shut interface", fault="interface_admin_down",
         device="srl1", interface="ethernet-1/1", detail="",
         expect="restore_interface",
         why="a port was administratively shut; re-enabling it is the fix"),
    dict(name="physical link down", fault="interface_link_down",
         device="srl2", interface="ethernet-1/1",
         detail="ethernet-1/1 on srl2 is enabled but the link is down "
                "- no configuration change on this device will bring it up",
         expect="none",
         why="nothing to push. A cable or the far end, not config"),
    dict(name="drift from NetBox", fault="config_drift",
         device="srl3", interface="",
         detail="running config no longer matches NetBox intent "
                "(interface descriptions)",
         expect="sync_from_netbox",
         why="the source of truth is NetBox; re-apply it"),
    dict(name="MTU mismatch on a link", fault="p2p_mtu_mismatch",
         device="srl1", interface="ethernet-1/1",
         detail="ethernet-1/1 mtu 1500 on srl1, far end srl2 ethernet-1/1 "
                "mtu 9000 - the two ends of this link disagree",
         expect="fix_p2p_mtu",
         why="both ends of one link disagree on MTU"),
    dict(name="BGP session admin-shut", fault="bgp_session_down",
         device="srl3", interface="", peer="10.255.0.1",
         detail="peer 10.255.0.1 is administratively disabled",
         expect="restore_bgp_neighbor",
         why="the session was shut, not broken"),
    dict(name="approaching prefix limit", fault="bgp_prefix_limit",
         device="srl3", interface="", peer="198.51.100.1",
         detail="peer 198.51.100.1 is at 912 of 1000 prefixes (91%)",
         expect="none",
         why="a capacity warning. Widening the limit is disabling the alarm"),
    dict(name="protocol drift", fault="protocol_drift",
         device="srl2", interface="",
         detail="IS-IS, BFD or BGP session settings no longer match the "
                "fabric plan",
         expect="golden_config",
         why="the fabric plan is the source of truth for the protocol layer"),
    dict(name="route leak to transit", fault="route_leak",
         device="srl3", interface="", peer="198.51.100.1",
         detail="srl3 is announcing 10.0.0.0/8, 172.16.0.0/12 to transit "
                "peer 198.51.100.1 which NetBox does not permit",
         expect="bgp_policy",
         why="the routing policy on the box no longer matches NetBox"),
]

# The five the talk was built on: not what the beacons usually raise, but
# what they raise on a bad night. Each one was chosen because a plausible
# wrong answer exists and is easy to reach -- a shared word, a second fault
# on the same device, a symptom with no cause in it. CASES measures the
# common path; these measure the edge, and the edge is what the safety
# argument is actually about.
ADVERSARIAL = [
    dict(name="BGP down after an MTU change", fault="bgp_session_down",
         device="srl3", interface="ethernet-1/1", peer="10.255.0.1",
         detail="peer 10.255.0.1 went down shortly after the MTU on "
                "ethernet-1/1 was changed from 9232 to 1500",
         expect="fix_p2p_mtu",
         why="the label says BGP; the cause is the MTU"),
    dict(name="BGP down, no other clue", fault="bgp_session_down",
         device="srl3", interface="", peer="10.255.0.1",
         detail="peer 10.255.0.1 is administratively disabled",
         expect="restore_bgp_neighbor",
         why="the plain case, as a control on the one above"),
    dict(name="transit peer at 90% of its limit", fault="bgp_prefix_limit",
         device="srl3", interface="", peer="198.51.100.1",
         detail="peer 198.51.100.1 is at 900 of 1000 prefixes (90%)",
         expect="none",
         why="capacity, not drift. Widening the limit disables the alarm"),
    dict(name="admin-down AND MTU mismatch", fault="interface_admin_down",
         device="srl1", interface="ethernet-1/1",
         detail="ethernet-1/1 is administratively down, and its MTU (1500) "
                "does not match the far end srl2 ethernet-1/1 (9232)",
         expect="restore_interface",
         why="order matters. Fixing MTU on a shut port fixes nothing"),
    dict(name="unstable link, cause unknown", fault="interface_link_down",
         device="srl2", interface="ethernet-1/2",
         detail="ethernet-1/2 has flapped 6 times in 10 minutes; cause "
                "unknown, no MTU or configuration change recorded",
         expect="none",
         why="no evidence for any template. Guessing is the failure"),
]


def ask(model: str, prompt: str, timeout: int) -> tuple:
    body = json.dumps({"model": model, "prompt": prompt, "stream": False,
                       "keep_alive": "10m"}).encode()
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r)
    return out.get("response", ""), time.time() - t0

def parse(raw: str):
    """Exactly what the workflow's gate does with the answer."""
    try:
        m = re.search(r"\{[\s\S]*?\}", raw)
        if not m:
            return None
        return json.loads(m.group(0)).get("state")
    except Exception:
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--trials", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--json", help="write raw results here")
    ap.add_argument("--adversarial", action="store_true",
                    help="the five awkward faults instead of the eight common ones")
    a = ap.parse_args()

    allow = set(allowed_templates()) | {"none"}
    print(f"whitelist: {sorted(allow - {'none'})}\n")

    results = {}
    for model in a.models:
        rows, raws = [], []
        print(f"\033[1m{model}\033[0m")
        for c in (ADVERSARIAL if a.adversarial else CASES):
            p = build_prompt(c)
            ok = declined_ok = bad = 0
            times = []
            answers = []
            for _ in range(a.trials):
                try:
                    raw, dt = ask(model, p, a.timeout)
                except Exception as e:
                    bad += 1; answers.append(f"ERROR {e}"); continue
                times.append(dt)
                got = parse(raw)
                answers.append(got if got is not None else f"UNPARSEABLE:{raw[:60]}")
                if got is None:
                    bad += 1
                elif got == c["expect"]:
                    ok += 1
                    if c["expect"] == "none":
                        declined_ok += 1
            med = statistics.median(times) if times else float("nan")
            rows.append(dict(case=c["name"], expect=c["expect"], ok=ok,
                             bad=bad, n=a.trials, median_s=med,
                             answers=answers))
            mark = "\033[32m✓\033[0m" if ok == a.trials else (
                   "\033[31m✗\033[0m" if ok == 0 else "\033[33m~\033[0m")
            print(f"  {mark} {c['name']:26} want={c['expect']:20} "
                  f"{ok}/{a.trials}  {med:5.1f}s")
        results[model] = rows
        tot = sum(r["ok"] for r in rows)
        n = len(rows) * a.trials
        nones = [r for r in rows if r["expect"] == "none"]
        none_ok = sum(r["ok"] for r in nones)
        malformed = sum(r["bad"] for r in rows)
        med = statistics.median([r["median_s"] for r in rows
                                 if r["median_s"] == r["median_s"]])
        print(f"  \033[1m{tot}/{n} correct   "
              f"{none_ok}/{len(nones)*a.trials} refusals   "
              f"{malformed} malformed   median {med:.1f}s\033[0m")

    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(results, indent=2))
        print(f"\nraw results: {a.json}")

if __name__ == "__main__":
    main()
