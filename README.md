# selfheal-lab

A self-healing network on a laptop: SaltStack detects the fault, a local
LLM picks the runbook, Salt applies it under the device's own revert timer,
and the change is kept only if the network actually recovers.

Built for a talk at mnNOG 8 — *Self-healing network: what actually breaks
it*. Everything here runs, on one laptop. Nothing in it is a diagram of an
intention: every control described below can be switched off and watched to
fail.

```
fault on a device, or between two devices
  → a Salt beacon notices, and mints a trace id          (2-14s, interval-bound)
  → Salt event bus → Elasticsearch
  → Grafana alert rule → webhook
  → n8n asks a local qwen2.5:7b which runbook applies
  → whitelist gate     a name that is not on the list stops here
  → change gate        freeze? rate limit? blast radius? audit store up?
  → salt-api → NAPALM → the router, committed with a revert timer armed
  → verify the OUTCOME, not the config
  → confirmed if the network recovered; reverted by the device if not
```

Measured over ten consecutive interface faults, rotating across all three
routers: **median 43s** from `admin-state disable` to the fault closing,
min 37s, max 48s, every stage recorded on every run. The spread is small
because the slowest step is a beacon interval and those are fixed.

A route leak takes longer and varies much more — median 99s over nine runs,
min 39s, max 300s — and almost none of that is the repair, which takes 7
seconds from push to verified. The rest is the alerting layer: the leak case
always raises the same device and fault, so consecutive runs are paced by the
notification policy's repeat interval rather than by anything in Salt.

`./scripts/soak.sh` produces these numbers, and `docs/commands.md` explains
why the two fault classes do not run on the same clock.

## What's in it

| | |
|---|---|
| **Devices** | 3 × Nokia SR Linux + 1 × FRR, in containerlab, native arm64, free, no account |
| **Topology** | A core triangle (srl1–srl2–srl3), and srl3 is the border router |
| **Routing** | IS-IS L2 + BFD, iBGP AS 65001 with srl1 and srl2 as route reflectors, eBGP to AS 64500 |
| **The upstream** | srl4 runs FRR, has no proxy-minion, and no automation may reach it |
| **Automation** | Salt master + one proxy-minion per *managed* device, NAPALM `srlinux` driver |
| **Source of truth** | NetBox — devices, interfaces, and the BGP policy the border router announces |
| **Observability** | Elasticsearch, Kibana, Grafana + alerting, every container's logs |
| **Audit** | append-only `napalm-audit` data stream, one trace id per outage |
| **Decision layer** | n8n calling a local Ollama model, no cloud API |
| **Action** | salt-api, scoped to `state.apply` on `srl*` and nothing else |

## The faults it detects

Five it heals, and three it deliberately refuses to.

1. **Interface down** — a monitored interface is administratively disabled
2. **P2P MTU mismatch** — the two ends of a link disagree. Neither device's
   own config is wrong; the link is dead anyway. Detected through the
   **Salt mine**, which is how one minion reads another's state.
3. **Config drift** — an interface description edited by hand, reverted to
   whatever the source of truth says — NetBox or pillar, same reactor
4. **BGP session down** — an iBGP session that is no longer established
5. **Route leak** — the border router is announcing prefixes to transit
   that NetBox does not permit. Every other detector here compares
   *configuration* to intent and would pass: a leak is a config that looks
   right and behaves wrongly. This one reads the post-policy adj-rib-out —
   what actually went out the session — and the remediation is verified the
   same way, so the proof that a leak stopped is that the prefixes are no
   longer being advertised:

   ```
   00:20:22  change.applied   success  policy_drift
   00:20:29  change.verified  success  198.51.100.0 is being offered
                                       only 203.0.113.0/24
   ```

And three with no runbook, on purpose:

5. **Link down** — the interface is enabled and the link is down anyway: a
   cut fibre, a dead transceiver, the far end shut. Nothing Salt can push
   to this router will light that link, so the model is expected to decline
   — and it does. Over ten runs it declined the far end ten times out of ten,
   at a median of 33s:

   ```
   07:42:09  fault.detected      interface_link_down
   07:42:24  decision.declined   "no configuration change can fix a
                                  physical link down issue"
   ```

   Reporting this as an ordinary interface fault would be worse than not
   detecting it: the model would pick `restore_interface`, the push would
   be an idempotent no-op, and the trail would fill with changes that did
   nothing to a link nobody went to look at.

