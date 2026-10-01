# The lab, end to end

Every box below is a running process, and every arrow was verified against
the running system rather than drawn from the compose file. 19 containers,
plus one thing that is deliberately not a container.

```
                         ┌─ HOST (macOS, Docker Desktop 11.7 GiB) ──────────────────────────┐
                         │                                                                   │
                         │   ollama  qwen2.5:7b      ← NATIVE, not a container, so it gets   │
                         │   :11434                    the GPU. host.docker.internal         │
                         └───────────────────────────────────────────────────────────────────┘
                                              ▲
                                              │ HTTP
 ═══════════════════════════════════════════  │  ═══════════════════════════════════════════
  DECIDE                                      │
                                    ┌─────────┴──────────┐
                     Grafana  ─────►│  n8n  2.38.7       │  127.0.0.1:5678
                     webhook        │  • normalise alert │
                                    │  • circuit breaker │  ← counts unattended changes
                                    │  • ask qwen2.5:7b  │
                                    │  • whitelist (7)   │  ← fail closed
                                    └─────────┬──────────┘
                                              │ salt-api  POST 127.0.0.1:8001
 ═══════════════════════════════════════════  │  ═══════════════════════════════════════════
  CONTROL PLANE                               ▼
                    ┌──────────────────────────────────────────────┐
                    │  salt-master                                 │
                    │   • event bus      • reactor (1 tag → 1 fn)  │
                    │   • salt mine      • salt-api :8000          │
                    │   • external_auth: n8n → state.apply on      │
                    │     srl1 srl2 srl3 ONLY                      │
                    └───┬──────────────┬──────────────┬────────────┘
                        │              │              │  ZeroMQ
              ┌─────────▼───┐  ┌───────▼─────┐  ┌─────▼───────┐
              │ salt-proxy  │  │ salt-proxy  │  │ salt-proxy  │   multiprocessing: false
              │   srl1      │  │   srl2      │  │   srl3      │   proxy_keep_alive: true
              │ 10 beacons  │  │ 10 beacons  │  │ 11 beacons  │   NAPALM srlinux driver
              └─────────┬───┘  └───────┬─────┘  └─────┬───────┘
                        │ JSON-RPC     │              │            ← HTTP, port 80
 ═══════════════════════│══════════════│══════════════│════════════════════════════════════
  DATA PLANE            ▼              ▼              ▼      containerlab, 172.30.30.0/24
                                                                   ┌────────────────┐
              ┌──────────┐ IS-IS L2  ┌──────────┐                  │  srl4     .24  │
              │ srl1 .21 ├───────────┤ srl2 .22 │                  │  FRR 10.2.1    │
              │ core RR  │  BFD 300ms│ core RR  │                  │  AS 64500      │
              └────┬─────┘           └─────┬────┘                  │  TRANSIT       │
                   │                       │                       │                │
                   │      ┌──────────┐     │        eBGP           │  NO proxy.     │
                   └──────┤ srl3 .23 ├─────┘  198.51.100.0/31      │  NO automation │
                          │ border   ├───────────────────────────► │  reaches it.   │
                          └──────────┘                             └────────────────┘
                     iBGP AS 65001 · srl1+srl2 are RRs · srl3 is a client + the eBGP edge
                          │
                          │ syslog udp/5514
 ═════════════════════════│══════════════════════════════════════════════════════════════
  OBSERVE                 ▼
        ┌───────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
        │ device-syslog │  │ docker-logs  │  │ docker-stats │  │ watchdog         │
        │ RFC 3164/5424 │  │ 19 containers│  │ cAdvisor was │  │ OUTSIDE Salt.    │
        │ holds on ES   │  │              │  │ tried, dropped│ │ "when did each   │
        │ failure       │  │              │  │              │  │  device last     │
        └───────┬───────┘  └──────┬───────┘  └──────┬───────┘  │  say anything?"  │
                │                 │                 │          └────────┬─────────┘
                └─────────────────┴────────┬────────┴───────────────────┘
                                           ▼
                              ┌───────────────────────────┐
                              │  elasticsearch  9.5.3     │
                              │   napalm-2*    beacon events
                              │   napalm-audit DATA STREAM — append-only,
                              │                no role can delete from it
                              │   lab-logs     every container + every router
                              │   napalm-{remediations,rejected,escalations}
                              └───────┬───────────────┬───┘
                                      │               │
                          ┌───────────▼──┐     ┌──────▼──────────┐
                          │ grafana 11.3 │     │ kibana 9.5.3    │
                          │ :3000        │     │ :5601           │
                          │ alert rule → │     └─────────────────┘
                          │ n8n webhook  │
                          └──────────────┘
 ═════════════════════════════════════════════════════════════════════════════════════════
  SOURCE OF TRUTH
                   ┌──────────────┐   ┌─────────────────┐   ┌──────────────┐
                   │ netbox 4.2   │──►│ netbox-postgres │   │ netbox-redis │
                   │ :8000        │   └─────────────────┘   └──────────────┘
                   │ devices · interfaces · IPs · ASNs · BGP config contexts
                   └──────────────┘
                            ▲
                            └── read by states and by three drift beacons

  NOT PART OF THIS LAB:  `postgres` on :5432 belongs to the `aigogo` compose
  project and happens to share the host.
```

