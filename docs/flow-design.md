# Demo flow — fault → detect → monitor → alert → AI → remediate

The pipeline the talk demonstrates, end to end. Every arrow below is a real
component in this repo, not a diagram of an intention.

```
   ┌─────────────────────────────────────────────────────────────────┐
   │ 1. FAULT                                                        │
   │    on one device  ·  or between two devices                     │
   └───────────────────────────┬─────────────────────────────────────┘
                               │
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 2. DETECT — Salt beacon (runs on the proxy-minion, every 20s)   │
   │    reads device state via NAPALM, compares to what it should be │
   └───────────────────────────┬─────────────────────────────────────┘
                               │  salt/beacon/<device>/<beacon>/fault
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 3. MONITOR — Salt event bus → event_return → Elasticsearch      │
   │    index napalm-YYYY.MM.DD — every event, searchable in Kibana  │
   └───────────────────────────┬─────────────────────────────────────┘
                               │
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 4. ALERT — Grafana alert rule queries that ES index             │
   │    fires → webhook contact point                                │
   └───────────────────────────┬─────────────────────────────────────┘
                               │  HTTP POST (alert payload)
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 5. DECIDE — n8n webhook receives the alert                      │
   │    → asks the local model: "which template fixes this?"          │
   │    → it returns ONE name from a fixed whitelist + params     │
   └───────────────────────────┬─────────────────────────────────────┘
                               │  POST /run  (salt-api, eauth)
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 6. ACT — salt-api runs the chosen state on the chosen device    │
   │    Salt renders the template and pushes it via NAPALM           │
   └───────────────────────────┬─────────────────────────────────────┘
                               │
   ┌───────────────────────────▼─────────────────────────────────────┐
   │ 7. VERIFY — state is idempotent; re-run reports "already        │
   │    configured". Outcome written back to ES for the record.      │
   └─────────────────────────────────────────────────────────────────┘
```

## Where the AI sits — and where it deliberately does not

The LLM **selects** a remediation template from a fixed whitelist and fills
its parameters. It does **not** write configuration text, and it has no
path to the device: salt-api only accepts a state name that already exists
in `salt/states/`. A hallucinated template name fails closed — the run is
rejected, nothing reaches the router.

This is a deliberate narrowing from freeform generation:

| Layer | Who decides | Why |
|---|---|---|
| What changed | Salt beacon (deterministic diff) | No ambiguity to interpret |
| Which fix applies | **LLM, from a whitelist** | Classification is what LLMs are good at |
| What the fix contains | A human-written Jinja template, reviewed | Config text is never generated |
| Whether it lands | Salt + NAPALM, idempotent | Same execution path as a human run |

## The three cases

### Case 1 — Interface down (single device)
- **Fault:** `set / interface ethernet-1/1 admin-state disable` typed on srl1
- **Beacon:** `iface_down` — reads `net.interfaces`, fires when a monitored
  interface is not up
- **Template:** `restore_interface` — re-enables the named interface
- **Point it makes:** the simplest possible closed loop, easy to follow live

### Case 2 — P2P mismatch between two devices
- **Fault:** MTU on srl2's side of the srl1↔srl2 link changed so the two
  ends disagree
- **Beacon:** `p2p_mismatch` — uses the **Salt mine**, where every proxy
  publishes its own interface MTUs; each device compares its side against
  its peer's mine data
- **Template:** `fix_p2p_mtu` — sets the local side back to the agreed value
- **Point it makes:** the fault exists in neither device alone. One device's
  config looks perfectly valid. This is the class of problem per-device
  monitoring never catches — and Salt's mine is built exactly for it.

### Case 3 — Drift from source of truth
- **Fault:** an interface description edited by hand at 3am
- **Beacon:** `config_drift` (NetBox-backed, srl1/srl2) or
  `config_drift_pillar` (pillar/YAML-backed, srl3)
- **Template:** `sync_from_netbox` / `sync_from_pillar`
- **Point it makes:** two different sources of truth, one mechanism — and
  the reactor doesn't know or care which one fired it

## Two paths, on purpose

Case 3 also runs through the **Salt reactor** directly (beacon → reactor →
state, no AI, ~20s). Cases 1 and 2 run the **full alert → AI → salt-api**
path. Both are real and both are shown, because they answer different
questions:

- The reactor path: *how fast can a deterministic loop close?*
- The AI path: *what do you do when the fault needs classifying first,
  and a human would otherwise have to read the alert and pick the runbook?*