6. **BGP prefix limit approaching** — the upstream is announcing far more
   than it should. Raising the limit automatically is precisely the wrong
   answer: the limit is the thing protecting you, and widening it under
   pressure disables the safety device because the safety device went off.
   Proven on a real cross-vendor eBGP session, with the upstream leaking
   903 prefixes at a limit of 1000:

   ```
   23:31:08  fault.detected     bgp_prefix_limit  903 of 1000 (90%,
                                                  warns at 80%)
   23:31:40  decision.declined  "Capacity or threshold problem, not
                                 configuration drift"
   ```

7. **A device that has gone quiet** — found by a watchdog outside Salt
   entirely, because a beacon cannot report that its own minion is dead.
   See below.

## Where the AI sits, and where it does not

The model picks a **name** from a fixed whitelist and nothing else. It does
not write configuration and has no path to a device: `salt-api` accepts one
function, `state.apply`, on `srl*` only, and a state name that does not
exist in `salt/states/` fails closed. Remediation templates are two to four
lines of Jinja, written and reviewed by a human, and their parameters are
looked up in pillar rather than taken from the caller, so nothing can
smuggle a value through.

If no runbook fits, the model is expected to answer `"none"` — and it does.
That answer becomes a ticket for a human instead of a config push.

### Being precise about what that buys

The whitelist makes an *invented* runbook impossible. It does nothing about
a real runbook chosen for the wrong fault.

And idempotence does not cover that gap either, which is the thing worth
saying out loud. A state that reliably drives a device to the same
configuration proves the configuration matches the template. It proves
nothing about whether that configuration was the right thing to want, and
re-applying a wrong-but-idempotent state across a fleet, confidently, is
precisely how this breaks at scale.

So the containment is elsewhere, in four places:

* **Templates are narrow and idempotent**, so a wrong-but-allowed choice is
  usually a no-op rather than an outage.
* **A remediation that repairs something declares a check on its outcome**,
  separate from the config it writes — the interface is operationally *up*,
  the adjacency formed, the session reached established, the prefixes
  actually withdrawn. An interface can be admin-enabled and still down.

  Five of the seven do this. The two that do not are `sync_from_netbox` and
  `sync_from_pillar`, and the reason is in the states themselves: for every
  other remediation the config is a means and the network is the end, so
  the config converging is not evidence the change worked. For those two
  the config *is* the end — the whole point is that the device matches its
  source of truth. What deserves scepticism there is not whether the push
  worked but whether the source of truth is right, which is what the
  fleet-wide blast radius is for.

  `golden_config` belongs in the first group and checks that the fabric
  still has its adjacencies afterwards. Pushing the whole protocol layer is
  precisely the change whose risk is that it converges cleanly and the
  adjacencies drop, so the config converging proves nothing.
* **Changes that declare a check and fail it are not kept.** Those commits
  are made with the device's own revert timer armed and confirmed only if
  the check passes, so a change that does not produce its intended outcome
  is rolled back by the router on its own clock — which still works when
  what failed is Salt, the master, or the network path between them. The
  two convergence states above commit directly; they have no check to
  confirm against, and arming a timer nothing can confirm would revert
  every change by default.
* **The blast radius is bounded.** At most two *distinct* devices may be
  changed in any fifteen minutes. This is a different control from the
  per-device rate limit for a reason: one bad row in the source of truth
  faults every device at once, and each of those remediations is
  individually within its per-device budget.

A whitelist stops the model inventing a template. It does not stop the
model picking a real one that does not address the fault — and because these
templates are idempotent, a wrong choice succeeds, changes nothing, and looks
handled. That is what the outcome checks above are for: a remediation that
repairs something has to prove the network recovered, not that the push
returned success.

## What this lab does not do

The route-leak case invites a fair question from anyone who runs a network:
there are standard controls for this, so where are they? They are not here,
and the scope is deliberate rather than accidental.

**RFC 9234 BGP Roles and the Only-To-Customer attribute** are the actual fix.
A session declares whether the peer is a customer, a provider, a peer or an
RS, the OTC attribute is set accordingly, and a leak is then detected and
rejected by the receiving router with no monitoring involved at all. Nothing
in this lab substitutes for that. If you can deploy OTC on a session, deploy
it; what this lab is for is the networks that cannot yet, which is still most
of them, and the question of how you find out when one of them leaks.

**RPKI origin validation** does not stop leaks, and it is worth being precise
about why, because the two get conflated. ROV answers "is this AS entitled to
originate this prefix?" A leak has a perfectly entitled origin and the wrong
reach. ROV is essential and it is orthogonal; this lab implements neither it
nor the ASPA work that does address path scope.

