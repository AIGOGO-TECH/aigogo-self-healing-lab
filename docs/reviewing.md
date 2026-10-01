# Reviewing this lab

Everything needed to get inside every component, in the order a reviewer
usually wants them. No credentials are written here: they live in `.env`,
which is generated per-clone and never committed. Where a password is
needed, the variable name is given and the command reads it for you.

Bring the lab up first — `./scripts/bootstrap.sh` — and stop when
`check-lab.sh` says `the lab is complete`. If it does not say that, the
failing check names the command that repairs it; nothing below will behave
until it passes.

---

## 0. Orientation, in three commands

```bash
./scripts/check-lab.sh          # 20 assertions about whether it actually works
cat docs/architecture.md        # what talks to what, and what each is trusted with
cat docs/commands.md            # every command, grouped by the box it runs on
```

`./scripts/check-lab.sh` is the one to run first. It asks whether the parts
are wired to each other, not whether they are alive, and each failure prints
the command that repairs it.

---

## 1. The routers

Four nodes, deployed by containerlab, named `clab-selfheal-srl1..4`.
srl1–3 are Nokia SR Linux; srl4 is FRR standing in for a transit provider
in a different AS.

```bash
# interactive CLI on any of them
docker exec -it clab-selfheal-srl1 sr_cli

# one command, non-interactive
docker exec clab-selfheal-srl1 sr_cli -e "show network-instance default protocols isis adjacency"
docker exec clab-selfheal-srl1 sr_cli -- info /interface ethernet-1/1

# the transit provider is FRR, so vtysh
docker exec -it clab-selfheal-srl4 vtysh
docker exec clab-selfheal-srl4 vtysh -c "show bgp ipv4 unicast summary"

# what the device itself logged, including every commit we made
docker exec clab-selfheal-srl1 tail -f /var/log/messages
```

