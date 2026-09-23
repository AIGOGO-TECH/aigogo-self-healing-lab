# Screenshot guide — click by click

Four web interfaces, all already running. Nothing here needs a login you
have to create; credentials are below where they're needed. Nothing in
these screenshots contains a real customer IP, hostname or company name —
the lab is entirely synthetic, so all of it is safe to publish.

**Browser window ~1400px wide.** Crop out browser chrome before using.

---

## FIRST: how to freeze a fault so you can photograph it

The loop heals things in ~40 seconds, which is too fast to screenshot.
To hold a fault open, stop n8n first — faults keep being detected and
Grafana keeps alerting, but nothing repairs them:

```bash
cd ~/Documents/MyGitProjects/selfheal-lab
docker compose stop n8n
```

Then inject the fault you want to photograph:

```bash
# Case 1 — interface down on srl1
docker exec -i clab-selfheal-srl1 sr_cli <<'X'
enter candidate
set / interface ethernet-1/1 admin-state disable
commit stay
X

# Case 2 — MTU mismatch between srl1 and srl2
docker exec -i clab-selfheal-srl2 sr_cli <<'X'
enter candidate
set / interface ethernet-1/1 mtu 1500
commit stay
X
```

When you're done photographing, bring everything back:

```bash
docker compose start n8n
# wait ~60s, then confirm both are healed:
docker exec clab-selfheal-srl1 sr_cli "show network-instance default protocols isis adjacency"
```

---

## 1 · NetBox — source of truth  →  http://localhost:8000

Login: **admin / admin**

| Shot | Click path | What the image must show | Slide |
|---|---|---|---|
| **1.1** | Left sidebar → **Organization → Devices** (or top search → "Devices") | The device list with **srl1** and **srl2**, their site, role and type columns | spare |
| **1.2** | Click **srl1** → the **Interfaces** tab | The row for `ethernet-1/1` with its **Description** column filled in — that description is exactly what the drift loop enforces | **#16 (Case 3)** |

Note: **srl3 is deliberately absent from NetBox.** Its source of truth is
a YAML pillar file instead. That's the whole point of Case 3 — if someone
asks why it's missing, that's the answer, not a gap.

---

## 2 · Kibana — the monitoring layer  →  http://localhost:5601

No login. On first load it may show a "Welcome" splash — click through it.

**Set the time picker (top right) to `Last 1 hour` before every shot.**

| Shot | Click path | What the image must show | Slide |
|---|---|---|---|
| **2.1** | ☰ menu → **Analytics → Discover** → data view dropdown (top left) → **`napalm-*`** | The raw Salt event stream. Add the `tag` column: hover `tag` in the left field list → **+**. Hundreds of events with a histogram above | spare |
| **2.2** | Same screen → in the query bar type `tag: *fault*` → Enter | Only the beacon **fault** events. Add the `data.detail` column too — each row then reads like a sentence | **"Salt detected it"** |
| **2.3** | In 2.2's results, click the **>** arrow on a `p2p_mismatch` row to expand it | The full JSON document with `local_mtu`, `peer_mtu` and `agreed_mtu` visible together | **#17 (Case 2)** |
| **2.4** | Data view dropdown → **`napalm-rejected`** | The two documents where the LLM answered `none` — `rejected_choice: none`, `note: LLM declined…` | **#20 (the honest finding)** |
| **2.5** | Data view dropdown → **`napalm-remediations`** | AI-chosen fixes: `chosen_state`, `llm_reason`, `salt_result` per row | **#19 (where AI sits)** |

Data views `napalm-tickets` and `napalm-remediations` are already created —
you only pick them from the dropdown, no setup.

---

## 3 · Grafana — dashboard + alerting  →  http://localhost:3000

No login (anonymous admin is on). If it asks, there's no password.

| Shot | Click path | What the image must show | Slide |
|---|---|---|---|
| **3.1** | ☰ → **Dashboards → Salt Info** | The "Salt Changes" panel — automation activity over time | spare |
| **3.2** | ☰ → **Alerting → Alert rules** → expand **Self-Heal Lab** folder → click **Network fault detected by Salt beacon** | The rule definition with its Elasticsearch query visible | **#15 (the loop)** |
| **3.3** | Same list, **while a fault is open** (see "freeze a fault" above) | The rule row in red **Firing** state | **#15 (Case 1)** |
| **3.4** | ☰ → **Alerting → Contact points** → **n8n-fault-webhook** | The webhook URL `http://n8n:5678/webhook/fault` — this is the alert → API hop | **#14 (the loop)** |
| **3.5** | ☰ → **Dashboards → Lab — Docker services** | Memory and CPU per container, real names — 17 containers, ~5GB, one laptop | **#23** |