**BMP** — RFC 7854, with adj-rib-out monitoring in RFC 8671 — is how the data
this lab polls for should be obtained in production: the router streams its
post-policy adj-rib-out to a collector, rather than something asking it every
thirty seconds. The SR Linux container image used here has no BMP in its
schema, which is why the beacon polls. On real hardware, this detector should
be a BMP consumer.

**MANRS** is the frame most of this belongs in. The export policy, the bogon
prefix-set and the 1000-prefix limit on the transit session are Action 1,
filtering, done at the scale of one customer edge. The lab does not implement
anti-spoofing, coordination or global validation data — Actions 2, 3 and 4.

**IRR** is where an export set comes from in a real network, and where it gets
cross-checked. Here it comes from NetBox, because the point being made is
about a source of truth and a device disagreeing, not about which registry
holds the truth. A production version of this reconciles the two.

None of the above is hard to add to a lab. They are left out so that what is
here can be read in an afternoon, and because the thing being demonstrated —
that a detector comparing configuration to intent is structurally blind to a
valid configuration behaving wrongly — is true whether or not OTC is deployed.

## Who changed what, and when

Every automated change is attributable end to end. A `trace_id` is minted
by the beacon that first sees the fault and carried through the event bus,
the alert, the workflow, the model's answer, the salt-api call, the state
run — and onto the device:

```
A:srl3# info from state /system configuration checkpoint *
    checkpoint 0 {
        comment "selfheal trace=srl3-20260916T075658Z-36367a actor=n8n/qwen2.5:7b state=restore_interface"
        created "2026-09-16T07:57:22.986Z"
    }
```

Someone with a CLI session on that router and no access to Salt,
Elasticsearch or a ticket system can still see which automated decision
changed it.

The trace lives on the *checkpoint*, not the commit, and that is not an
accident of implementation. An automated change is committed with the
device's revert timer armed, and SR Linux's `commit confirmed` takes no
comment — so the driver writes the message onto the checkpoint it creates
immediately before the change. Which is the better place for it: the
checkpoint is the rollback anchor, so the trace id names exactly the point
you would roll back to. The same id in Kibana gives the whole story:

```
05:12:04  fault.detected     open      salt-beacon:srl3
05:12:28  decision.made      accepted  n8n/qwen2.5:7b      restore_interface
05:12:34  change.applied     success   n8n/qwen2.5:7b      (3.4s, revert timer armed)
05:12:36  change.verified    success   n8n/qwen2.5:7b      ethernet-1/1 is up
05:12:37  fault.resolved     resolved  salt-beacon:srl3  33.2s
```

`napalm-audit` is an Elasticsearch **data stream**, which rejects
update-by-id and delete-by-id outright, and no role in `es/roles.json`
holds a delete privilege on it. Nothing in this stack can edit or remove
its own audit record, including the component that wrote it.

Container logs from every service — twenty of them, the routers included
— land in `lab-logs` on the same time axis, so "what did the whole system do
between 05:12:04 and 05:12:37" is one Kibana query rather than nine
terminals.

### Watching the watcher

Everything above detects faults by observing devices. Nothing observed
whether that observation was still happening — until all three routers were
stopped by a Docker restart and stayed down for an hour and forty-five
minutes while every service reported healthy and the alert rule sat at
`state: inactive`. The beacons could not reach the devices, so they emitted
nothing, and to anything counting events, silence is indistinguishable from
health.

`collector/watchdog.py` asks the one question the rest of the system
structurally cannot — *when did each device last say anything at all* — and
runs outside Salt and outside the pipeline it watches. A beacon cannot
report that its own minion is dead; a master cannot report that its own
event bus has stopped reaching Elasticsearch. When Elasticsearch is what
broke, the watchdog says that instead of having an opinion about devices.

## Running it