SSH also works (`admin` / `$SRL_PASSWORD`, Nokia's documented default),
but `docker exec` avoids the host-key dance.

Addressing, and which file is the source of each address:
`docs/addressing.md`.

---

## 2. Salt

The master and three proxy-minions, one per SR Linux node. The proxies are
where NAPALM lives; the routers themselves run no agent.

```bash
docker exec -it salt-master bash

# from the host
docker exec salt-master salt 'srl*' test.ping
docker exec salt-master salt srl1 net.arp
docker exec salt-master salt srl1 beacons.list
docker exec salt-master salt srl1 pillar.items
docker exec salt-master salt-run state.event pretty=True     # the event bus, live

# what a remediation would do, without doing it
docker exec salt-master salt srl1 state.apply golden_config test=True
```

Custom code worth reading, all under `salt/states/`:

| Path | What it is |
|---|---|
| `_beacons/` | the detectors — one file per fault class |
| `_modules/audit.py` | the change gate and the audit trail |
| `_modules/netsafe.py` | commit, verify, confirm, revert |
| `_modules/verify.py` | the outcome checks |
| `_states/audited.py` | the state that wraps every remediation |
| `reactor/` | what the event bus triggers |
| `*.sls` | the seven remediations the model chooses between |

`salt/master.d/api.conf` is the salt-api boundary — worth reading closely,
it is the narrowest part of the trust model.

---

## 3. The web interfaces

All bound to `127.0.0.1` by default (`BIND_ADDR`). Passwords are in
`.env`; the `grep` next to each one prints it.

| What | URL | User | Password |
|---|---|---|---|
| NetBox — source of truth | http://127.0.0.1:8000 | `$NETBOX_SUPERUSER_NAME` | `grep NETBOX_SUPERUSER_PASSWORD .env` |
| Grafana — the detector | http://127.0.0.1:3000 | `$GRAFANA_ADMIN_USER` | `grep GRAFANA_ADMIN_PASSWORD .env` |
| Kibana — the audit trail | http://127.0.0.1:5601 | `elastic` | `grep ELASTIC_PASSWORD .env` |
| n8n — the decision layer | http://127.0.0.1:5678 | owner account, set on first visit | — |
| salt-api | http://127.0.0.1:8001 | `n8n` | `grep SALT_API_SECRET .env` |

Elasticsearch has no published port on purpose. Reach it through a
container:

```bash
PW=$(grep -E '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
docker exec salt-master curl -s -u "elastic:$PW" \
  'http://elasticsearch:9200/_cat/indices?v'
```

In Kibana, the index worth opening is `napalm-audit` — one document per
decision, change, refusal and verification, correlated by `trace_id`.

---

## 4. Watching it work

```bash
./scripts/demo-screen.sh srl1          # four panes: fault, router log, heal, devices
./scripts/demo-screen.sh --leak srl3   # the route-leak view
./scripts/demo-screen.sh --provision srl3
```

Individually:

```bash
./scripts/watch-heal.sh 10       # faults as stages, newest first
./scripts/watch-events.sh        # the Salt event bus, filtered
./scripts/watch-device.sh        # the routers' own logs
./scripts/show-decision.sh srl3  # what the model was asked, and answered
./scripts/show-leak.sh           # what the transit provider received
./scripts/evidence.sh srl1 10    # the audit trail, as text
./scripts/demo-mode.sh           # can a change be made right now, and why not
```

---

## 5. Breaking it

The device argument is optional; each case has a sensible default.

```bash
./scripts/break.sh interface [srl3]   # admin-shut a port
./scripts/break.sh mtu       [srl1]   # the two ends of a link disagree
./scripts/break.sh bgp       [srl3]   # shut a BGP session
./scripts/break.sh drift     [srl1]   # edit a description NetBox owns
./scripts/break.sh leak      [srl3]   # relax the transit export policy
./scripts/break.sh prefixes  [900]    # the upstream announces a large table
./scripts/break.sh unknown            # a fault no template addresses
./scripts/unbreak.sh prefixes         # withdraw that one again
```

Only `prefixes` has an unbreak: the rest are what the lab is for, and
undoing one by hand while waiting for the loop is how a test comes to report
a heal that never happened. If you need a device back without waiting, push
the fix as a human and it will not count against the ceilings:

```bash
docker exec salt-master salt srl1 state.apply restore_interface \
  pillar='{"interface":"ethernet-1/1","actor":"<you>","actor_type":"human"}'
```

Two ceilings decide whether a fix is allowed: three changes to one device
per hour, and at most two distinct devices in any fifteen minutes.
`./scripts/demo-mode.sh` prints both and says when they clear. A refused
change is the system working, not failing — the refusal is recorded
against the same trace.

---

## 6. The model

Runs locally under Ollama, on the host rather than in a container.

```bash
grep OLLAMA .env                 # which model, and where
curl -s localhost:11434/api/tags | python3 -m json.tool | head
./eval/model-bakeoff.py --models qwen2.5:7b --trials 10
./eval/model-bakeoff.py --models qwen2.5:7b --trials 10 --adversarial
```

The harness parses the prompt and the whitelist out of
`n8n/fault-remediation-workflow.json`, so the test cannot drift from what
runs. The cases are in the script and are worth disagreeing with.

---

---

## 7. What to read once you are in

Every control in this lab is a file you can open and argue with. The four
worth arguing with first:

- **`salt/master.d/api.conf`** — what n8n may ask salt-api to do. It names
  three minions one at a time and permits exactly one function.
- **`salt/states/_modules/audit.py`**, `change_allowed()` — the freeze, the
  rate limit, the blast radius and the override marker.
- **`n8n/fault-remediation-workflow.json`**, the node named *Validate against
  whitelist* — the lines between the model and the network.
- **`salt/states/_states/audited.py`** — what gets recorded, when, and what
  happens when the audit store is unreachable.

Each beacon in `salt/states/_beacons/` also has to decide what to do when the
device cannot be read at all, and they do not all answer the same way. The
differences are deliberate.

If you find something here that is wrong, the useful form of that finding is
a fault the lab cannot detect, or a change it would make that it should not.
