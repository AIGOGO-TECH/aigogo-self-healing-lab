# Command reference

Everything you can ask this lab, grouped by the box you ask it on. Each
command is one that was run against a live lab, not one that ought to work.

Two rules save most of the debugging time:

- **Run `./scripts/check-lab.sh` first.** Containers stay up while their
  cabling does not — a laptop that slept loses the veth pairs but keeps every
  container `Up`, so `docker ps` looks perfect while the fabric is dark.
  check-lab asks whether the parts are wired to each other, and each failure
  prints its own fix.
- **Not every device has every command.** `srl1` and `srl2` are core; `srl3`
  is the only border router and the only one with transit policy, a route-leak
  beacon, or an eBGP session. `srl4` is the transit provider and runs FRR, not
  SR Linux. Asking srl1 for `transit-out` returns an empty prompt, not an
  error — see [Why a command returns nothing](#why-a-command-returns-nothing).

---

## 0. The fastest possible health check

```sh
./scripts/check-lab.sh          # exit code = number of failed checks
./scripts/evidence.sh 30        # everything the system did in the last 30 min
```

---

## 1. Routers — SR Linux (srl1, srl2, srl3)

### Getting in

```sh
docker exec -it clab-selfheal-srl1 sr_cli      # interactive
docker exec clab-selfheal-srl1 sr_cli "show version"   # one-shot, scriptable
```

Inside the CLI: `quit` to leave, `?` for options, `tree` to explore the
schema. `info` reads config; `info from state` reads operational state.

### What every router can answer

| Question | Command |
|---|---|
| Are my IS-IS neighbours up? | `show network-instance default protocols isis adjacency` |
| Are my BGP sessions up? | `show network-instance default protocols bgp neighbor` |
| Is BFD holding the link? | `info from state /bfd network-instance default` |
| What is in the routing table? | `show network-instance default route-table ipv4-unicast summary` |
| Are the interfaces up, and at what MTU? | `show interface brief` / `info interface ethernet-1/1` |
| Who changed me, and when? | `info from state /system configuration checkpoint *` |
| What is my whole protocol config? | `info /network-instance default protocols` |
| Roll back the last change by hand | `tools system configuration checkpoint 1 load` then `commit now` |

The checkpoint list is the single most useful read on a router in this lab.
Every automated change writes one, and the comment carries who and why:

```
checkpoint 0 {
    name NAPALM-31475f07-2
    comment "selfheal actor=bootstrap state=sync_from_netbox"
    created "2026-09-28T06:56:35.997Z"
}
```

`actor=` is the account, `state=` is the Salt state that ran. A checkpoint
with no `selfheal` comment was made by a human or by containerlab.

### srl3 only — the border router

```sh
docker exec -it clab-selfheal-srl3 sr_cli
```

```
# the export policy — this is what a route leak breaks
info /routing-policy policy transit-out
info /routing-policy policy transit-in
info /routing-policy prefix-set our-aggregates

# what we are actually offering the provider, after policy
show network-instance default protocols bgp neighbor 198.51.100.0 advertised-routes ipv4
show network-instance default protocols bgp neighbor 198.51.100.0 received-routes ipv4

# the transit session itself
show network-instance default protocols bgp neighbor 198.51.100.0
```

Policies that exist on srl3 and nowhere else: `transit-in`, `transit-out`.
Prefix-sets: `bogons`, `our-space`, `our-aggregates`, `transit-acceptable`.
`ibgp-next-hop-self` exists on all three.

### srl4 — the transit provider (FRR, different CLI)

srl4 is not ours. It is the account that settles a route-leak argument,
because our own adj-rib-out is us saying what we think we sent.

```sh
docker exec -it clab-selfheal-srl4 vtysh
```

```
show bgp ipv4 unicast summary          # PfxRcd is the number that matters
show bgp ipv4 unicast                  # every prefix we leaked into them
show bgp neighbors 198.51.100.1 received-routes
show ip route bgp
```

In a clean lab `PfxRcd` is **1**. During a leak it goes to 10. That single
column moving 1 → 10 → 1 is the demo.

```sh
./scripts/show-leak.sh     # the same view, grouped by what each prefix is
```

### Device logs

```sh
docker exec clab-selfheal-srl3 tail -f /var/log/messages
./scripts/watch-device.sh            # all three, formatted for commits
```

---

## 2. Salt

```sh
docker exec -it salt-master bash
```

### Is the control plane alive

```sh
salt 'srl*' test.ping                 # three True, or the proxies are stale
salt-key -L                           # accepted minions
salt 'srl*' grains.items              # what Salt thinks each device is
```

If `test.ping` says *Minion did not return*, the routers were replaced under
the proxies. Fix from the host, not from inside:

```sh
docker restart salt-proxy-srl1 salt-proxy-srl2 salt-proxy-srl3
```

### Reading the device through Salt (NAPALM)

```sh
salt srl1 net.arp
salt srl1 net.interfaces
salt 'srl*' net.cli "show network-instance default protocols isis adjacency"
```

### The custom modules — this lab's own vocabulary

`audit` — the audit trail, from the minion's side:

```sh
salt srl3 audit.open_faults                 # faults raised and not yet resolved
salt srl3 audit.recent 30                   # last 30 minutes of records
salt srl3 audit.history                     # every change this device has seen
salt srl3 audit.devices_changed 60          # blast radius in the last hour
salt srl3 audit.change_allowed state=bgp_policy device=srl3   # would the gate say yes right now?
```

`srlstate` — state reads that beacons use:

```sh
salt srl3 srlstate.advertised_to 198.51.100.0     # post-policy adj-rib-out
salt srl3 srlstate.bgp_prefix_counts              # received/active/rejected per peer
salt srl1 srlstate.get /interface[name=ethernet-1/1]
```

`verify` — outcome checks. These are what states use to decide a change
worked, and they poll rather than sample once:

```sh
salt srl3 verify.advertises_only 198.51.100.0 '["203.0.113.0/24"]'
salt srl1 verify.isis_adjacencies 2
salt srl3 verify.bgp_established 198.51.100.0
salt srl3 verify.interface_up ethernet-1/1
```

A healthy `advertises_only` returns:

```
detail:    198.51.100.0 is being offered only 203.0.113.0/24
verified:  True
waited_s:  1
```

`netsafe` — the confirmed-commit layer:

```sh
salt srl1 netsafe.pending          # is a change sitting unconfirmed?
```

### Beacons — the detection layer

```sh
salt 'srl*' beacons.list
salt srl3 beacons.list              # srl3 has route_leak; srl1/srl2 do not
salt 'srl*' beacons.disable         # stop all detection (bootstrap does this)
salt 'srl*' beacons.enable
```

| Beacon | Interval | Watches |
|---|---|---|
| `heartbeat` | 60s | proves the device is still producing events at all |
| `iface_down` | 15s | a monitored interface went admin-down |
| `bgp_down` | 20s | a session left `established` |
| `p2p_mismatch` | 20s | the two ends of a link disagree on MTU |
| `config_drift` | 20s | running config ≠ NetBox |
| `config_drift_golden` | 30s | the protocol layer drifted from the golden config |
| `config_drift_policy` | 30s | the export/import policy drifted — border only |
| `prefix_limit` | 30s | the upstream is sending more than we agreed to accept |
| `route_leak` | 30s | we are announcing prefixes we are not allowed to — **srl3 only** |

`config_drift_pillar` exists as a second source-of-truth variant and is
loaded but not scheduled by default.

### Pillar — source of truth #2

```sh
salt srl1 pillar.items                      # everything, secrets masked
salt srl1 pillar.get fabric:devices:srl1
salt srl1 pillar.get isis_adjacencies
salt srl1 pillar.get maintenance
salt srl3 pillar.get device_truth           # srl3 only, per top.sls
```

Files, all under `salt/pillar/`:

| File | Holds |
|---|---|
| `top.sls` | which pillar reaches which minion |
| `fabric.sls` | ASNs, loopbacks, link addressing, IS-IS keychain, RR topology |
| `topology.sls` | p2p links with MTU, monitored interfaces, expected adjacency counts |
| `netbox.sls` | NetBox URL + token, read from the master's environment |
| `maintenance.sls` | the blast-radius gate: `max_changes_per_hour`, `max_devices_per_window`, `fleet_window_minutes`, `bgp_settle_seconds` |
| `srl3.sls` | the pillar-as-source-of-truth demo — one interface description |

`maintenance.sls` is the file to open when a change is refused. It is what
`audit.change_allowed` reads.

### States — the remediation layer

```sh
salt srl1 state.apply golden_config test=True     # dry run, always safe
salt srl1 state.apply golden_config               # converge the protocol layer
salt srl1 state.apply sync_from_netbox            # converge to NetBox
salt srl1 state.apply sync_from_pillar            # converge to pillar
salt srl3 state.apply bgp_policy                  # rebuild the export policy — fixes a leak
salt srl3 state.apply restore_interface           # bring a shut interface back
salt srl3 state.apply restore_bgp_neighbor        # un-shut a session
salt srl1 state.apply fix_p2p_mtu                 # make both ends agree
salt-run jobs.list_jobs                           # what has run
salt-run jobs.lookup_jid <jid>                    # what one job did
```

Every one of these goes through `audited.config`, which means: take a
checkpoint, ask `audit.change_allowed`, push with a revert timer, run the
state's `verify:` function, and confirm only if verification passed. A state
that cannot verify reverts itself — that is the confirmed-commit behaviour, and
it is why `test=True` is not the only safe way to run these.

### The event bus and the reactor

```sh
salt-run state.event pretty=True          # raw feed, everything
./scripts/watch-events.sh                 # the same feed, human-readable
```

The reactor is deliberately narrow — one rule, in `salt/master.d/reactor.conf`:

```
'salt/beacon/*/config_drift*/drift'  ->  salt://reactor/heal_drift.sls
```

`heal_drift.sls` will only apply `sync_from_netbox` or `sync_from_pillar`, and
only to the minion named in the event *tag* — a forged `id` in the event body
is dropped. Everything else reaches remediation through n8n instead.

### salt-api — the only door the LLM has

`salt/master.d/api.conf`, port 8000 inside the container:

- eauth is `sharedsecret`, user `n8n`
- srl1, srl2, srl3 named one at a time — srl4 is absent on purpose
- the only permitted function is `state.apply`

So the worst an LLM can do is name a state file that does not exist, and get a
failed job. It cannot run arbitrary commands, cannot reach runners or the
wheel, and cannot push raw config.

```sh
docker exec salt-master cat /etc/salt/master.d/api.conf | grep -v secret
```

---

## 3. NetBox — source of truth #1

`http://127.0.0.1:8000` — user `admin`, password from `grep NETBOX_SUPERUSER_PASSWORD .env`.

### What is in it

| Object | Count | Notes |
|---|---|---|
| Sites | 3 | DC1 Primary Core, DC2 Secondary Core, POP3 Regional Edge |
| Device roles | 2 | Core Router (srl1, srl2), Edge Router (srl3) |
| Platforms | 1 | Nokia SR Linux 24.10.1 |
| Devices | 3 | srl4 is **not** in NetBox — it is the provider, not ours |
| Interfaces | 13 | with MTU and description — what `config_drift` compares against |
| IP addresses | 13 | loopbacks, p2p /31s, mgmt |
| Prefixes | 7 | see below |

```
10.255.0.0/24    Loopbacks — one /32 per router, IS-IS advertised
10.255.1.0/24    Infrastructure point-to-point links, /31 each
172.30.30.0/24   Out-of-band management
198.51.100.0/31  Transit interconnect — provider space, not ours
203.0.113.0/24   Customer aggregate — what we announce to AS64500
203.0.113.0/26   Site A customers
203.0.113.64/26  Site B customers
```

The two /26s are originated but **not** exported. They are the leak: a policy
mistake that starts announcing more-specifics of your own aggregate is RFC 7908
Type 6, and it is the most common kind there is.

### Where the BGP intent lives

Not in a config context object — `extras/config-contexts` is empty. It is on
**srl3's `local_context_data`**, because a config context attached to a role
would have merged into all three devices and made every router report a border
policy it does not have.

UI: *Devices → srl3 → Config Context* tab.
API:

```sh
T=$(grep '^NETBOX_API_TOKEN=' .env | cut -d= -f2-)
curl -s -H "Authorization: Token $T" \
  "http://127.0.0.1:8000/api/dcim/devices/?name=srl3" | python3 -m json.tool | less
```

This is the object `bgp_policy.sls` renders from and `config_drift_policy`
compares against. Editing it in the NetBox UI and watching the border router
converge is the source-of-truth demo.

### Useful API reads

```sh
T=$(grep '^NETBOX_API_TOKEN=' .env | cut -d= -f2-)
B=http://127.0.0.1:8000/api
curl -s -H "Authorization: Token $T" "$B/dcim/devices/?limit=10"
curl -s -H "Authorization: Token $T" "$B/dcim/interfaces/?device=srl3"
curl -s -H "Authorization: Token $T" "$B/ipam/prefixes/?limit=20"
curl -s -H "Authorization: Token $T" "$B/core/object-changes/?limit=10"  # who edited what (NetBox 4 path)
```

The changelog is the NetBox-side counterpart to the device checkpoints: it
answers *who changed the intent*, where checkpoints answer *who changed the
device*.

### Re-seeding

```sh
docker exec netbox python3 /opt/seed.py            # idempotent
docker exec netbox python3 /opt/policy-context.py  # rewrite the BGP intent
./scripts/seed-netbox.sh
```

---

## 4. Elasticsearch — the audit trail

Port 9200 is **not published to the host**. Everything goes through the
container:

```sh
P=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
docker exec elasticsearch curl -s -u "elastic:$P" \
  "http://localhost:9200/_cat/indices?v&h=index,docs.count,store.size"
```

| Index / data stream | Holds |
|---|---|
| `napalm-audit` | **the audit trail** — every fault, decision, change, verification |
| `napalm-remediations` | what the LLM proposed and the workflow accepted |
| `napalm-rejected` | what the whitelist refused |
| `napalm-escalations` | what nothing could handle |
| `napalm-YYYY.MM.DD-v1` | parsed device syslog (napalm-logs) |
| `lab-logs` | container logs from every service |
| `docker-stats` | per-container CPU and memory |

### The audit record

```json
{
  "@timestamp": "2026-09-28T07:25:02Z",
  "action": "device.heard",
  "outcome": "resolved",
  "trace_id": "srl2-20260928T071358Z-526618",
  "actor": "watchdog",
  "device": "srl2",
  "fault": "device_silent",
  "reason": "srl2 is producing events again after 664s"
}
```

`trace_id` ties a whole incident together, from the beacon that saw it to the
verification that closed it. Sort by `@timestamp` — there is no `data._stamp`
mapping on this index.

### Every action the system can record

| Action | Means |
|---|---|
| `fault.detected` / `fault.resolved` | a beacon opened / closed a fault |
| `decision.made` / `decision.declined` | the model answered / refused |
| `decision.blocked` | the circuit breaker stopped it |
| `decision.duplicate` | the same fault was already in flight |
| `change.requested` | the workflow asked Salt for a state |
| `change.blocked` | the blast-radius gate refused |
| `change.override` | a provisioning window was open |
| `change.applied` | the config was pushed |
| `change.verified` | the outcome check passed — the change is confirmed |
| `change.unverified` | pushed, never confirmed — **this is the one to grep for** |
| `change.failed` | the push itself errored |
| `device.silent` / `device.heard` | the watchdog lost / regained a device |
| `fault.observed` | the **push** path saw a fault. It never acts on one |

Actors seen in a run: `salt-beacon:srlN`, `salt:srlN`,
`salt-reactor/config_drift`, `n8n/<model>`, `watchdog`, `bootstrap`,
`napalm-logs` (observations only).

### Queries worth keeping

```sh
./scripts/evidence.sh                    # last 15 minutes, everything
./scripts/evidence.sh srl3 60            # one device, last hour
./scripts/evidence.sh trace:<trace-id>   # one incident, start to finish
./scripts/show-decision.sh               # what the model saw and what it said
```

Anything applied but never confirmed:

```sh
P=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
docker exec elasticsearch curl -s -u "elastic:$P" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=20" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"action":"change.unverified"}},"sort":[{"@timestamp":"desc"}]}'
```

---

## 4b. The push detection path

Runs alongside the beacons to be measured against them. It records and does
not act, so nothing here can change a router.

```sh
./scripts/compare-paths.sh 48     # push vs poll over the last 48h
./scripts/compare-paths.sh 6
```

Three lists come out: faults both paths saw and which was first, faults only
push saw, and faults only poll saw. The last one decides whether detection
could ever move to push.

The two record totals it prints are **not** comparable — the poll path writes
one record per fault lifecycle, the push path one per syslog message — so read
the distinct device+fault column beside them. The script says so in its own
output.

```sh
docker logs -f napalm-logs        # what it parsed, and what it could not
docker logs -f push-detect        # what it recorded, with seen/written counts
```

napalm-logs' own log is where the gaps are: messages with no profile never
reach the bridge, because napalm-logs drops them internally. Three lines,
almost the same, three different meanings:

| Line | Means |
|---|---|
| `not configured for os: srlinux tag bfd` | the prefix matched; that **subsystem** has no message file. Expected for `bfd` and `mgmt` |
| `Configured regex did not match for os: srlinux tag bgp` | the subsystem has a file, but this **message** is not in it |
| `not configured for os: srlinux tag sr_bfd_mgr` | **the prefix is broken.** A process name here means nothing is being parsed |

The routers must carry both destinations, or the push path is blind and looks
quiet:

```sh
docker exec clab-selfheal-srl1 sr_cli "info /system logging" | grep remote-
# expect 172.30.30.30 port 5514 (the collector) and .31 port 5515 (napalm-logs)
docker exec salt-master salt 'srl*' state.apply golden_config   # if one is missing
```

Observations in the audit trail, separate from the poll path's detections:

```sh
P=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
docker exec elasticsearch curl -s -u "elastic:$P" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=20" \
  -H 'Content-Type: application/json' \
  -d '{"query":{"term":{"action":"fault.observed"}},"sort":[{"@timestamp":"desc"}]}'
```

`evidence.sh`, `watch-heal.sh` and `watch-provision.sh` **exclude** these rows,
because one syslog message per row crowds out the incident they are meant to
narrate. `PUSH=1 ./scripts/evidence.sh` puts them back.

## 5. The UIs

| UI | URL | Credentials |
|---|---|---|
| NetBox | http://127.0.0.1:8000 | `admin` / `grep NETBOX_SUPERUSER_PASSWORD .env` |
| Grafana | http://127.0.0.1:3000 | `grep GRAFANA_ADMIN_USER .env` / `grep GRAFANA_ADMIN_PASSWORD .env` |
| Kibana | http://127.0.0.1:5601 | `elastic` / `grep ELASTIC_PASSWORD .env` |
| n8n | http://127.0.0.1:5678 | owner account is created on first visit |
| napalm-logs UI | http://127.0.0.1:8001 | — |

### Grafana — what to look at

**Self-Heal — audit trail** is the dashboard that matters.

- *Change control* — the four stat panels across the top
- *Changes applied* vs *Changes blocked by the gate* — the gate working is a
  number going up, not an error
- **Applied but NOT verified** — this should be **0**. Any other number means a
  change was pushed and never confirmed, and that is the panel to check after
  every demo run
- *Model declined or was refused* — the model saying no is a success, not a failure
- *Audit events by action* — the shape of a run
- *The trail itself* — the raw records, who changed what and why

**Lab — Docker services** answers "does this fit on a laptop": memory per
container, total lab memory, CPU. Use it before recording.

There is also an alert rule in `grafana/alert-rule.json` — check
*Alerting → Alert rules* is provisioned; check-lab verifies this.

### Kibana — for anything the dashboards do not answer

Data views are created by `kibana/init.py`. Go to *Discover*, pick
`napalm-audit`, and filter. The queries worth typing:

```
action: "change.unverified"
action: "change.blocked" and device: "srl3"
trace_id: "srl3-20260928T..."
fault: "route_leak"
```

`lab-logs` is where you go when a container is misbehaving and you do not know
which one.

### n8n — the decision path

Workflow: **Fault → LLM → Salt Remediation**, 16 nodes. Open an execution and
walk it left to right:

| Node | What to check |
|---|---|
| Alert webhook | the fault as it arrived — `POST /webhook/fault` |
| Fetch fault from ES | the full record, not just the alert |
| Normalize alert | device, fault class, trace id |
| Build LLM prompt | **this is the input to read on stage** |
| Ask local LLM | the raw model reply |
| Validate against whitelist | the state name the model chose, and whether it is permitted |
| Accepted? | the branch taken |
| Build breaker query / Circuit breaker | how many changes recently — the rate ceiling |
| salt-api: run remediation | the actual call, with credentials added at request time |
| Audit: LLM decision / change requested | what got written to `napalm-audit` |

The credentials are **not** in the workflow JSON — the HTTP node adds them
from `$env` when the request is made. `grep` the n8n database and you will
find zero occurrences of the shared secret.

If you do not want to switch windows mid-demo:

```sh
./scripts/show-decision.sh      # the prompt and the reply, from the audit trail
```

---

## 6. Breaking it on purpose

```sh
./scripts/break.sh interface [srl3]   # an interface is shut
./scripts/break.sh mtu       [srl1]   # the two ends of a link disagree
./scripts/break.sh bgp       [srl3]   # a session is shut
./scripts/break.sh drift     [srl1]   # a description is edited by hand
./scripts/break.sh prefixes  [900]    # the upstream leaks a big table
./scripts/break.sh leak      [srl3]   # we leak transit's routes back
./scripts/break.sh unknown            # a fault with no runbook at all

./scripts/unbreak.sh                  # put it back by hand
```

Nothing in `break.sh` talks to Salt. Every injection is made straight on the
device, the way a mistake would be — which leaves the detection to the system
rather than to the person running the demo.

Watch it heal:

```sh
./scripts/watch-heal.sh               # the heal as a readable story
./scripts/watch-events.sh             # the event bus
./scripts/verify-heal.sh srl3 ethernet-1/1 <epoch-of-the-break>
```

`verify-heal.sh` asks *who* did it, not what the device looks like — watching
`admin-state` alone cannot tell an automated remediation from an engineer in
another terminal, and that produced a false pass once already.

---

## 6b. Proving it repeats

One heal is an anecdote. `soak.sh` runs a fault class N times and reports every
stage of every run, read out of the audit trail rather than timed by the test.

```sh
./scripts/soak.sh interface 10        # ten interface faults
./scripts/soak.sh leak 10             # ten route leaks
./scripts/soak.sh drift 10            # ten config drifts
GATE=wide ./scripts/soak.sh all 10    # thirty runs, ceilings widened
```

Stages per run: `push` (napalm-logs saw it) · `poll` (a beacon raised it) ·
`decided` · `declined` · `blocked` · `applied` · `verified` · `resolved`.
Results go to a TSV, and the summary prints min/median/max/stdev per stage plus
the two numbers the talk claims: how many resolved, and how often push was
ahead of poll.

Two things about it are worth knowing before reading any output.

**`GATE=wide` widens the change ceilings and says so.** At production limits
(3 changes/hour/device, 2 devices/15min) the fourth run of a class is correctly
refused — worth proving once, and in the way of measuring ten heals. The
summary always states which ceilings were in force.

**Runs rotate the target device.** Grafana groups notifications by
device + fault + interface with `group_interval: 30s`, so the same fault
injected twice on the same interface inside that window collapses into one
notification: the second run is detected perfectly and never reaches the
model. Rotating makes each run its own alert group. The leak case cannot
rotate — only the border router has a transit policy — so it relies on the
inter-run settle being longer than `group_interval`.

That grouping is not a bug to work around. It is what stops one broken
interface becoming one alert per evaluation, and any soak test of an alerting
pipeline has to account for it or it will measure the pipeline once and the
detector N times.

## 7. The whole lab

```sh
./scripts/bootstrap.sh        # build, seed, provision, enable detection
./scripts/check-lab.sh        # verify it is wired together
./scripts/demo-mode.sh on     # free memory before recording
./scripts/demo-mode.sh off
./scripts/demo-screen.sh              # 4 self-running panes: heal
./scripts/demo-screen.sh --provision  # 4 panes: ZTP
./scripts/demo-screen.sh --leak srl3  # 4 panes: route leak
./scripts/show-gate.sh                # pane 1 of the heal screen, standalone
./scripts/show-intent.sh              # pane 1 of the provision screen
./scripts/show-leak.sh                # pane 1 of the leak screen
./scripts/backup.sh / restore.sh
```

tmux, since this comes up every time: the prefix is `Ctrl-b`, then an arrow
key to move between panes. `Cmd`-anything is your terminal app, not tmux.
Mouse mode is on, so clicking a pane also works.

---

## Why a command returns nothing

SR Linux prints an empty result for a path that is valid in the schema but not
configured on that device. It is not an error and there is no message. The
three that catch people out:

| Command | Empty on | Because |
|---|---|---|
| `info /routing-policy policy transit-out` | srl1, srl2 | transit policy exists only on the border router, srl3 |
| `show ... bgp neighbor 198.51.100.0` | srl1, srl2 | only srl3 has an eBGP session |
| `salt srl1 beacons.list` shows no `route_leak` | srl1, srl2 | a core router has nothing to leak to |

And `srl4` is FRR: `sr_cli` does not exist there, `vtysh` does.

To check whether a path exists at all on a device before blaming the command:

```sh
docker exec clab-selfheal-srl1 sr_cli "info /routing-policy" | grep "policy "
```