## The flow, with measured times

A monitored interface is shut by hand on srl1. Nothing else is touched.

```
 T+0s     break.sh sets admin-state disable on srl1:ethernet-1/1

 T+7s     beacon  iface_down  fires on salt-proxy-srl1
          ├─ mints a trace id: srl1-20260920T145940Z-6dcd4d
          └─ event bus → elasticsearch  (napalm-2*)
          ALSO: srl2's beacon sees interface_link_down on its side —
          the same physical failure, correctly reported as a symptom

 T+8s     audit.track writes  fault.detected  to napalm-audit

 T+~20s   grafana alert rule (120s window, 10s eval) fires
          group_by data.device.keyword / data.fault.keyword / data.interface.keyword
          → POST to n8n

 T+29s    n8n:  normalise alert (from Grafana's labels, one fault)
                circuit breaker: unattended changes for srl1 in the last hour?
                prompt the model with 7 runbook names, each described by the
                  FAULT it repairs
                validate answer against the whitelist — fail closed
          decision.made  accepted  "Administrative state ... re-enabled"

 T+32s    salt-api → salt-master → salt-proxy-srl1 → state.apply restore_interface
          audited.config:
            1. audit.change_allowed()   freeze? rate limit? blast radius?
                                        audit store reachable?
            2. netsafe.push_template()  RLock held across load → diff → commit
                                        commit_confirmed, revert timer armed
                                        trace id written onto the CHECKPOINT
          change.applied  success

 T+33s    verify.interface_up()  reads the device — the OUTCOME, not the config
          change.verified  success  "ethernet-1/1 is up"
          netsafe.confirm()  keeps the change. Had it failed, the ROUTER
                             would have reverted it on its own clock.

 T+40s    beacon sees the interface up → fault.resolved
```

Everything after T+0 is unattended. The same `trace_id` appears on the
beacon event, every audit record, the salt-api call, the router's
configuration checkpoint, and the router's own syslog.

## What is deliberately absent

| | Why |
|---|---|
| **A proxy-minion for srl4** | It is the transit provider. Not ours to automate. `salt-api` names srl1, srl2, srl3 — a glob would have covered it silently. |
| **napalm-logs / ZeroMQ** | The profile is in `napalm-logs/srlinux/` and tested, but not wired in. Detection stays on beacons until both paths can be run together and compared. |
| **A BFD beacon** | Deliberately not written, and worth being precise about why. BFD is configured (300ms × 3 ≈ 900ms) and its transitions are collected as syslog but never acted on — which sounds like an obvious gap and mostly is not. A beacon that *polls* BFD state learns nothing sooner than the beacons already here, because the latency is the poll interval, not the protocol; BFD's value is the event, not the state. And a BFD transition means the path is physically broken, which is the one fault class this system deliberately refuses to remediate: "no configuration push fixes a physical fault like a broken link." Faster detection of an unfixable fault buys a faster ticket, not a faster heal. The real gap is smaller and duller than it first looks: detection was treated as solved, and is the step least thought about. |
| **Any LLM path to a device** | `salt-api` accepts one function. Templates take parameters from pillar, never from the caller. |
