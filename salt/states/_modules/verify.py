"""Did the change achieve what it was for?

Idempotence is convergence, not correctness. A state that reliably drives a
device to the same configuration proves only that the configuration is what
the template says -- it says nothing about whether that was the right thing
to want. Re-applying a wrong-but-idempotent state confidently, across a
fleet, is a good way to break a network at scale.

So every remediation declares a check on the *outcome* it exists to
produce, separate from the configuration it writes:

    restore_interface     -> the interface is operationally up
    fix_p2p_mtu           -> the IS-IS adjacency over that link is up
    restore_bgp_neighbor  -> the session is established

Configuration convergence is checked by the template. These check the
network. They are deliberately about operational state, which a template
cannot assert and a diff cannot show: an interface can be admin-enabled and
still down, an MTU can match on both ends and the adjacency still not form.

What makes this more than logging is what audited.config does with the
answer. An automated change is committed with the *device's own* revert
timer armed, and confirmed only if the check passes. A change that does not
produce the outcome it was for is not kept -- the router rolls it back on
its own clock, with no help from Salt, the master, or the network path
between them.
"""

import logging
import time

log = logging.getLogger(__name__)

__virtualname__ = "verify"

# Protocols need a moment. IS-IS hellos are every 9 seconds by default and
# BGP takes longer than that to leave Connect, so checking immediately after
# a commit reliably reports failure for a change that was fine.
DEFAULT_TIMEOUT = 45
DEFAULT_INTERVAL = 5


def __virtual__():
    return __virtualname__


def _poll(check, timeout, interval):
    """Run check() until it returns a truthy (ok, detail) or time runs out."""
    deadline = time.time() + int(timeout)
    detail = "not checked"
    while True:
        try:
            ok, detail = check()
            if ok:
                return {"verified": True, "detail": detail,
                        "waited_s": int(timeout) - int(deadline - time.time())}
        except Exception as err:  # noqa: BLE001 - a failed poll is not a verdict
            detail = f"{type(err).__name__}: {err}"
        if time.time() >= deadline:
            return {"verified": False, "detail": detail, "waited_s": int(timeout)}
        time.sleep(int(interval))


def interface_up(name, timeout=DEFAULT_TIMEOUT, interval=DEFAULT_INTERVAL):
    """Is the interface operationally up, not merely admin-enabled?"""
    def check():
        ifaces = (__salt__["net.interfaces"]() or {}).get("out", {})
        data = ifaces.get(name)
        if not data:
            return False, f"{name} is not present in net.interfaces"
        if not data.get("is_enabled", False):
            return False, f"{name} is still administratively down"
        if not data.get("is_up", False):
            return False, f"{name} is admin-enabled but operationally down"
        return True, f"{name} is up"
    return _poll(check, timeout, interval)


def bgp_established(peer, timeout=90, interval=DEFAULT_INTERVAL):
    """Has the session actually come up, rather than merely been un-shut?"""
    def check():
        out = (__salt__["bgp.neighbors"]() or {}).get("out", {})
        for by_as in out.values():
            for peers in (by_as or {}).values():
                for p in peers or []:
                    if p.get("remote_address") != peer:
                        continue
                    state = p.get("connection_state", "unknown")
                    if p.get("up") and state == "established":
                        return True, f"session to {peer} is established"
                    return False, f"session to {peer} is {state}"
        return False, f"no session to {peer} is present at all"
    return _poll(check, timeout, interval)


def isis_adjacency_up(interface, timeout=60, interval=DEFAULT_INTERVAL):
    """Did the adjacency form over this link?

    The point of fixing a P2P MTU mismatch is not a matching MTU: it is an
    adjacency that forms. With hello padding on, the MTUs can be made to
    agree and the adjacency can still stay down for an unrelated reason, and
    a config-only check would call that a success.
    """
    def check():
        res = __salt__["net.cli"](
            "show network-instance default protocols isis adjacency")
        text = ""
        if isinstance(res, dict):
            out = res.get("out") or {}
            text = "\n".join(str(v) for v in out.values()) if isinstance(out, dict) else str(out)
        want = interface.split(".")[0]
        for name, state in _adjacencies(text):
            if name == want and state == "up":
                return True, f"adjacency on {interface} is up"
        return False, f"no up adjacency on {interface}"
    return _poll(check, timeout, interval)


def _adjacencies(text):
    """(interface, state) per adjacency row, matched as whole fields.

    Whole fields, not a substring test: "ethernet-1/1" is a substring of
    "ethernet-1/10", so on a device with ten or more ports in a slot an
    adjacency up on one would satisfy a change made to the other. Satisfying
    the check is what cancels the revert timer, so the wrong link's health
    would make the wrong change permanent.

    SR Linux prints the table pipe-delimited:
        | ethernet-1/1 | 1 | srl2 | ... | up | ...
    """
    for line in text.splitlines():
        if "|" not in line:
            continue
        cells = [c.strip() for c in line.split("|") if c.strip()]
        if not cells or not cells[0].startswith("ethernet"):
            continue
        state = next((c.lower() for c in cells[1:] if c.lower() in ("up", "down")), "")
        yield cells[0], state


def isis_adjacencies(expected, timeout=90, interval=DEFAULT_INTERVAL):
    """Does this device still have every IS-IS adjacency it should?

    The device-wide counterpart to isis_adjacency_up, for golden_config --
    which pushes the whole protocol layer (IS-IS, BFD, iBGP) and therefore
    has the whole protocol layer as its outcome. Checking that the config
    converged proves nothing here: the risk of pushing protocol config is
    precisely that it converges and the adjacencies drop.

    `expected` comes from pillar (topology:isis_adjacencies), never from
    the caller, so a remediation cannot lower the bar it is judged against.
    """
    want = int(expected)

    def check():
        res = __salt__["net.cli"](
            "show network-instance default protocols isis adjacency")
        text = ""
        if isinstance(res, dict):
            out = res.get("out") or {}
            text = "\n".join(str(v) for v in out.values()) if isinstance(out, dict) else str(out)
        up = [n for n, st in _adjacencies(text) if st == "up"]
        if len(up) >= want:
            return True, f"{len(up)} of {want} IS-IS adjacencies up ({', '.join(sorted(up))})"
        return False, (f"only {len(up)} of {want} IS-IS adjacencies up"
                       + (f" ({', '.join(sorted(up))})" if up else ""))
    return _poll(check, timeout, interval)


def advertises_only(peer, permitted, timeout=60, interval=DEFAULT_INTERVAL):
    """Check that this router announces to `peer` only what it is allowed to.

    The outcome check for a route leak. Re-applying the export policy proves
    the policy converged; it does not prove the announcements stopped --
    BGP has to re-run the policy over the adj-rib-out and withdraw, which
    takes a moment and can fail to happen at all if the policy was correct
    and something else was leaking.

    So this reads the post-policy adj-rib-out, the same place the beacon
    read, and waits for the extra prefixes to be gone.
    """
    allowed = set(permitted or [])

    def check():
        advertised = __salt__["srlstate.advertised_to"](peer)
        if advertised is None:
            return False, "could not read the adj-rib-out"
        extra = [p for p in advertised if p not in allowed]
        if extra:
            return False, (f"still advertising {len(extra)} prefix(es) to "
                           f"{peer} that are not permitted: "
                           f"{', '.join(extra[:5])}")
        return True, (f"{peer} is being offered only "
                      f"{', '.join(sorted(allowed)) or 'nothing'}")

    return _poll(check, timeout, interval)
