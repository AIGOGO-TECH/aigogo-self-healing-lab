# What broke on the way to P1, and why

Real failures hit while bringing up containerlab + SR Linux + Salt + NAPALM
on Apple Silicon. Each one is left pinned/patched in place rather than
hidden, because at MNNOG the point of this repo is "run it yourself and see
what a 2025 automation stack looks like in 2026."

## 1. SR Linux v26.7.2 crashes on arm64
`net_inst_mgr` (the process that owns network-instances, i.e. the mgmt VRF
that JSON-RPC listens on) segfaults on container start:
```
error 'File exists (17)' ns srbase-mgmt "creating veth "gway-1", "gateway" pair!"
```
Confirmed as a version regression, not a Docker Desktop issue: 24.10.1 boots
clean on the same host. Pinned in `clab/topo.yml`.

## 2. containerlab's default mgmt subnet collides with an existing project
containerlab wants `172.20.20.0/24` for its management network. This host
already runs AIGOGO's stacks on 172.17-172.22. Pinned to `172.30.30.0/24`
in `clab/topo.yml`.

## 3. `pip install salt` fails on `python:3.12-slim`
Salt pulls in C extensions (e.g. `timelib`) that need a compiler; `-slim`
has none. Fixed by installing `build-essential`/`python3-dev` for the
install step and removing them afterward (`salt/Dockerfile`).

## 4. Salt 3008 externalized NAPALM support
`napalm.init` proxymodule doesn't exist in Salt core any more — it moved to
the separate `saltext.napalm` package. Without it, salt-proxy aborts with
`Proxymodule napalm could not be loaded`.

## 5. `salt.utils.platform.is_proxy()` misfires under Salt 3008 + Python 3.12
This is the one that cost the most time. `is_proxy()` is:
```python
if "proxy" in main.__file__ or any(a.startswith("--proxyid") for a in sys.argv):
```
When `__main__` has no `__file__` at the point some loader contexts call
this, the left operand raises `AttributeError` — and because Python
evaluates `or` left-to-right, the exception fires before the (working)
`--proxyid` check on the right ever runs. The whole expression aborts to
`False`, `saltext.napalm` concludes NAPALM "is not installed", and the
proxy exits — even though `napalm` imports fine and the driver is present.

Confirmed by instrumenting the real function at its actual call site: the
argv check alone is reliable, the `__main__.__file__` probe is not, in this
environment. Fixed by replacing `saltext.napalm.utils.napalm.is_proxy`
outright (`salt/patches/sitecustomize.py`) with the one fact that actually
matters for this image, which only ever runs as a proxy minion:
```python
def is_proxy(opts):
    return opts.get("proxy", {}).get("proxytype") == "napalm"
```

## 6. Pillar's `proxy:` key does not merge into `opts['proxy']` in time
The standard NAPALM-proxy pattern (used by most tutorials, ourselves
included at first) puts the full proxy dict — driver, host, credentials —
in pillar, keyed per device. On Salt 3008 in this setup, the first device
connection attempt (`get_device_opts`) reads `opts['proxy']` before
pillar's version has merged in, so it sees only what's in the *local*
minion config and NAPALM fails with `Please provide a valid driver name`.

Fixed by moving the full proxy config (host, driver, credentials) into each
proxy's own local `/etc/salt/proxy-<id>` file. This is also, incidentally,
the opposite of what the original ISP did — their pillar held real device
IPs and a plaintext password (see the MNNOG slides) precisely because that
tutorial pattern is what's written down everywhere. It works right up until
a Salt upgrade changes pillar timing under you, silently.

## 7. Full stack barely fits in Docker's default 8GB

With all 11 containers up (2 SR Linux + salt plane + ES + Kibana + Grafana
+ NetBox/postgres/redis), available memory settles around 700-1050MB out
of Docker Desktop's default 8GB allocation. Kibana alone uses ~1.1-1.2GB.
No OOM kills observed yet, but there is no real margin left — P4 (reactor/
beacon activity) and P5 (n8n) will need more room.

**Before continuing to P4:** bump Docker Desktop's memory limit to 12GB+
(Settings → Resources → Memory). This requires a Docker Desktop restart,
which briefly stops every other container on this host, including AIGOGO's
— do this at a moment that's fine to interrupt those.

## 8. `pillar.get` masks its own return value by default

`salt.modules.pillar.get()` has an `unmask` parameter, default `False`. Any
value under a key Salt considers sensitive-looking (confirmed: `token`,
`url` — broader than just credentials) comes back as the literal string
`"**********"` even when called programmatically from a beacon or module,
not just in CLI display. The custom `config_drift` beacon hit this:
`__salt__["pillar.get"]("netbox", {})` returned a masked URL, so
`http.query` failed with "Unsupported url scheme". Fixed by passing
`unmask=True`. Oddly, Jinja's `salt['pillar.get'](...)` inside a state SLS
does *not* apply the same masking — `sync_from_netbox.sls` never needed it.

## 9. `net.load_template(test=True)` already diffs and discards — don't call `compare_config` after it

`test=True` makes `load_template`/`load_config` load the candidate, diff it
against running, discard it, and return the diff directly under the
`diff` key of its own return value — all in one call. A separate
`net.compare_config()` call afterward finds nothing, because by then there
is no pending candidate left to compare. The `config_drift` beacon
originally called both and always saw an empty diff; fixed by reading
`result["diff"]` from `load_template`'s return instead.

## 10. Reactor tag globs must match the *whole* event tag

`salt/beacon/*/config_drift/` (no trailing wildcard) does not match
`salt/beacon/srl1/config_drift/drift` — Salt's reactor tag matching needs
the pattern to cover the entire tag string. Fixed to
`salt/beacon/*/config_drift/drift`, matching only the drift sub-tag (not
`/error`, so a NetBox outage doesn't trigger a state.apply storm).

## 11. (minor, unresolved) ES dynamic mapping conflict on `data.fun_args`

Once `state.apply` runs, some fired events carry `fun_args` as a plain
string, others as a structured object (e.g. `{pretty=true}` from a nested
call). Elasticsearch's dynamic mapping locks the field type from whichever
shape it sees first, then rejects (`400 document_parsing_exception`) any
later event with a different shape. Doesn't affect the reactor loop itself
— it only means a few observability documents get dropped. Left as-is for
the lab; a production setup would want an explicit index template with
`fun_args` mapped as an object or disabled.

---

## P4 confirmed working end-to-end (2026-09-14)

Manually broke srl1's interface description via `sr_cli` (simulating an
operator typo) with **zero Salt command run afterward**. Within one beacon
interval (20s):

```
salt/beacon/srl1/config_drift/drift  — diff: "oops typo..." -> "uplink to srl2..."
Fetching file ... 'reactor/heal_drift.sls'
Published command state.apply, jid ...
Result: True · Configuration changed! (reverted)
```

This is the loop the 2025 production stack never had — detect → decide →
act → verify, with no human in the middle.

## 12. n8n's `{{ }}` expression parser breaks on nested `}}` inside the template

Wrapping a whole ES query object in a single expression —
`={{ JSON.stringify({query: {bool: {must: [...]}}}) }}` — fails with a
generic `ExpressionError: invalid syntax`. n8n's template delimiter matching
looks for the first `}}` to close the expression; any `}}` produced by
adjacent closing braces *inside* a nested object literal (e.g.
`{"match": {"data.fun": "x"}}`) closes the expression early, truncating it
mid-object. Fixed two ways: (1) for a body with no dynamic values, skip the
`{{ }}` wrapper entirely and write plain static JSON; (2) for a body that
does need dynamic values, keep the object literal flat (no nested `{}`) and
build any nested structure via string concatenation instead of a literal.

## 13. `n8n import:workflow` needs an explicit `id`, and imports land inactive