---

## 4 · n8n — the AI decision layer  →  http://localhost:5678

No login setup needed; it opens straight into the UI.

There are two workflows. You want **"Fault → LLM → Salt Remediation"**.
The other one ("Self-Heal Incident Explainer") runs every 30 seconds and
will otherwise flood the executions list — filter it out.

| Shot | Click path | What the image must show | Slide |
|---|---|---|---|
| **4.1** | **Overview → Workflows** → open **Fault → LLM → Salt Remediation** | The whole canvas: webhook → fetch from ES → normalize → LLM → **Validate against whitelist** → IF gate → salt-api, with the rejection branch going down | **#19** |
| **4.2** | Top of the canvas → **Executions** tab → click a **success** run → click the **Validate against whitelist** node → **Output** panel | `accepted: true`, `chosen: "restore_interface"`, and the LLM's `reason` | **#19** |
| **4.3** ⭐ | Same Executions list → find the run where the fault was `bgp_session_flapping` → same node → Output | `chosen: "none"`, `note: "LLM declined: no template addresses this fault"` | **#20** |
| **4.4** | Any successful run → click **Ask local LLM** node → Output | The raw llama3.1 JSON reply — proof it's a local model, not a cloud API | **#19** |
| **4.5** | Executions → the run where the note is **circuit breaker open** → **Validate against whitelist** → Output | `recent: 4`, `note: circuit breaker open — escalated to a human` — the LLM was never even asked | **#22** |

**4.3 is the single most valuable screenshot in the deck.** If the run
isn't in the list any more, recreate it:

```bash
curl -X POST http://localhost:5678/webhook/fault \
  -H 'Content-Type: application/json' \
  -d '{"device":"srl1","fault":"bgp_session_flapping","interface":"","detail":"BGP peer flapping every 30s, no template exists"}'
```
It takes ~15 seconds to answer, then refresh the Executions tab.

---

## 5 · Terminal captures

Real terminal windows photograph better than re-typeset text. Make the
font large before capturing.

| Shot | Command | Shows | Slide |
|---|---|---|---|
| **5.1** | `docker exec salt-master salt '*' test.ping` | three proxy-minions answering | #13 |
| **5.2** | `docker exec clab-selfheal-srl2 sr_cli "show network-instance default protocols isis adjacency"` | two live IS-IS adjacencies on the hub | #13 |
| **5.3** | same as 5.2 **during** an MTU mismatch | `Adjacency Count: 0` — the link genuinely broken | #17 |
| **5.4** | `docker exec salt-master salt-run state.event pretty=True` during a fault | the live event bus: beacon fault → reactor → state.apply | #15 |
| **5.5** | `docker exec salt-master salt 'srl1' mine.get 'srl*' net.interfaces` | the Salt mine — one device reading its peers' MTUs | #17 |

Ctrl-C to stop 5.4.


---

## 6 · The Facebook post

| Shot | What | Slide |
|---|---|---|
| **6.1** | Your post of 24 June 2025 — the n8n AI Agent canvas plus the live chat answering "what is my network status now?" | **#6** |

**Crop the commenter's name and photo out.** They didn't agree to appear
in a conference deck. Your own name and post text are fine — it's your work.

---

## 7 · NetBox is now enterprise-shaped

Re-seeded with the full model, so 1.1 and 1.2 look like a real operator's
NetBox rather than three bare devices:

- **Regions** Mongolia → Ulaanbaatar · **Site group** Core PoP
- **Sites** DC1 Primary Core · DC2 Secondary Core · POP3 Regional Edge
- **Racks** R01/R02/R03 in Hall A at each site, devices racked at a position
- **Tenant** ISP Core Network · **Contact** Network Operations,
  noc@example.net — assigned to all three devices
- **Platform** Nokia SR Linux 24.10.1 · serials and asset tags per device
- **IPAM** RFC1918 RIR, 10.0.0.0/8 aggregate, four prefixes, ten addresses,
  loopbacks set as each device's primary IPv4
- **Cables** between both P2P links · **Circuit** TRANSIT-10G-001, 10G IP
  transit landing at DC1
- **Tags** Salt-managed, Core Network

Worth saying on stage: after seeding those interface descriptions into
NetBox, **nobody ran a Salt command** — the drift loop had pushed all of
them onto the routers within 20 seconds. Change the source of truth, the
network follows.