Requires Docker (Desktop is fine), about 10GB of RAM for the whole lab, and
[ollama](https://ollama.com) running natively on the host — natively, so it
gets the GPU.

```bash
ollama serve &
ollama pull qwen2.5:7b

./scripts/gen-secrets.sh    # writes .env, mode 0600, gitignored
./scripts/bootstrap.sh      # routers, stack, Salt sync, NetBox, workflows
./scripts/check-lab.sh      # is it complete, or merely running?
```

`bootstrap.sh` is idempotent and ends by running `check-lab.sh`. Everything
it cannot do declaratively is in there because compose cannot express it:
containerlab needs its own privileged run, and Salt has to be told to sync
the custom beacons before anything is ever watched.

`check-lab.sh` is the one worth knowing about. It does not ask whether the
services are alive — compose already does that. It asks whether they are
wired to *each other*: the veth pairs exist and not merely the nodes, the
beacons are loaded and not merely the proxies, NetBox holds devices and
not merely a 200, the fault webhook answers and not merely n8n's port,
Salt events are landing in Elasticsearch and not merely that the cluster
is green. Each failure carries the command that repairs it, and the exit
code is the number of failures.

It exists because a half-finished bootstrap and a finished one leave
identical evidence — every container up, every health check green — and the
difference only surfaces minutes later, as a fault that is detected and then
never acted on.

| Service | URL | Login |
|---|---|---|
| NetBox | http://127.0.0.1:8000 | `admin` / see `.env` |
| Kibana | http://127.0.0.1:5601 | `elastic` / see `.env` |
| Grafana | http://127.0.0.1:3000 | `admin` / see `.env` |
| n8n | http://127.0.0.1:5678 | owner account created on first visit |
| salt-api | http://127.0.0.1:8001 | shared secret, see `.env` |

Ports bind to `127.0.0.1`. There is no TLS anywhere inside the stack and no
operator authentication in front of it, so nothing here is safe on a LAN
without termination and an auth layer ahead of it.

## Watching it work

```bash
./scripts/break.sh interface srl3   # or: mtu, bgp, drift, leak, unknown
./scripts/break.sh prefixes 900     # the upstream leaks a table at you
./scripts/unbreak.sh prefixes       # withdraw it — nothing else will
```

`prefixes` is the one fault the automation will never clean up, and that is
correct: it happens on srl4, which is somebody else's router. You do not
fix your upstream's mistakes, you phone them.

Then, without touching anything:

```bash
docker exec salt-master salt srl3 audit.history device=srl3
docker exec salt-master salt-run state.event pretty=True
docker exec clab-selfheal-srl3 sr_cli "info from state /system configuration checkpoint *"
```

`./scripts/break.sh unknown` posts a fault no template addresses, and the
model declines. That is the run worth watching, not the one that works.

Other things worth trying:

```bash
# freeze all automated change, the way you would before planned work
sed -i 's/enabled: false/enabled: true/' salt/pillar/maintenance.sls
docker exec salt-master salt '*' saltutil.refresh_pillar
./scripts/break.sh interface srl3     # detected, recorded, and refused

# what has actually been changed, fleet-wide, in the last 15 minutes
docker exec salt-master salt srl3 audit.devices_changed
```

## Operations

```bash
./scripts/backup.sh          # ES snapshot, NetBox pg_dump, n8n, Salt PKI
./scripts/restore.sh <dir>
./scripts/gen-traffic.sh     # put real traffic across the links
```

## Credentials

There are none in this repository. `scripts/gen-secrets.sh` generates
`.env`, which is gitignored and mode 0600, and everything reads from it:
compose directly, the Salt configs through `salt/entrypoint.py`, the Salt
pillar through `environ.get`, and the n8n workflows through `$env`.

The one exception is the SR Linux password, which `gen-secrets.sh` leaves
at Nokia's documented default, because the containerlab nodes are built
with it. Change it on the devices first.

**This is a lab, not a product.** It is built to be believed on a laptop, in
front of an audience, and it has not been run at scale, behind TLS, or with
operator authentication. Treat every control in it as a design worth copying
and none of it as hardened. Anything pointed at real equipment needs its own
threat model, its own secret management, and its own scale test first.

## Documentation

| File | What's in it |
|---|---|
| [`docs/commands.md`](docs/commands.md) | Every command worth running, per box — routers, Salt, NetBox, Elasticsearch, the UIs |
| [`docs/reviewing.md`](docs/reviewing.md) | How to get inside every component, and what to read once you are in |
| [`docs/architecture.md`](docs/architecture.md) | How the pieces are wired, and what each one is trusted with |
| [`docs/flow-design.md`](docs/flow-design.md) | The pipeline, and the fault cases it was built around |
| [`docs/addressing.md`](docs/addressing.md) | Every address in the lab, and which file is the source of it |
| [`napalm-logs/README.md`](napalm-logs/README.md) | The SR Linux syslog profile, and push detection measured against poll |

`docs/commands.md` is the one to open first if the lab is running and
something looks wrong.

## Licence

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Use it and change it. The licence asks for one thing back: keep the NOTICE
with it. There is a patent grant in both directions, which is the practical
reason to prefer Apache over MIT for anything a company might build on.

The components this pulls in have their own licences, and three of them —
Elasticsearch, Grafana and n8n — carry conditions worth reading before
this becomes part of something commercial. They are listed in NOTICE.