A workflow JSON exported without a top-level `id` field fails import with
`SQLITE_CONSTRAINT: NOT NULL constraint failed: workflow_entity.id` — add
a UUID. Also, `active: true` in the JSON is not honored on import; the
CLI logs "Deactivating workflow" regardless. In this n8n version (2.38.7),
activation is `n8n publish:workflow --id=<id>`, which then requires an
**n8n restart** to actually take effect ("Note: Changes will not take
effect if n8n is running").

---

## P5 confirmed working end-to-end (2026-09-14)

Full pipeline, zero human action after the initial manual "mistake":

```
sr_cli: interface description manually changed on srl1
  -> beacon detects drift (20s)
  -> reactor heals it via sync_from_netbox (P4)
  -> n8n polls Elasticsearch for the healed diff (30s)
  -> n8n calls local ollama (llama3.1, native on the Mac, Metal-accelerated)
  -> generated ticket written to napalm-tickets index
```

Actual generated ticket (verbatim, unedited):

> Incident Report: SRL1 Configuration Reverted by Automation System
>
> The self-healing automation system detected that the configuration of
> device SRL1 had drifted from its declared source of truth. Specifically,
> the description of interface ethernet-1/1 was changed from "yet another
> manual mistake" to "uplink to srl2 (P2P transit)". The automation system
> automatically reverted the change to ensure the device's configuration
> remained in sync with its intended state. No further action is required
> by the NOC team as this change has already been resolved through
> automated remediation.

This is the "LLM writes the ticket, not the config" claim from the talk
outline, proven rather than asserted — the LLM never touches NAPALM, Salt,
or the device; it only reads an already-completed heal from Elasticsearch
and narrates it.

**All five phases (P1-P5) are now done and verified on live containers:**
containerlab + SR Linux, Salt + NAPALM, Elasticsearch/Kibana/Grafana,
NetBox source of truth, and the full self-heal + AI-explain loop.

---

# Phase 6 — fault → alert → AI → remediate (2026-09-14)

## 14. The public SR Linux container has no MPLS at all

Planned an MPLS core (LDP adjacencies, label bindings) for the demo.
Checked the CLI tree before building: `network-instance <ni> protocols`
offers bgp / bgp-evpn / bgp-vpn / igmp / isis / linux / mld / ospf / pim —
**no LDP**. There is no `system mpls` node and no `segment-routing` under
isis either. The freely available SR Linux image is a data-centre NOS;
MPLS lives on the 7250 platforms and was not reachable on this build.

Switched to **IS-IS**, which turned out to be the better fit anyway: the
fault this demo cares about — a P2P MTU mismatch where each device's own
config is individually valid — is IS-IS hello-padding behaviour, not
something MPLS adds. IS-IS came up clean on arm64: two L2 adjacencies on
the hub, loopbacks learned at the right metrics, end-to-end ping across
the hub at ttl=63.

## 15. containerlab reassigns mgmt IPs on every redeploy

Three times this session a redeploy silently moved every node's
management IP, which broke every `salt-proxy-*`'s `host:` line and cost a
debugging cycle each time. Fixed permanently with `mgmt-ipv4:` pinned per
node in `clab/topo.yml`.

## 16. salt-api must run in the master's container

Ran salt-api as its own compose service first. It answered
`503 Salt Master is not available`, and sharing `/var/run/salt` and
`/var/cache/salt` between the two containers didn't fix it — parts of the
auth path dial `127.0.0.1:4506`, which only exists where salt-master
itself runs. Now started alongside the master:
`sh -c "salt-api -l info & exec salt-master -l info"`.

## 17. Salt 3006+ disables every netapi client by default

`400 Bad Request — Client disabled: 'local'. Add to 'netapi_enable_clients'`.
A deliberate hardening: you must name the clients you want. Only `local`
is enabled here, so the API can ask a minion to run a state and cannot
touch runners or the wheel (key management).

## 18. ⭐ The whitelist stops invented templates. It does NOT stop wrong ones.

The most important finding of the whole build.

Sent the pipeline a fault with no matching remediation —
`bgp_session_flapping`. The LLM did **not** hallucinate a template name.
It picked `sync_from_netbox`: a real, whitelisted, completely irrelevant
template. salt-api accepted it (the name was valid), Salt ran it, and it
reported `Already configured.` — **no change made**.

So the whitelist did its job and still let a wrong decision through. What
actually contained the damage was that every remediation state is
**idempotent and narrowly scoped**: applying the wrong one was a no-op
rather than a new outage.

The fix was to give the model somewhere to put "I don't know": an explicit
`none` option, plus a line in the prompt saying *picking a template that
does not address the fault is worse than escalating to a human*. Retested
with the same fault:

```json
{"state": "none", "reason": "no template addresses this BGP peer flap fault"}
```

routed to the `napalm-rejected` index for a human. Two lessons, both
worth saying out loud: **give the model a way to decline**, and **make
every action it can trigger safe to trigger wrongly.**

## 19. Grafana alert labels came through as `[no value]`

Wired Grafana alerting → webhook → n8n. The alert fired correctly and
reached n8n, but `{{ $labels.device }}` rendered as the literal string
`[no value]` — the terms-agg series didn't carry the labels the way the
annotation template expected, so n8n received a fault with no device and
the LLM defaulted to a generic template.

Restructured rather than fought it: **Grafana's job is to say something is
wrong; Elasticsearch's job is to say what.** n8n now queries ES for
fault events in the last two minutes and works from that. More robust,
one less templating layer to be wrong, and it survives any future change
to how Grafana renders labels.

---

## Phase 6 confirmed working end-to-end

Injected `admin-state disable` on srl3 and touched nothing else:

```
beacon iface_down fires        salt/beacon/srl3/iface_down/fault
  -> Elasticsearch             napalm-2026.09.14
  -> Grafana alert rule        "Network fault detected by Salt beacon"
  -> webhook                   http://n8n:5678/webhook/fault
  -> n8n queries ES            srl3 | interface_admin_down | ethernet-1/1
  -> llama3.1 (local)          {"state":"restore_interface"}
  -> whitelist gate            accepted
  -> salt-api /run             state.apply restore_interface
  -> device                    admin-state disable -> enable
  -> IS-IS                     Adjacency Count: 0 -> 1
```

All three cases verified live: interface down (single device), P2P MTU
mismatch (between two devices, detected via the Salt mine), and config
drift from either source of truth.

---

# Phase 7 — making it credible to an operator (2026-09-14)

## 20. iBGP with a route reflector, on the same three nodes

AS 65001, srl2 as route reflector, srl1 and srl3 as clients, sessions on
the loopbacks. Two sessions established. Because the sessions ride
loopbacks reachable only via IS-IS, an IS-IS fault takes BGP down with
it — the cascading failure operators actually see, for free.

## 21. Salt's `revert_in` is NOT the device's confirmed commit

This one matters and I got it wrong first time.

`netconfig.managed(revert_in=60)` looked right — the parameter exists and
is forwarded. It did not roll anything back. Looking at the execution
module explains why: `confirm_commit(jid)` and `cancel_commit(jid)` take
a **JID**. Salt implements revert_in by scheduling a Salt job to undo the
change later. It is a real safety net, but it lives on the automation
side: if the master dies, or the minion dies, or the path between master
and device breaks, the scheduled revert never runs and the bad config
stays.

NAPALM's srlinux driver can arm the **device's own** commit-confirmed
timer instead, and that does work:

```python
d.commit_config(message="...", revert_in=60)
d.has_pending_commit()   # True
# ... nobody calls confirm_commit() ...
# the router rolls it back on its own clock
```

Verified on an interface no beacon manages (the first attempt used an
interface NetBox enforces, so the drift loop reverted it and the result
proved nothing — a false positive I nearly reported).

Exposed as `_modules/netsafe.py` (`netsafe.push_confirmed`,
`netsafe.pending`, `netsafe.confirm`) so the demo can show the property
that actually answers the operator's question: **the rollback does not
depend on the thing that made the change still being alive.**

## 22. A pending confirmed commit blocks every other commit

`CommitError: Pending commit confirm already in process!` — arm one and
the device refuses further commits until it is confirmed, cancelled, or
expires. Automation that arms a confirm and then dies locks the device
out of config changes for the length of the window. Worth knowing before
setting a long timer.

## 23. Concurrent remediations collide

Two remediation paths firing at once on one minion:
`The function "state.apply" is running as PID 9 ... with jid ...` — Salt
refuses the second. In a lab that is a retry; at scale it needs a queue
or a lock.

## 24. Circuit breaker — and why it is not optional

Added: at most **3 automatic remediations per device per hour**, counted
by querying the remediation index in Elasticsearch (so the limit survives
an n8n restart). Beyond that the fault is written to `napalm-rejected`
with `circuit breaker open — escalated to a human`, and the LLM is never
even consulted. A flapping device can otherwise be reconfigured in a
tight loop forever.

Implementation note: reading the count with `$('node').item.json` failed
silently — `.item` pairs by index and the breaker node emits one item
while the consumer runs per-fault. `.first()` is correct here.

## 25. ⭐ Where the model is good, where it is not

Four deliberately awkward faults, same whitelist:

| Fault given | Model chose | Verdict |
|---|---|---|
| `bgp_session_down`, detail says it followed an MTU change | `fix_p2p_mtu` | **Right** — treated the root cause, not the symptom it was labelled with |
| `bgp_session_down`, clean | `restore_bgp_neighbor` | Right |
| interface admin-down **and** MTU mismatch together | `fix_p2p_mtu` | **Wrong order** — fixing MTU on an interface that is still administratively down achieves nothing |
| `link_unstable`, "cause unknown", no MTU evidence | `fix_p2p_mtu` | **Guessed** — rationalised "MTU mismatch could be causing the instability" instead of declining |

So: genuinely good at single, well-described faults — including reasoning
past the label to the root cause. Weak at **ordering** when several faults
are live at once, and it will **reach for a plausible template rather than
decline** when the description is vague.

Both wrong answers were harmless. The vague one was a literal no-op
(`Already configured.`); the other changed a value that was already
correct. The network stayed up throughout — 1 / 2 / 1 adjacencies before
and after. That is the whole argument for narrow, idempotent templates:
**the design has to make a wrong decision survivable, because the model
will make wrong decisions.**

## 26. cAdvisor cannot name containers on Docker Desktop

Wanted a Grafana dashboard of the lab's own containers. cAdvisor +
Prometheus came up and scraped fine — 1716 metrics — but every series was
labelled only `id="/docker/<hash>"`, with no `name` label at all, because
cAdvisor cannot reach the daemon metadata inside Docker Desktop's VM. A
dashboard of hashes is useless on a slide.

Replaced with a ~40-line exporter that reads the Docker API directly and
writes to the Elasticsearch that Grafana already queries
(`statsexporter/exporter.py` → index `docker-stats`). Real container
names, no second datasource, and about 400MB of RAM handed back to a
laptop that needed it.

---

# Hardening, 2026-09-15

Everything above was found while building a demo. What follows was found
while trying to make that demo safe to publish and safe to run — a
different exercise, and it turned up a different class of bug. Several of
these had been sitting there the whole time, invisible because the demo
worked anyway.

## 27. ⭐ The alert rule spent an entire outage reporting healthy

`execErrState: OK` on the Grafana rule. Elasticsearch had just had
authentication switched on and the datasource had no credentials, so every
query the rule made came back `401 Unauthorized`. Grafana's API reported:

```
Network fault detected by Salt beacon | state: inactive | health: ok |
```

`inactive` and `ok`. Not "error", not "no data" — the rule was reporting
the network was fine, from a query it could not run.

Two fixes, and the second matters more than the first. `execErrState` is
now `Error`, so a rule that cannot see says so. And because a rule that
cannot read Elasticsearch has no idea what is wrong with the network,
`DatasourceError` is routed to an escalation store rather than to the
remediation webhook — a broken detector must be loud and must not be able
to start a config push.

The general form is worth stating: **a detector's failure mode is not
"nothing is wrong".** Anything that treats "I could not check" as "it is
fine" will eventually do it during the outage that mattered.

## 28. Grafana had no volume at all

Every datasource, dashboard, alert rule, contact point and notification
policy had been created by hand in the UI, and the container had no volume.
A `docker compose down` would have wiped the entire observability plane —
and the only reason it had not already happened was that `restart:
unless-stopped` kept the same container alive for days.

Fixed by provisioning all of it from files in `./grafana`, and verified the
only way that can be verified: by deleting the container and watching
everything come back.

## 29. Proxy minion keys were ephemeral

The master persisted its accepted keys on a volume. The proxies did not
persist their private keys. Recreate a proxy and it generates a new
keypair, the master sees a key that does not match the one it accepted for
that id, and rejects it:

```
[CRITICAL] The Salt Master has rejected this minion's public key!
```

The proxy then exits. The device is simply no longer managed, and nothing
says so except one line in a container log. Volumes for every proxy's
`/etc/salt/pki`; recovery from a lost one is `salt-key -d <id>`.

## 30. Idempotence is not correctness

Raised as a review comment on the talk, and it is the sharpest thing anyone
said about it: *achieving the same repeated outcome does not mean it is the
correct or intended outcome — might break things at scale.*

That is right, and the deck had been implying otherwise. A state that
reliably drives a device to the same configuration proves the configuration
matches the template. It proves nothing about whether that configuration
was the right thing to want.

The lab had a real instance of it and had not noticed. A shut interface on
srl3 takes IS-IS down, which takes iBGP down a minute later. The system
treated the BGP session as an independent fault, opened a second trace,
asked the model again, and pushed `restore_bgp_neighbor` to a device whose
BGP was not the problem. That remediation succeeded — idempotently,
repeatably, and pointlessly.

Four things came out of it:

* **Outcome checks** (`_modules/verify.py`). Every remediation declares a
  check on what it was *for*, separate from the config it writes: the
  interface is operationally up, the adjacency formed, the session reached
  established. An interface can be admin-enabled and still down.
* **Unverified changes are not kept.** Commit with the device's own revert
  timer armed; confirm only if the check passes. Proven by making the check
  impossible to satisfy — far end shut, near end enabled:

  ```
  05:14:08  change.applied      commit with revert_in=120, verify=interface_up
  05:14:53  change.unverified   "admin-enabled but operationally down" (45s)
  05:16:12  the device reverted itself, with no help from Salt
  ```

* **Blast radius.** The per-device rate limit is the wrong instrument for
  the failure that hurts at scale: one bad row in the source of truth
  faults every device at once, and each of those remediations is
  individually within its per-device budget. A second ceiling bounds how
  many *distinct* devices may change in fifteen minutes.
* **Symptom suppression.** BGP faults are not reported while an interface
  fault is open on the same device, and the suppression is itself recorded,
  so the audit trail explains the silence.

## 31. The drift reactor had no rate limit whatsoever

The n8n path had a circuit breaker from early on. The Salt reactor's drift
path — the other way to a device — had nothing. A device that drifted and
failed to converge would have been reconfigured every twenty seconds,
forever.

The fix is where the fix belongs: in `audited.config`, the state both paths
go through, rather than in either pipeline. Rate limit, blast radius and
maintenance freeze are one gate, configured in pillar, and a fourth
condition was added while writing it — if the audit store is unreachable,
refuse. An unattended change with no possibility of a record is exactly
what the gate exists to prevent.

## 32. `sync_from_netbox` would have blanked every description

```jinja
{%- set interfaces = salt['http.query'](...).get('dict', {}).get('results', []) %}
```

NetBox down, or returning a 500, or returning an empty page: `interfaces`
is `[]`, the template renders an empty interface set, and the state
converges the device to it. The source of truth being unavailable is not
the same as the truth being nothing. Both drift states now refuse to run
against an empty source.

In the same pass: `restore_interface` accepted any interface name the
caller supplied. The whitelist stops the model inventing a *state*; nothing
stopped it naming an interface nobody was watching. It is now restricted to
the ones the device actually monitors.

## 33. Opening a second connection to a device times out under load

`netsafe` opened its own NAPALM session instead of reusing the one the
proxy-minion already holds. Harmless with one remediation at a time; the
moment the interface→IS-IS→BGP cascade produced two at once, both died:

```
ConnectionException: JSON-RPC request failed: timed out
```

SR Linux's JSON-RPC server tolerates only a small number of concurrent
sessions. Reusing the proxy's connection also cut a config push from 18.5s
to 3.4s.

## 34. A backup script that reported success while backing up nothing

```sh
es -X PUT ".../_snapshot/selfheal/$STAMP" >/dev/null && echo "snapshot taken"
```

The snapshot was failing. `set -e` does not fire for the left-hand side of
an `&&`, so the script sailed past it, tarred an empty repository
directory, and printed a summary. Three separate problems were hiding
behind that one line:

* the repository was not registered, because `path.repo` only takes effect
  when Elasticsearch is recreated
* once it was, registration failed with `access_denied` — a named volume is
  created root-owned and Elasticsearch runs as uid 1000. The error names a
  temp file rather than a permission, so it reads like a config problem
* once that was fixed, the snapshot name was rejected for being uppercase

None of which would have been discovered until someone needed the backup.
The script now checks the repository, checks the snapshot state, and prints
Elasticsearch's own error instead of discarding it with `curl -f`.

## 35. Healthchecks that report unhealthy for a working service

`pgrep -f stats.py` — `pgrep` is not in `python:3.12-slim`. Both collectors
ran perfectly and reported unhealthy forever.

Replaced with a heartbeat file, which is the better check regardless: both
collectors are loops around a socket read, and a thread wedged on a
half-open connection leaves a perfectly healthy PID behind.

## 36. A one-shot init that hard-fails takes the whole stack down with it

`es-init` runs first and everything waits on it. When the snapshot
repository could not be registered, it exited non-zero, and compose refused
to start salt-master, n8n, Grafana, Kibana and both collectors — the entire
self-healing pipeline, stopped over a backup feature.

Bootstrap steps need a severity, not just a result. A missing index
template must stop the stack, because the alternative is silent data loss.
A missing snapshot repository must not.

## 37. n8n 2.x blocks `$env` inside nodes, and downgrading is not an option

Moving the salt-api secret out of the workflow JSON and into `$env` looked
like a clean win until every execution failed with `access to env vars
denied`. `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` fixes it, and it is the wrong
default for a shared automation server — the trade-off is written down in
`docs/production.md` rather than hidden in a compose file.

Separately: pinning the image to a version chosen from the tag list was a
downgrade across a major version. The volume's sqlite database already
carried 2.x migrations, so n8n refused to start, and a second failure came
right behind it — supplying a fresh `N8N_ENCRYPTION_KEY` to an install that
had already generated its own makes every stored credential unreadable. The
existing key had to be adopted, not replaced. Pin to the version you are
actually running, and read the key out of the volume before changing it.

## 38. Rotating a Postgres password in `.env` silently does nothing

Moving every credential out of `docker-compose.yml` and into a generated
`.env` worked for all of them except this one. Postgres reads
`POSTGRES_PASSWORD` **only when it initialises an empty data directory**.
On an existing volume the value is ignored entirely, and the new password
in `.env` is only what NetBox *presents*.

Nothing failed at the moment of the change. It failed the next time NetBox
restarted, and then presented as an endless restart loop — 39 restarts
before anyone looked:

```
FATAL: password authentication failed for user "netbox"
⏳ Waiting on DB... (27s / 30s)
```

The fix is one `ALTER USER`. The lesson is that a secret has two places to
live — the consumer and the thing being authenticated to — and a rotation
that only updates one of them is not a rotation. `scripts/bootstrap.sh` now
checks for exactly this disagreement at startup and prints the command,
because the failure surfaces far away in time from its cause.

## 39. ⭐ The network was down for 105 minutes and nothing said a word

A Docker restart stopped all three routers at 05:45:52. They stayed
stopped, because containerlab sets no restart policy while every service in
`docker-compose.yml` does — so the management plane came back healthy and
the network did not come back at all, which is the worst of the four
possible combinations.

It was found at 07:30, by accident, while checking something else. In
between:

* every compose service reported `healthy`
* the Grafana alert rule reported `state: inactive`, `health: ok`
* not one alert fired
* the proxy-minions logged `CRITICAL ... No route to host` into a log
  nobody was reading

Nothing was broken, exactly. The beacons could not reach the devices, so
they emitted no events, and every detector in the system works by counting
events. **Silence is indistinguishable from health to anything that
measures faults.** It is the same blind spot as the 401 in §27, in a place
where no rule was watching at all.

The fix could not be another beacon, because a beacon cannot report that
its own minion is dead, and it could not live in Salt, because a Salt
master cannot report that its own event bus has stopped reaching
Elasticsearch. `collector/watchdog.py` runs outside both and asks the one
question neither can: *when did each device last say anything at all?*
Confirmed on the failure that prompted it — three `device.silent` records
within a minute of starting, three `device.heard` when the proxies
reconnected.

The general rule, third time it has come up in this repo: **build one thing
whose failure mode is noise rather than silence**, and point it at
everything else.

## 40. Detection watched `is_enabled`; verification watched `is_up`

`verify.interface_up` correctly refused to accept a change unless the
interface was *operationally* up. The beacon that detects interface faults
only ever looked at `is_enabled` — the administrative state.

So the system could tell that a remediation had not worked, and could not
tell that a fibre had been cut. A link that goes down on its own was
invisible to it.

Fixed by splitting the fault in two rather than widening the existing one,
because only one of them has a fix this system is allowed to apply:

* `interface_admin_down` — someone shut it; `restore_interface` un-shuts
  it; a closed loop
* `interface_link_down` — the config is already correct and the link is
  down anyway; no runbook, and there should not be one

Merging them would have been worse than not detecting the second at all:
the model would have picked `restore_interface`, the push would have been
an idempotent no-op, verification would have failed, and the audit trail
would have filled with changes that did nothing to a link nobody went to
look at. Which is §30's point arriving from the other direction.

With them separated, the model gets a fault it genuinely cannot fix, and
declines in fifteen seconds: *"no configuration change can fix a physical
link down issue"*.

## 41. ⭐ A real runbook, chosen for the wrong fault, caught by testing

The reviewer's warning -- *achieving the same repeated outcome does not mean
it is the correct or intended outcome* -- turned up in the lab the day a
seventh runbook was added.

A new beacon warns when a BGP session approaches its prefix limit. There is
deliberately no runbook for it: raising a limit because the limit warned you
is disabling the safety device because the safety device went off. The model
is supposed to answer "none".

It answered `bgp_policy`, reason: *"BGP routing policy drifted from NetBox —
prefix filters"*. A real runbook, on the whitelist, for a fault it does not
address. And because `bgp_policy` is idempotent it would have succeeded,
changed nothing, recorded a clean `change.applied`, and left a transit
session heading for teardown with nobody looking at it. The whitelist cannot
catch this; idempotence does not help; only the outcome check would have
noticed, and there is no outcome to check when nothing needed doing.

The cause was one word. The runbook list described each template by the
technology it touches:

    - bgp_policy : BGP routing policy drifted from NetBox — prefix filters,
                   what we announce, what we accept from transit

and the fault was called `bgp_prefix_limit`. The model matched on "prefix".

Two changes, same model, same fault:

  each runbook is now described by the FAULT it repairs, not the technology
  it touches, with an explicit note that matching on a shared word is how a
  real runbook reaches the wrong fault

  the prompt names the two categories that are never a config push: capacity
  and thresholds ("a prefix limit being approached, a table filling, a
  counter rising"), and anything physical where the configuration is already
  correct

Result:

    before  decision.made      bgp_policy   "prefix filters"
    after   decision.declined  none         "Capacity issue cannot be
                                             resolved by a configuration push"

The failure was prompt design, not model judgement -- the same conclusion as
lesson 25, arrived at from the opposite direction. It is also the argument
for keeping a fault class in the lab that has no runbook at all: without
`bgp_prefix_limit` and `interface_link_down`, nothing would ever have tested
whether the model can decline.

## 42. The trace was on the device, but not where the docs said

Every claim in this repo about the router recording who changed it pointed
at

    info from state /system configuration commit *

and after a remediation that went through outcome verification, that
command showed a commit with no comment at all. The audit trail said one
thing and the device appeared to say nothing.

The trace was there. It was on the **checkpoint**, not the commit:

    checkpoint 0 {
        comment "selfheal trace=srl3-20260916T075658Z-36367a
                 actor=n8n/llama3.1 state=restore_interface"
        created "2026-09-16T07:57:22.986Z"
    }

SR Linux's `commit confirmed` takes no comment — it cannot, the syntax has
no room for one — so napalm-srlinux writes the message onto the checkpoint
it creates immediately before the change. The driver says so in a comment
that is easy to miss:

    # not combinable with save/comment; the message is already
    # recorded in the checkpoint comment above

Which is the better place for it. The checkpoint is the rollback anchor, so
the trace id names exactly the state you would roll back to — but only the
confirmed-commit path behaves this way, and that is the path every verified
remediation takes. A change applied without verification still carries its
comment on the commit.

Caught while collecting screenshots for a talk, which is the recurring
lesson underneath this one: **writing the claim down is not checking it.**
The command had been in the README for days and had only ever been run by
hand, against a change made by hand, which takes the other path.

## 43. A fixable fault can be starved by unfixable ones

After a redeploy left the whole fabric drifted, three devices needed
converging at once. The blast radius correctly refused the third — and then
a genuinely fixable fault on a device that was *not* blocked sat unhandled
for ten minutes.

The cause is where the work is spent, not where it is refused. Every
Grafana notification wakes one workflow run, which normalises whatever
Elasticsearch has seen in the last two minutes and takes the faults in the
order they come back. With srl1 producing a steady stream of blocked
attempts — BGP down, config drift, protocol drift, all refused — those
faults kept arriving first, and srl3's shut interface, which the gate would
have allowed, never got a turn.

Nothing is broken and nothing is lost: the fault stays open, the audit
trail is honest about it, and it converges once the fifteen-minute window
rolls. But "the system is busy being refused" is a real failure mode for
anything that processes a queue of faults, and it gets worse the larger the
fleet is.

The fix is to sort rather than to add capacity. A fault the gate would
currently refuse should go to the back: ask the gate *before* spending an
LLM call and a salt-api round trip on it, not after. That also removes the
odd shape in the audit trail where `change.requested blocked` outnumbers
every other action.

Not yet implemented, and written down rather than quietly left out.

There is a second lesson inside the first. The watcher script used to
confirm this reported

    13:37:02 t+211s  enable
    >>> HEALED once the freeze was lifted, after 211s

and it was wrong. The interface did come up at 13:37, because *I* brought
it up by hand to clean the lab. The audit trail has no change.applied
anywhere near that time, and the device's newest checkpoint is a bgp_policy
push five minutes earlier.

The script watched the *state* and inferred the *cause*, which is precisely
the mistake this whole project is about. Every test that asks "did it heal"
has to ask the audit trail who did it, not the device what it looks like —
otherwise a human tidying up in another terminal counts as a success.

## 44. 2048MB was the documented fix, and it was still not enough

Lesson 38 raised every router from 1400MB to 2048MB after a starved node
lost its datapath while reporting healthy. That number was measured from a
three-node lab. On four nodes it is wrong, and it fails the same silent
way:

    srl1  peak=2.05GB  limit=2.05GB  oom_kill=3
    srl2  peak=2.05GB  limit=2.05GB  oom_kill=0
    srl3  peak=2.05GB  limit=2.05GB  oom_kill=2
    srl4  peak=1.84GB  limit=2.05GB  oom_kill=0

srl1 and srl3 were killed and came back with

    mgmt0 is down, reason port-not-present

while `show system application` listed `json_rpc` and `mgmt_server` as
running and the JSON-RPC server's own state said `oper-state: up`. Every
container reported healthy, containerlab reported running, and NAPALM could
not open a connection to either of them. The real peak, once given room,
is 2.30-2.42GB.

Two things follow. A limit derived from one topology is not a property of
the software, and writing the number down in a comment does not make it
true of the next topology. And a memory limit is not a safety control here:
starving SR Linux does not slow it down, it removes its management plane
and leaves everything else asserting that the device is fine.

## 45. The fourth router cost 1.8GB to do nothing

srl4 is the upstream transit provider. It holds one eBGP session and
originates three prefixes. As SR Linux it peaked at **1.84GB** — while
idle, with one interface configured — which was most of the headroom the
other three needed.

It is now FRR, in the same topology, doing the same job:

    srl4  cur=0.02GB   oom_kill=0

Twenty megabytes against 1.84GB. Nothing else changed: same AS, same /31,
same three originated prefixes, same export policy expressed in FRR's
syntax instead of SR Linux's.

The honest reason to do it was memory. The better reason only became
obvious afterwards: a transit provider **is** a different company running
different software that you cannot log into, and making it a fourth
identical SR Linux had quietly implied otherwise. The trust boundary is now
visible in the topology file rather than asserted in a comment, and a fault
that arrives from outside your own configuration language is exactly the
kind an ISP actually gets.

## 46. `srl*` covered the upstream, and nothing happened

`salt/master.d/api.conf` granted n8n `state.apply` on `'srl*'`. That glob
was exactly right for every device the automation managed — until the
topology grew a fourth node that was somebody else's router, at which point
it silently covered that too.

Nothing broke, because srl4 has no proxy-minion, so the target matched
nothing. That is the part worth sitting with: the boundary was being held
by an *absence*, not by a rule. Adding a proxy for srl4 — which a student
following the lab might reasonably do — would have handed the automation
write access to a transit provider with no code change and no warning.

It is now three named entries. Adding a device to that list is the act of
deciding that automation may write to it, and it should look like a
decision.

## 47. Every detector compared configuration to intent, so none could see a leak

`config_drift` watches descriptions, `config_drift_golden` watches the
protocol layer, `config_drift_policy` watches the routing policy itself.
All three answer the same question: does this device's configuration match
what the source of truth says? A route leak passes all three, because a
leak is not a configuration that looks wrong — it is a configuration that
looks right and behaves wrongly. An export policy attached to the wrong
peer-group, a prefix-list carrying one `le` too many, an aggregate whose
components escape alongside it: each diffs clean.

`route_leak` reads the post-policy adj-rib-out instead — what actually went
out the session — and compares it to the export set NetBox declares:

    srl3 is advertising 7 prefix(es) to 198.51.100.0 (AS64500) that NetBox
    does not permit: 7 prefix(es) that are not ours to announce
    (10.255.0.1/32, 10.255.0.2/32, 10.255.1.0/31, ...).
    Permitted: 203.0.113.0/24

And the remediation verifies the same way. `bgp_policy` now declares

    verify: verify.advertises_only

so the change is committed under the device's own revert timer and kept
only when the announcements actually stop:

    00:20:22  change.applied   success   policy_drift
    00:20:29  change.verified  success   198.51.100.0 is being offered
                                         only 203.0.113.0/24

That line is the point of the whole exercise. It does not say the policy
matches NetBox. It says the router stopped announcing what it should not.

One caveat, recorded because it is the obvious next test: the injection
used by `break.sh leak` relaxes `transit-out`'s default action, which
changes the configuration — so `config_drift_policy` sees it too, and in
this run it was the drift reactor that drove the fix. Proving `route_leak`
catches what the config detectors cannot needs a leak that leaves srl3's
policy config untouched.

## 48. Restarting a containerlab `linux` node destroys its links

The first `unbreak.sh` undid the prefix-leak injection by restarting srl4,
on the reasoning that FRR reads its configuration from a bind-mounted file
and a restart therefore restores it exactly. The configuration did come
back. The interface did not:

    lo    UNKNOWN   127.0.0.1/8 10.255.0.4/32
    (no eth1)

containerlab builds the veth between `srl3:e1-3` and `srl4:eth1` at deploy
time. `docker restart` destroys it, and the node comes back configured,
healthy, and with no data plane — a BGP session that will never leave
`Active`, which looks exactly like a routing problem and is not one.
Recovering it took a full `--reconfigure`, which rebuilds the entire lab.

The undo is now done in place with FRR's own negation commands. The general
form of the lesson: for a `linux`-kind node, the container lifecycle and
the topology lifecycle are not the same thing, and only containerlab owns
the second one.

## 49. Bringing the fabric up burns the budget that heals it

Provisioning three routers is three changes. The per-device ceiling is
three changes an hour. So immediately after a bring-up, the device most
likely to need self-healing is the one least able to receive it:

    00:15:32  change.blocked  rate limit: 3 changes to srl3 in the last
                              hour (limit 3) -- escalating to a human
    00:20:11  decision.blocked  circuit breaker: 3 changes to srl3

Every one of those refusals is correct in isolation. Together they mean a
freshly provisioned fabric is unprotected for an hour, and — more sharply —
that a live demo will not heal anything if any setup was done by hand
first.

`bootstrap.sh` already does initial provisioning through the override path,
which is the right shape. What it does not do is stop those changes
counting against the automation's budget afterwards. Whether a human's
deliberate override *should* count is a genuine design question: the device
really did change three times. Written down rather than silently tuned
away, because raising the limit until nothing trips it is how these
controls die.

## 50. ⭐ A clean bootstrap left the fabric with no network, and said it was fine

Three separate bugs in `scripts/bootstrap.sh`, found by doing the one thing
that had never been done: running it from nothing and then checking the
network rather than the exit code.

**It never provisioned the protocol layer.** The converge step applied
`sync_from_netbox` and `sync_from_pillar` — the interface *descriptions* —
and nothing else. `golden_config` and `bgp_policy` were not in the list at
all. Bootstrap finished, printed its URLs, and left three routers with no
IS-IS adjacencies and no BGP sessions. Every container was healthy. The
first thing anyone cloning this repo would have seen is a lab that reports
up and has no network.

**It converged srl3 from the wrong source of truth.** `sync_from_pillar`,
left over from when srl3 demonstrated a second backend — while srl3's own
drift beacon watches NetBox. Bootstrap wrote pillar's descriptions and the
beacon reported them as drift twenty seconds later. A fresh install
disagreed with itself on arrival.

**And its "already deployed" check asked the wrong question.** It tested
whether the srl1 *container* was running. containerlab builds the veth
pairs between nodes at deploy time, and a host restart brings every
container back through its restart policy without rebuilding them — so the
nodes come up configured, healthy, and wired to nothing. On exactly that
state the check said "already deployed, skipping".

The three compound into the finding worth keeping. With the links gone,
every interface was oper-down, and IS-IS was correctly configured on all of
them — so `golden_config` reported:

    Already in the desired state.

It was telling the truth. The configuration matched the intent perfectly,
on a fabric that could not pass a packet. That is the whole argument for
checking outcomes rather than configurations, made by the repo's own
provisioning script against its own author, and it went unnoticed for as
long as nobody ran bootstrap from scratch and then looked at an adjacency
count.

`links_up()` now asks whether a link is UP before deciding the topology
exists, and the converge step provisions protocols, then policy, then
descriptions, in that order.

## 51. The fault-injection script reported injecting a fault it had not injected

`./scripts/break.sh mtu srl1` printed

    setting ethernet-1/1 mtu to 1400 on srl1 — the far end stays at 9000

and changed nothing at all. SR Linux 24.10.1 accepts an interface MTU of
1450..9500 and answered:

    Error: Failed to parse value '1400' ... Must be an integer in
    range 1450..9500

Nobody saw that, because the helper every case used was

    cli() { docker exec -i "clab-selfheal-$1" sr_cli >/dev/null 2>&1; }

Both streams to /dev/null, and the exit status never checked. The script
announced the injection, the device refused it, and the run continued —
with a fabric that was never broken and therefore never healed. Every test
downstream of it passed for the wrong reason.

This is lesson 39's mistake in a different costume. That one was a watcher
that inferred a heal from device state; this one is an injector that
assumed a break from its own echo statement. Both substitute intention for
observation, and both are the exact failure the rest of this repo exists to
argue against.

`cli()` now prints what the device said and exits non-zero when it contains
an error.

## 52. The MTU case is better than the deck claimed, and differently

With a valid mismatch — 1500 on one end, 9232 on the other — the adjacency
does die, and SR Linux is explicit about why:

    srl1:  ethernet-1/1 is up, speed 100G
             ethernet-1/1.0 is down, reason ip-mtu-too-large

    srl2:  ethernet-1/1 is up, speed 100G
             ethernet-1/1.0 is up

So the slide's line — "neither device reports an error" — is not true on
this version. srl1 reports one. What is true, and is the sharper point, is
that **the far end reports nothing whatsoever**: srl2's subinterface is up,
its configuration is valid, every config-vs-intent check it has passes, and
it has no idea anything is wrong. Meanwhile srl1 knows its own MTU is too
large for something but cannot know what the other end is set to.

Neither device can name the fault. Only the pair can:

    07:13:53  srl1  srl1:ethernet-1/1 mtu 1500 != srl2:ethernet-1/1 mtu 9232 (agreed 9232)
    07:15:01  srl2  srl2:ethernet-1/1 mtu 9232 != srl1:ethernet-1/1 mtu 1500 (agreed 9232)

Both sides independently, through the Salt mine, each reading the other's
state. That is a better story than the one on the slide, and it survives a
network engineer checking it against a real device.

## 53. ⭐ Two heals at once shared one candidate, and one of them lost

The `TypeError: 'NoneType' object is not subscriptable` that had been
appearing and vanishing for days turned out to be a race, which is why it
never reproduced on demand. The traceback added in lesson 47's commit
caught it on the first run that failed afterwards:

    File "netsafe.py", line 179, in push_template
        dev.commit_config(message=message, revert_in=int(revert_in))
    File "napalm_srlinux/srlinux.py", line 1488, in commit_config
        if self._candidate["mode"] == "json":
    TypeError: 'NoneType' object is not subscriptable

`_candidate` is the driver's loaded-but-not-yet-committed configuration,
and it was None by the time the commit ran. The reason is two deliberate
decisions meeting:

* the proxy-minion runs `multiprocessing: false`, so every Salt job on it
  is a **thread in one process**, and
* `_device()` hands every one of those threads the **same driver object**,
  on purpose, because SR Linux's JSON-RPC server will not tolerate a second
  session.

So the driver's `_candidate` is shared mutable state across concurrent
jobs. Two jobs at once is not an edge case in this system, it is the normal
case: shutting an interface produces an `iface_down` fault *and* a
`config_drift` fault, and the reactor answers both.

    restore_interface   load_merge_candidate()   _candidate = {...}
    sync_from_netbox    load + commit            _candidate = None
    restore_interface   commit_config()          TypeError

Observed exactly that way:

    07:36:56  decision.made   accepted  Interface was administratively shut.
    07:36:58  fault.detected  open      running config differs from NetBox
    07:36:58  change.failed   failure   TypeError: 'NoneType' object is not subscriptable

The model was right, the runbook was right, the gate allowed it — and the
interface stayed down. The audit trail recorded `change.failed`, which is
the system being honest about a failure it could not explain.

Fixed with an `RLock` in netsafe around the load → diff → commit window.
The same fault, retried after the fix, with the same drift fault in play:

    07:39:59  fault.detected   open      ethernet-1/1 is administratively down
    07:42:39  decision.made    accepted  interface was administratively shut
    07:42:47  change.applied   success
    07:42:49  change.verified  success   ethernet-1/1 is up
    07:43:00  fault.resolved   resolved

The general lesson is not about locks. It is that the two safety properties
this repo argues for — reuse one device session, and run remediations
concurrently because faults arrive in groups — are in direct tension, and
nothing in the design said so out loud until a router stayed broken.

## 54. ⭐ Grafana grouped every fault into one, on labels that did not exist

The alert rule sets `labels: {}` and its annotations referenced
`$labels.device`, `$labels.fault`, `$labels.interface`. The notification
policy grouped by the same three. None of them exist.

Grafana's Elasticsearch datasource names a terms-aggregation series after
the *field* it grouped on, so a firing instance actually carries:

    data.device.keyword     = srl2
    data.fault.keyword      = interface_admin_down
    data.interface.keyword  = ethernet-1/1

Two consequences, one cosmetic and one severe. The annotations rendered as
empty strings — harmless, because n8n re-reads the fault record from
Elasticsearch rather than trusting the payload, which is why this survived
so long unnoticed. But `group_by` names labels that evaluate to nothing, so
**every firing instance landed in the same group**, and one group sends one
notification per `repeat_interval`.

With two faults open, one of them was never delivered:

    07:45:06  srl2  interface_admin_down   fault.detected
    07:45:20  both instances Alerting in Grafana
    07:51:35  srl1  interface_link_down    decision.declined
    ...srl2 never reached the model at all, for nine minutes

And two faults at once is not unusual here, it is what a single failure
looks like: shutting `srl2:ethernet-1/1` raises `interface_admin_down` on
srl2 and `interface_link_down` on srl1, because the neighbour's link went
down with it. The system was built to handle exactly that and the alerting
layer was quietly serialising it.

Fixed by grouping on the real label names. Templating them back to the
short names was tried first and is recorded here because it made things
worse in an instructive way: Grafana rendered the template as the literal
string `data.device.keyword` for every instance, so all of them still had
identical labels and still collapsed — a fix that looked applied, changed
the output, and preserved the bug.

The heal that had been stuck for nine minutes completed immediately
afterwards, and the released backlog produced free evidence for a control
that had never been observed firing:

    07:54:49  decision.made       accepted  Re-enables the administratively shut interface
    07:54:52  change.applied      success
    07:54:53  change.verified     success   ethernet-1/1 is up
    07:54:58  fault.resolved      resolved
    07:55:58  decision.duplicate  skipped   trace ...-6e0a33 is already settled or being decided
    07:56:34  decision.duplicate  skipped
    07:56:36  decision.duplicate  skipped

Three notifications for one fault, three refusals to act twice.

## 55. The BGP case never reaches the model, and that is the right answer

`break.sh bgp` shuts an iBGP neighbour. Two detectors saw it, two seconds
apart, and the deterministic one finished before the model was asked:

    08:03:46  fault.detected  config_drift_golden  IS-IS, BFD or BGP session
                                                   config differs from the
                                                   fabric plan
    08:03:48  fault.detected  bgp_down             iBGP session srl3 ->
                                                   10.255.0.2 (route-reflector)
                                                   is idle, expected established
    08:03:51  change.applied  salt-reactor/config_drift   golden_config
    08:04:10  fault.resolved

Five seconds from detection to a committed fix, with no LLM call, no
salt-api round trip and no whitelist check — because shutting a neighbour
is a *deviation from a declared configuration*, and comparing a device to
its intended configuration is a diff. There is nothing to reason about.

This sharpens where the model belongs. It is not needed for anything the
golden config already describes. It earns its place on the faults that are
not config deviations at all:

* a physical link that is down while the interface is enabled
* a prefix limit approaching on a session whose config is perfect
* an MTU that is valid on both ends and wrong as a pair
* a leak that is a correct-looking policy behaving wrongly

Every one of those passes a config-versus-intent check.

Two smaller findings from the same run. `break.sh bgp` was still shutting
`10.0.0.2`, a neighbour that stopped existing when the fabric was
renumbered for the border router and the upstream — another injection that
had been quietly refused by the device. And `bgp_down`'s beacon text turned
out to be exactly what the deck claimed, which was luck rather than
verification: the *outcome* line on that slide had been written from
memory, and was wrong.

## 56. ⭐ An unreadable device looked exactly like a device with every session down

`bgp_down` read the device like this:

    result = __salt__["bgp.neighbors"]()
    out = result.get("out", {}) if isinstance(result, dict) else {}

and never asked whether the read had succeeded. When the device cannot be
reached, `out` is empty, `live` is empty, and every neighbour declared in
pillar comes out as `missing` — which the loop below reports as down.

Proven by pausing srl2's container, so NAPALM got `No route to host`:

    09:09:07  fault.detected    open       iBGP session srl2 -> 10.255.0.1
                                           (route-reflector) is missing
    09:09:07  fault.detected    open       iBGP session srl2 -> 10.255.0.3
                                           (rr-client) is missing
    09:09:28  decision.made     accepted   "iBGP session is administratively
                                            shut"
    09:09:38  change.requested  no-change  An exception occurred in this state

Two invented faults. The model woken and handed a false premise — it
concluded the session had been administratively shut; the box was gone. A
salt-api round trip spent pushing at a device nothing could reach. The only
thing that prevented a configuration change on a false belief was that the
push failed too.

It also spends the per-device rate limit and the fleet blast radius that a
genuine fault would need, on a device whose actual problem is that somebody
has to walk to it.

The fix is four lines: if the read did not succeed, return no verdict.
Re-run, same pause:

    bgp_down: cannot read srl2 (Device connection is not open) -- no verdict

    09:38:19  device.silent  srl2 has produced no Salt event for 930s
                             (threshold 180s)

Zero invented faults, and the watchdog raising the one true thing instead:
this device has gone quiet. Which is what the watchdog exists for — a
beacon cannot report that its own minion is dead.

The detail worth keeping is that `iface_down`, in the same repo, already
had this right:

    data = ifaces.get(name)
    if not data:
        # No reading is not the same as a healthy reading

One beacon knew. The other did not, and nothing made them agree. "I do not
know" is a third answer, and every detector needs it.

## 57. One alert, one fault — the workflow had been handling a list

With the alerting labels fixed (lesson 54), a second bug underneath it
became visible. `Normalize alert` had two paths: a fault POSTed directly,
or — when Grafana's labels were unusable — "take what Elasticsearch has
seen recently", which returns **every** recent fault as a list.

The short label names were always empty, so every notification took the
list path. One notification processed all open faults; two notifications
for two different faults each processed the same list. Observed with an
interface shut on srl3, which also takes srl2's link down:

    14:47:56  srl2  fault.detected     interface_link_down
    14:47:58  srl3  fault.detected     interface_admin_down
    14:48:18  srl2  decision.declined  configuration changes cannot fix a physical issue
    14:48:20  srl2  decision.declined  configuration push cannot resolve a physical issue

Two decisions for srl2, two seconds apart — and srl3, whose own alert
instance was firing at the same moment, got none. It was eventually healed
six minutes later on a repeat notification, with `decision.made` recorded
twice.

An alert is about one fault. It now reads `alerts[0].labels` for the
device, fault and interface, then matches that triple against the recent
events to recover the trace id and detail — rather than taking the newest
event and hoping.

The difference on a clean run:

    14:59:33  break
    14:59:40  fault.detected     open      ethernet-1/1 on srl1 is administratively down
    15:00:09  decision.made      accepted  Administrative state of the interface needs to be re-enabled
    15:00:12  change.applied     success
    15:00:13  change.verified    success   ethernet-1/1 is up
    15:00:13  fault.resolved     resolved

Forty seconds, one decision, deterministic. That last word is what matters
for anything you intend to record: the previous behaviour healed too, just
not reliably and not on a schedule you could film.

## 58. `multiprocessing: true` is worse here, and the canonical book does not say why

"Network Automation at Scale" (Ulinic & House, O'Reilly 2017) — written by
the author of Salt's NAPALM integration — says on page 21:

> "A notable option required for some NAPALM drivers to work properly is
> multiprocessing set as false ... This is necessary for SSH-based proxies
> ... However, it can be re-enabled for devices using HTTP-based APIs
> (e.g., Arista or Cisco Nexus)."

SR Linux is JSON-RPC over HTTP, so by that rule we could re-enable it — and
doing so would have dissolved lesson 53's race structurally, since each job
would get its own process and its own copy of the driver's `_candidate`.

Tested. It does not.

Basic operation looked fine: `test.ping` fine, `net.interfaces` returning
36 interfaces, six concurrent device reads all succeeding, beacons still
emitting. Then a real fault:

    15:44:00  decision.made   accepted  interface was administratively shut
    15:44:05  fault.detected  open      IS-IS, BFD or BGP session config differs
    15:44:05  change.failed   failure   TypeError: 'NoneType' object is not
                                        subscriptable

The same failure as before, and now the `RLock` from lesson 53 cannot help,
because a per-process lock serialises nothing across processes.

The reason is in the driver:

    self._candidate_name = f"napalm-{session}"      # srlinux.py:77
    enter = f"enter candidate private name {self._candidate_name}"

`_candidate_name` is fixed when the driver is created, so every forked
child inherits the same one — and they all drive **one named candidate on
the router**. `_discard_named_candidate()` then wipes the candidate another
process is still building. The collision simply moves out of Python memory
and onto the device, where a lock cannot reach it.

So the book's carve-out assumes a driver that is stateless per request.
This one is not: it keeps server-side session state keyed to a name fixed
at connect time, and that has to be serialised whatever the transport is.
`multiprocessing: false` plus a lock is correct here, and the comment in
`salt/proxy-srl*` should say so on its own evidence rather than leaning on
the book's SSH rationale.

Worth keeping as a general shape: "HTTP, therefore safe to parallelise" is
a statement about the transport. Concurrency safety is a property of where
the state lives.

## 59. Writing the napalm-logs profile SR Linux does not have

napalm-logs 0.11.0 ships profiles for eos, fortinet, huawei, ios, iosxr,
junos, netiron, nxos, opengear and sonic. Not SR Linux — which is the
reason this lab polls for faults at a beacon interval instead of consuming
pushed events, and the one respect in which the lab is worse than the 2025
production system it is modelled on.

The raw material was already here. `collector/syslog.py` has been shipping
device syslog into Elasticsearch, and 1,384 real messages were waiting:

    bfd      237    Session from 10.255.1.1:16420 to 10.255.1.0:16414 is UP
    isis      74    the level-2 IS-IS adjacency with system 0000.0000.0002,
                    using interface ethernet-1/1.0, moved to state UP.
    lldp      32    LLDP remote peer added on interface ethernet-1/1: ...
    bgp       28    Group ibgp: Peer 10.255.0.2 moved into the ESTABLISHED state
    netinst   16    The interface ethernet-1/1.0 in network-instance default is now up
    mgmt      13    Generated checkpoint NAPALM-e19a8f50-1 with comment selfheal
                    trace=srl2-20260921T042800Z-9d5b73 actor=n8n/llama3.1

That last line is worth its own note: **the router's own syslog carries our
trace id**. The automation's actions are in the device's log, attributed to
the model that chose them, in a place nobody has to be told to look.

A napalm-logs profile is pure YAML. Two things were learned writing one.

`init.yml` must bind a value called exactly `tag` — the schema check fails
with `Unable to find key "prefixes:values:tag"` otherwise, which is a good
error. And SR Linux carries *two* headers: the RFC 5424 one, then its own
`app|pid|tid|seq|severity:` inside the message body. Consuming both in the
prefix keeps every message file down to a `line` and a mapping.

All seven message types were replayed through napalm-logs and checked on
the ZeroMQ publisher:

    error: INTERFACE_UP                 host: srl1
      yang: interfaces/interface/ethernet-1/1.0/state/oper_status = UP
    error: BGP_NEIGHBOR_STATE_CHANGED   host: srl1
      yang: bgp/neighbors/neighbor/10.255.0.1/state/session_state = IDLE

`LLDP_NEIGHBOR_DOWN` publishes an empty `yang_message`, and the file says
so rather than inventing a field: OpenConfig has no way to express "this
neighbour is gone" through a napalm-logs mapping.

Not wired into the lab yet, deliberately. napalm-logs is another process to
keep alive, and a syslog message that never arrives is silence — which this
repo has already been caught treating as health three times (§11, §20,
§56). Both paths should run together before either is trusted alone.

## 60. ⭐ The border router's BGP intent existed only in a database

`docker compose down -v`, then `bootstrap.sh`, then:

    srl3 has no bgp config context in NetBox — not a border router,
    nothing to do

srl3 is the border router. The config context carrying what it announces,
accepts and filters had never been created by any script. It existed only
in whichever NetBox database had been poked by hand, months ago, and the
volume delete took it with it. A fresh clone never had it at all.

Three things then quietly did nothing:

* `bgp_policy` — "not in scope", so the policy layer was never applied
* `config_drift_policy` — nothing to compare against
* `route_leak` — no permitted set, so no leak is possible by definition

None of them failed. All three reported success. The most recent and
strongest case in the whole repo was dead on arrival for anyone who cloned
it, and the only symptom was a sentence that reads like a correct answer.

Fixed in two places: `gen-configs.py` now derives the BGP intent from the
same `PLAN` as everything else, and `seed.py` writes it to NetBox.

The second half took two attempts, and the failed one is the instructive
part. A NetBox **config context** was the obvious home, so that is what was
written first — bound to the device. NetBox assigns config contexts by
region, site group, site, location, device type, role, platform, cluster,
tenant or tag. **There is no per-device assignment.** The `devices` field
was accepted by the API, stored as `None`, and the context applied to
everything:

    srl1  config_context keys: ['bgp']
    srl2  config_context keys: ['bgp']
    srl3  config_context keys: ['bgp']

Two core routers with no transit session at all now believed they had an
eBGP peering with AS64500 and a customer aggregate to announce. Had
`bgp_policy` run before that was noticed, it would have rendered transit
policy onto both of them — a wrong-but-idempotent change, applied
confidently, to every device that matched a category. Which is precisely
the failure the blast radius limit exists for, arriving through the source
of truth rather than through a beacon.

The right home is the device's own `local_context_data`, which merges into
`config_context` for exactly one device. Binding by role would have been
defensible for something every edge router shares; "the prefixes srl3
announces" is not that.

    srl1  []
    srl2  []
    srl3  ['bgp']

Also fixed here: `seed-netbox.sh` ran its seeding scripts in a throwaway
`python:3.12-slim` attached to the lab network, and began by installing
requests from PyPI. The lab network has no route to PyPI:

    Failed to establish a new connection: [Errno 101] Network is unreachable

So seeding required internet, and when it did not have it, it seeded
nothing and left NetBox empty — the same silent-empty-source-of-truth
failure by a different road. It now runs in salt-master, which already has
requests and is already on the right network, the way the discovery step
beside it already did.

## 61. ⭐ `set -e` is a correct stop and an invisible one

The lab was recorded on. A fault was injected, Grafana fired, the Salt
beacon detected it — and then nothing happened for four minutes. Every
container was running. Every health check was green. Grafana showed the
alert firing. The demo simply sat there.

The answer was one line in a log nobody was watching:

    Received request for unknown webhook:
    The requested webhook "POST fault" is not registered.

and then:

    $ docker exec n8n n8n list:workflow
    $

No workflows at all. The reason was four steps earlier and an hour older.
`bootstrap.sh` runs `set -eu`, and the NetBox seed had failed on a machine
with no route to PyPI (lesson 60). `set -e` did exactly what it is for: it
stopped. And stopping meant the *n8n import three steps below it never
ran*. The script printed its error and exited, the terminal scrolled, and
what remained on screen was a lab that had come up.

The bug was not the failure. The bug was that **an aborted bootstrap and a
finished bootstrap left the same evidence**: containers up, services
healthy, ports answering. Nothing distinguished them, so nothing could be
asked about them. `docker ps` cannot see a missing workflow. A health
check cannot see a service it was never told to expect.

Two things came out of this.

**An aborted run now says so.** A `trap ... EXIT` reports which step died
and, more usefully, that everything after it was skipped:

    == BOOTSTRAP DID NOT FINISH ==
    It stopped in: seeding NetBox
    Everything after that step was skipped. The containers that are
    already up will look healthy, and the lab will not work.

**And the completeness of the lab became a question you can ask.**
`scripts/check-lab.sh` checks the *wiring between* services, not the
liveness of each one — the links exist and not merely the nodes, the
beacons are loaded and not merely the proxies, NetBox has devices in it
and not merely a 200, the fault webhook answers and not merely n8n's
port, Salt events are landing in Elasticsearch and not merely that
Elasticsearch is green. Seventeen checks, each with the command that
repairs it, and the exit code is the number of failures, so bootstrap can
end on it instead of ending on a list of URLs and a hope.

The first draft of that script reported four failures on a lab where all
seventeen things were fine. `beacons.list --out=json` returns a JSON
object whose single value is a YAML *string*, so the keys arrive as
`iface_down:` and never as `"iface_down"`; and `docker exec` without `-i`
silently discards a heredoc, so NetBox "did not answer" a query it was
answering perfectly. Both were caught by running it, which is the whole
point: a checker is code, and code that reports a healthy system broken
is worse than no checker at all — it teaches you to ignore it.

It also demanded `route_leak` on all three routers. Only srl3 has a
transit peer, so only srl3 runs that beacon. The check was wrong about
what the lab should be, which is a third way for a checker to lie.

## 62. ⭐ Leaving scope is not a state any of this can express

Lesson 60 fixed the cause: the BGP config context was bound to every
device instead of one, so srl1 and srl2 — core routers with no transit
peer — were converged with the border router's service layer. NetBox was
corrected, `local_context_data` now carries it for srl3 alone, and
`bgp_policy` on srl1 answers, correctly:

    srl1 has no bgp config context in NetBox — not a border router,
    nothing to do

Which is exactly the problem. "Nothing to do" is what the state says
about a device that is *still carrying every line it was given*:

                    blackhole 203.0.113.0/24   transit-in   ebgp-transit   real peer
      srl1 (core)          present              present       present          0
      srl2 (core)          present              present       present          0
      srl3 (border)        present              present       present          1

This is not cosmetic. All three routers originate the customer aggregate
into iBGP, and two of them resolve it to a blackhole. srl2's table shows
both paths — one from srl3, one from itself:

      Received Paths: 2
        Path 1: <Best,Valid,Used,>  Route source: neighbor 0.0.0.0
        Path 2: <Valid,>            Route source: neighbor 10.255.0.3

The core router's own blackhole wins, because a local static beats an
iBGP path. Customer traffic arriving at srl2 is dropped by the router that
was never supposed to know that prefix existed.

The mechanism is ordinary and worth saying out loud, because every
merge-based automation has it. `audited.config` renders intent and loads
it as a *merge*. A merge adds and changes; it cannot subtract, because
nothing in the rendered document mentions the lines that should go. When
a device leaves scope, the source of truth stops describing it — and
"stops describing" and "describes as absent" are the same empty set.
Intent-based convergence quietly means *convergence toward what intent
mentions*, and everything intent has forgotten is frozen in place.

So the blast radius of a misapplied config context is not the window in
which it was misapplied. It is permanent, and it is invisible to the very
beacons meant to catch drift: `config_drift_policy` on srl1 compares the
device against a NetBox that says nothing about policy, finds no
disagreement, and reports compliant. The device is compliant. The device
is also wrong.

Two honest answers exist and this lab has neither yet:

  - render the *negative* — have the state emit the `delete /` lines for
    a scope it no longer holds, which means the template must know what
    it used to own, not only what it owns now
  - treat the golden config as complete and load it as a **replace**
    rather than a merge, so anything absent from intent is absent from
    the device — the correct answer, and a much larger one, because it
    means intent has to describe every line on the box

For now the cleanup is a rebuild: `containerlab destroy` returns the nodes
to their bootstrap config, and `bootstrap.sh` converges them from a NetBox
that is now right. Worth knowing that `docker compose down -v` does *not*
do this — the routers are deployed by containerlab, not compose, so they
survive a full teardown of the stack with every stray line intact.

## 63. ⭐ n8n is "healthy" before it has a database

The rebuild in lesson 61 was clean: routers destroyed and redeployed, every
volume gone, new secrets, `bootstrap.sh` from scratch. `check-lab.sh` then
reported the same two failures as the run it was written to catch.

    [FAIL] n8n workflows imported          0 present, expected 2

Running the import by hand worked immediately. So the import was not
broken; the moment it ran was. The first three lines of a fresh n8n's log:

    Initializing n8n process
    n8n ready on ::, port 5678
    Migrations in progress, please do NOT stop the process.

followed by five hundred lines of migration. n8n opens its listener, and
answers `/healthz` with `{"status":"ok"}`, before it has a schema. Compose
believed it, bootstrap believed compose, and the workflows were imported
into a database that did not exist yet. Both calls carried `|| true`.

Three separate things had to be wrong at once for this to be invisible,
and all three are common:

  - **a health check that tests the listener, not the service.** `/healthz`
    is a liveness probe answering "the process is up". `/healthz/readiness`
    answers for the database. Compose was asking the wrong one.
  - **`|| true` on a step whose failure is silent downstream.** It is
    there so a re-run does not abort on an already-imported workflow. It
    also swallowed the only report anyone would ever get.
  - **no confirmation.** The step imported and moved on. Nothing asked
    whether the import had worked, so nothing could notice that it had not.

The fix is all three. The health check reads readiness. The import waits
for `n8n list:workflow` to succeed — the database answering, not the port.
And it now imports, counts, and retries, and fails loudly after three
attempts rather than leaving a lab that detects faults and cannot act on
them:

    n8n has 0 of 2 workflows after three attempts.
    Nothing will act on a detected fault until this is fixed.

The general shape is worth keeping: **a step that cannot verify its own
result is not a step, it is a hope.** This one had been hoping since the
repository was created, and only failed on a machine slow enough for the
migration window to matter.

Also: after `docker compose restart n8n`, the container reports healthy
several seconds before the webhook is registered — so a check run
immediately afterwards correctly fails. That is not a false alarm. At that
instant a fault really would have gone unanswered.

## 64. ⭐ The automation raced the bootstrap, won, and spent the budget

A fault injected on a freshly built lab was refused:

    srl3  ethernet-1/1 on srl3 is administratively down
      [x] detected    14:03:16  salt-beacon:srl3
      [!] BLOCKED     14:03:39  circuit breaker: 3 changes to srl3
                                in the last hour

The circuit breaker was right. There really had been three changes to srl3
in the hour. The audit trail says who made them:

    13:56:00  change.applied  salt-reactor/config_drift  automation  golden_config
    13:57:50  change.applied  salt-reactor/config_drift  automation  sync_from_netbox
    13:58:03  change.applied  salt-reactor/config_drift  automation  bgp_policy

Not one record anywhere from `actor=bootstrap`, on a lab that had been
bootstrapped eight minutes earlier. Bootstrap's own provisioning step had
found nothing to do, because the drift reactor had already done all of it.

The ordering is the bug, and it is entirely ordinary. Step 3 syncs the
beacons to the minions, and a synced beacon starts watching immediately.
Step 4 seeds NetBox. Step 4b converges the devices. So for the couple of
minutes between step 3 and step 4b, every beacon was comparing a
freshly-deployed router against a source of truth that was filling up
underneath it — and the moment NetBox had content, all three routers were
"drifted" and the reactor converged them, one state at a time.

**The automation was correct at every step and the outcome was wrong.**
Provisioning is not self-healing. It got counted as self-healing because
nothing in the system distinguishes "this device has never been
configured" from "this device has drifted", and the only thing that could
have — the bootstrap's own `override`, which exists precisely to say
*this is planned work, not a fault* — never got to run.

The cost is specific and it is the kind that only shows up in front of an
audience: a lab built an hour before a demo is rate-limited out of its own
demo. Every device came up with two or three of its three hourly changes
already spent, by the automation, provisioning itself.

The maintenance freeze looked like the answer and is not. It outranks the
override by deliberate design (lesson: a freeze that an override can skip
is not a freeze), so bootstrap cannot converge through one. What is wanted
is narrower and more honest: **nothing watches until there is something
worth watching.** `beacons.disable` after the sync, `beacons.enable` once
the devices match intent, and the EXIT trap re-arms them if bootstrap dies
in between — because a lab whose beacons are off is the silent-total
failure this repository keeps re-discovering.

Two smaller things fell out of it.

`converge()` ended on a `grep`, which succeeds when it matches, so a
convergence that failed both attempts printed three lines into a wall of
output and returned 0. It now returns 1 and bootstrap stops. Third
instance of the same disease in three lessons.

And `check-lab.sh` could not have caught a disabled beacon: `beacons.list`
still returns the full list, and `config.get beacons_enabled` returns the
same empty string before and after a disable. So the check no longer reads
configuration at all — it asks Elasticsearch whether each device's
heartbeat has arrived in the last four minutes. One question that proves
the beacon fired, the event bus carried it, and the returner wrote it.
Verified by silencing srl2 and watching the pulse age out:

    t+80s   pulses: srl1 srl2 srl3
    t+100s  pulses: srl1 srl3

### 64a. The fix for 64 had the disease from 63

The first version of "silence the beacons during provisioning" put the
disable *after* `saltutil.sync_all` and sent its output to `/dev/null`.
Three proxy minions busy syncing every module do not answer promptly, so
some of them returned "Minion did not return", the disable never happened
on those, and nothing said so. The clean rebuild that was supposed to
prove the fix produced:

    14:44:58  fault.detected  bgp_session_down          (after the "disable")
    14:45:18  fault.detected  protocol_drift
    14:45:50  change.applied  salt-reactor/config_drift  golden_config

The budget went from 3/3 to 1/3, which looks like progress and is really
the same bug with a smaller blast radius. Two changes:

  - the disable now runs *before* `sync_all`, not after — the beacons are
    already loaded from the proxy config at container start, so the
    earliest possible moment is before the sync, not after it
  - it counts the confirmations and retries, and fails the bootstrap if
    all three minions have not said yes

That is the third time in four lessons that the failure was a step which
could not report failure — a swallowed `|| true`, a `grep` as a return
value, and now a `>/dev/null`. It is worth stating as a rule rather than
rediscovering: **in this repository, a command whose output is discarded
must either be idempotent and inconsequential, or verified afterwards.**

Two checks also had to learn patience. Run immediately after bootstrap,
`check-lab.sh` reported srl2's beacon silent and the fault webhook
unregistered — both true at that instant and both false a minute later.
A heartbeat is on a 60-second interval and the devices are not in step; a
restarted n8n answers its port before it registers a webhook. Both now
retry within a bounded window, and only when the first read fails, so a
healthy lab still answers instantly. A check that is right too early is
still wrong.

## 65. ⭐ The demo's most interesting forty seconds are also its heaviest

This lab is developed on a 16 GB laptop. The numbers do not fit, and it
took a recording to notice:

    host RAM                16.0 GB
    Docker VM allocated     11.7 GB
    llama3.1 when loaded     5.1 GB   (native on the host, not a container)

11.7 plus 5.1 is 16.8. The model runs *outside* Docker, so its arrival is
paid for in swap, and it arrives exactly when a fault is being decided.
Measured through one real decision with nothing else running:

    14:59:35  swap=4674M  free=34%  load=6.3   <- fault injected
    15:00:14  swap=7563M  free=27%  load=8.2   <- the model loads
    15:01:27  swap=5922M  free=56%  load=5.1   <- settled

Nearly three gigabytes of swap in forty seconds, while a screen recorder
writes video through the same window. Ollama also unloads after five
minutes idle, so every take pays for it again — and the stall lands on
detection-to-decision, which is the part worth filming.

`scripts/demo-mode.sh on` does two unsubtle things: it stops the services
the four-pane demo never opens (Kibana alone is ~1 GB), and it loads the
model with `keep_alive: 2h` so the 5.1 GB is already resident before the
recording starts. Same fault, same machine, afterwards:

                        cold model      pre-warmed
      swap spike        +2889 MB        +590 MB
      memory free       27%             56%
      peak load         8.17            5.91
      free in the VM    ~420 MB         ~1250 MB

Five times smaller, and the floor never gets near the danger zone. The
memory is still spent — it is spent *before* the take instead of during
it, which is the whole trick.

Two things to know before recording, both of which blocked a take here:

  - the per-device ceiling is 3 changes/hour, so re-taking on the same
    router four times in an hour will refuse the fourth, correctly
  - the blast radius is 2 distinct devices per 15 minutes, so a re-take on
    a *different* router within fifteen minutes gets refused too:

        [x] decided     15:05:21  n8n/llama3.1 — interface was administratively shut
        [!] BLOCKED     15:05:22  blast radius: 2 devices already changed in the last 15m
            the model decided; the gate refused anyway.

That second one is not an obstacle to film around. It is the best thirty
seconds in the system — the model says yes and the gate says no, one
second apart, and the audit trail records both. Film it on purpose.

## 66. ⭐ A proxy minion does not notice that its device was replaced

"The demo is not working." Six checks failed, and only the first one named
the cause:

    [FAIL] the links exist          nodes are running, cables are not
    [FAIL] proxy minions answer     only 0 of 3
    [FAIL] srl1 beacons loaded      missing: iface_down bgp_down ...
    [FAIL] srl2 beacons loaded      missing: ...
    [FAIL] srl3 beacons loaded      missing: ...
    [FAIL] beacons are actually firing   silent: srl1 srl2 srl3

Five of those six are the same failure wearing different clothes. The
routers had been up for 58 minutes without restarting, no container had
been OOM-killed, the clab network still existed with 16 containers
attached — and `ip -br link` inside srl1 showed only `lo`, `tunl0`,
`gre0`. Every veth pair was gone. That is a woken-up laptop: containerlab
builds the links in the VM's namespace and moves them into the nodes, and
when Docker Desktop's network is reset underneath, the containers survive
and their cabling does not.

`bootstrap.sh` already knew this — `links_up()` exists for exactly this
case (lesson: ask about a link, not about a container) — so it ran
`containerlab deploy --reconfigure` and the links came back. And the lab
still did not work.

`--reconfigure` does not restart a container. It **replaces** it. A proxy
minion holds an open session to its device, so all three were left talking
to containers that no longer existed — and they did not notice, because
nothing asked them to. They answered the master, reported healthy, and
returned "Minion did not return" for every device call.

The fix is one line of ordering, but it took the trap from lesson 61 to
find it. Bootstrap stopped and said so:

    == BOOTSTRAP DID NOT FINISH ==
    It stopped in: syncing beacons, modules and states to the proxy minions

It died at the beacon-silencing step, which counts confirmations and
refuses to continue without three (lesson 64a). Both of those guards were
written for a different bug, and both earned their keep here: without
them, bootstrap would have run to the end and printed its URLs over a lab
whose proxies were talking to ghosts.

So: the clab step now records whether it replaced the devices, and if it
did, the proxies are restarted before anything asks them to do work. The
wait loop that follows counts the answers rather than trusting the exit
code — with one proxy down, `salt 'srl*' test.ping` prints two successes
and returns non-zero, and the old loop only did the right thing by
accident.

Restarting the three proxies fixed it in fifteen seconds. Finding out that
was the fix took an hour, and would have taken longer without a check that
distinguishes "the container is running" from "the thing it is for works".

## 67. ⭐ The small models fail at the one thing that matters

The model was chosen the way models usually are: it was the one that was
installed. So before the talk, it got measured. `eval/model-bakeoff.py`
runs the production prompt -- parsed out of the n8n workflow rather than
copied, so the test and the running system cannot drift apart -- against
every fault the beacons raise, ten trials each.

    model         on disk   correct    refused correctly   median
    qwen2.5:7b     4.7 GB   160/160        40/40            1.1s
    llama3.1:8b    4.9 GB    77/80         18/20            1.5s
    gemma2:2b      1.6 GB    56/80          6/20            1.0s
    llama3.2:3b    2.0 GB    52/80          9/20            0.6s
    qwen2.5:3b     1.9 GB    45/80          0/20            0.8s

Two things fell out of it, and neither was the thing being looked for.

**The fourth column is the whole story.** Every model heals the easy
faults: an admin-shut port, a description that drifted, an MTU that
disagrees. What separates them is the two cases where the correct answer
is *do not touch this* -- a physical link down, and a prefix limit at 91%.
qwen2.5:3b got that right **zero times out of twenty**. On a dead link it
answered `restore_interface` ten times out of ten. It is not slightly
worse than the 7B models; it is a model that always acts, which is the one
property this system cannot tolerate.

llama3.2:3b managed to be wrong in both directions at once: it refused a
fault it should have healed seven times in ten, and acted on one it should
have refused. Fast, small, and useless.

qwen2.5:3b also produced `bgp_prefix_limit` as its answer five times --
the name of the *fault*, not of any template. An invented name, which is
exactly what the whitelist exists to stop, and it stopped it. That control
had been argued for; now it has been watched working.

**And the winner was not a trade-off.** qwen2.5:7b is better than
llama3.1:8b on every axis at once: more accurate (160/160 against 77/80),
faster (1.1s against 1.5s), and smaller in memory (4.6 GB against 5.1).
There was no cost to weigh. The default is now qwen2.5:7b.

The other measurement was the useful one for the architecture. **Inference
takes 1.1 seconds.** The twenty-seven seconds between a beacon detecting a
fault and the model answering are Grafana's 10s evaluation interval, plus
`for: 10s`, plus n8n. The model was never the slow part, so a smaller
model buys memory and nothing else -- and on this evidence, not even that.

Three trials, by the way, said llama3.1 scored 24/24. Ten trials said
77/80. A number small enough to be convenient is usually too small to be
true.

## 68. ⭐ The gate was one HTTP field away from being optional

An independent audit before publication found the change gate authorising
itself. Every remediation state begins:

    {%- set override = pillar.get('override', '') %}
    {%- set actor_type = pillar.get('actor_type', 'automation') %}

and salt-api calls carry `kwarg: {pillar: {...}}` — the workflow already
uses it, for `interface` and `peer`. eauth can restrict the **function**
and the **target**. It cannot restrict kwargs. So anything holding
`SALT_API_SECRET` could send

    kwarg: {pillar: {override: "x", actor_type: "human"}}

and skip the rate limit and the blast radius together, with the resulting
change filed as a *human* one and therefore invisible to `recent(
unattended_only=True)`, to `devices_changed()`, and to n8n's own breaker.
Unlimited unattended change, recorded as an operator at the keyboard.

Two lessons, and the second is the uncomfortable one.

**A permission asserted by the caller is not a permission.** The override
exists for a real case — initial provisioning, where every device
legitimately needs converging and the blast radius correctly refuses the
third. The mistake was carrying that authorisation in the same channel as
the parameters. It is now a marker file in the master's `file_roots`:
bootstrap creates `salt://.provisioning` for the seconds it converges and
removes it afterwards, its EXIT trap removes it if the run dies, and
`check-lab.sh` fails if one is ever found open. A salt-api caller cannot
create a file on the master. An override asked for without the window is
refused *and recorded*, so the attempt lands in the same audit trail as
everything else.

**And the documentation said the opposite, confidently.** README and
`docs/architecture.md` both claimed *"their parameters are looked up in
pillar rather than taken from the caller, so nothing can smuggle a value
through."* That is true of `interface`, `peer` and `mtu`, which are
membership-checked against pillar. It was never true of `override`,
`actor_type`, `actor` or `trace_id`, which were read straight from the
caller's pillar and not checked at all. The sentence was written about the
half that was defended, and then believed about the whole.

The same audit found `risky_change.sls` — a teaching example of the revert
timer — still in `file_roots`, using `netconfig.managed` instead of
`audited.config`: no gate, no rate limit, no audit record, and free-text
`interface`, `text` and `revert_in` from the caller. The whitelist that
was supposed to contain this lives in JavaScript inside n8n; the boundary
is the eauth rule, and the eauth rule permitted it. It is deleted. The
demo on the slide never used it — that capture was made with
`netsafe.push_confirmed` directly.

And `golden_config`, `sync_from_netbox` and `sync_from_pillar` declared no
`verify:`, so `audited.py` armed no revert timer for any of them
(`arm = revert_in if (verify and revert_in) else None`) while the README,
the architecture doc and the talk all said *every* remediation declares an
outcome check and commits under a revert timer. Three of seven did not —
including the two the drift reactor fires most often, and the one that
rewrites IS-IS, BFD and iBGP across the whole device.

`golden_config` now checks the outcome that matters: the fabric still has
its adjacencies afterwards. The count comes from pillar, never from the
caller, because a remediation must not be able to lower the bar it is
judged against. `sync_from_netbox` and `sync_from_pillar` keep their
reasoned no-check — for them the configuration *is* the end — and the
claim has been narrowed to say so.

The audit found twenty-eight things. That it was worth running is not the
lesson. The lesson is that every one of these had been read past, by
someone who knew what the code was supposed to do.
