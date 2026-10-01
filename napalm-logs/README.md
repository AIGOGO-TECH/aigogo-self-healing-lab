# napalm-logs profile for Nokia SR Linux

napalm-logs turns a device's syslog into structured, vendor-agnostic
objects on the Salt event bus, shaped to OpenConfig/IETF YANG models. It is
the canonical way to get **push** detection instead of **poll**: a Salt
beacon notices a fault on its next interval — measured at about seven
seconds in this lab — while a syslog message arrives in milliseconds.

napalm-logs 0.11.0 ships profiles for `eos`, `fortinet`, `huawei`, `ios`,
`iosxr`, `junos`, `netiron`, `nxos`, `opengear` and `sonic`.

**There is none for SR Linux.** This is one.

## What it covers

Seven message types, each written against messages captured from this
lab's routers rather than from documentation. The raw sample is quoted at
the top of every file.

| File | SR Linux app | napalm-logs error |
|---|---|---|
| `INTERFACE_UP.yml` | `netinst` | `INTERFACE_UP` |
| `INTERFACE_DOWN.yml` | `netinst` | `INTERFACE_DOWN` |
| `BGP_NEIGHBOR_STATE_CHANGED.yml` | `bgp` | `BGP_NEIGHBOR_STATE_CHANGED` |
| `BGP_SESSION_STATE_LOWERED.yml` | `bgp` | `BGP_NEIGHBOR_STATE_CHANGED` |
| `ISIS_ADJACENCY_STATE_CHANGED.yml` | `isis` | `ISIS_ADJACENCY_STATE_CHANGED` |
| `LLDP_NEIGHBOR_UP.yml` | `lldp` | `LLDP_NEIGHBOR_UP` |
| `LLDP_NEIGHBOR_DOWN.yml` | `lldp` | `LLDP_NEIGHBOR_DOWN` |

`init.yml` consumes both headers: the RFC 5424 one, and SR Linux's own
`app|pid|tid|seq|severity:` header inside the message body.

## Tested

All seven were replayed through napalm-logs 0.11.0 and checked on the
ZeroMQ publisher. Four of the results:

    error: INTERFACE_UP                 host: srl1
      yang: interfaces/interface/ethernet-1/1.0/state/oper_status = UP

    error: INTERFACE_DOWN               host: srl1
      yang: interfaces/interface/ethernet-1/1.0/state/oper_status = DOWN

    error: BGP_NEIGHBOR_STATE_CHANGED   host: srl2
      yang: bgp/neighbors/neighbor/10.255.0.2/state/session_state = ESTABLISHED

    error: BGP_NEIGHBOR_STATE_CHANGED   host: srl1
      yang: bgp/neighbors/neighbor/10.255.0.1/state/session_state = IDLE

`LLDP_NEIGHBOR_DOWN` publishes an empty `yang_message`, and the file says
why: OpenConfig cannot express "this neighbour is gone" through a
napalm-logs mapping.

## Using it

```bash
napalm-logs --config-path /path/to/this/directory/.. --disable-security
```

`--config-path` takes the directory that *contains* `srlinux/`, because
napalm-logs takes the device OS name from the directory name.

Then on the Salt master:

```yaml
engines:
  - napalm_syslog:
      disable_security: true
      transport: zmq
      address: napalm-logs
      port: 49017
```

Events arrive tagged `napalm/syslog/srlinux/{notification_type}/{device}`,
and a reactor can match them exactly like a beacon fault.

## Wired in, as a second opinion

Since 2026-09-30 this runs alongside the beacons rather than instead of them.

```
routers ──syslog :5514──> device-syslog ──> lab-logs      (every message, for a human)
        └─syslog :5515──> napalm-logs ──ZMQ :49017──> push-detect ──> napalm-audit
                                                        action: fault.observed
```

Two syslog destinations, not one relayed to the other. The routers support
several `remote-server` entries, so each consumer owns a port and neither can
drop the other's traffic; a relay in between would be one more process whose
silence looks like health.

`collector/pushdetect.py` writes `fault.observed` and **does not remediate**.
The poll path keeps writing `fault.detected` and stays the only thing allowed
to act, because two detectors both calling `state.apply` on one fault is a
collision this repo has already paid for once. Promoting the push path is a
separate, deliberate change, and the thing that should justify it is data:

```bash
./scripts/compare-paths.sh 48
```

That prints three lists — faults both paths saw and which was first, faults
only push saw, and faults only poll saw. The third list is the one that
decides anything.

### What the first runs showed

Push is first when it sees a fault at all, because a beacon can be anywhere
inside its interval when the fault happens while syslog arrives in
milliseconds. Treat the size of the lead as bounded by the beacon interval —
15s for interfaces, 20s for BGP — rather than by any single measurement.

The lead is not the finding. This is:

| Fault | Push sees it | Verified |
|---|---|---|
| interface down | yes, milliseconds | yes |
| BGP session down | yes, milliseconds | yes — `IDLE` then `ESTABLISHED` |
| IS-IS adjacency down | yes, milliseconds | yes — `DOWN`, `INIT`, `UP` |
| p2p MTU mismatch | **no** — both ends are individually valid, nothing is logged | — |
| config drift | **no** — syslog says "committed", not "differs from NetBox" | — |
| policy drift | **no** — same | — |
| route leak | **no** — the config is valid and the session stays up | — |
| prefix limit | **no** — a count crossing a threshold is a state, not an event | — |

Two of nine beacons get faster. Five cannot use syslog at all, and no profile
or daemon can change that: the device does not emit anything to parse. Push
also adds one thing the poll path does not have — the `mgmt` messages say
somebody committed on the device, in the second it happened rather than at the
next drift poll.

So the honest summary is that push and poll answer different questions, and
the lab is better for running both. It is not a migration.

**The record counts are not comparable, and `compare-paths.sh` says so.** The
poll path writes one `fault.detected` per fault lifecycle; this bridge writes
one row per syslog message. Read the distinct device+fault column and the
three lists, not the totals.

### Three message types, three different log lines

One event on a link produces messages from `netinst`, `isis`, `bfd` and
`lldp` within milliseconds, and only some of them have a profile. napalm-logs
says which case you are in, and the three read almost the same:

| Line in `docker logs napalm-logs` | Means |
|---|---|
| `not configured for os: srlinux tag bfd` | the prefix matched; that **subsystem** has no message file. Expected for `bfd` and `mgmt` |
| `Configured regex did not match for os: srlinux tag bgp` | the subsystem has a file, but this particular **message** is not in it |
| `not configured for os: srlinux tag sr_bgp_mgr` | **the prefix is broken.** A process name here means nothing is being parsed |

The middle case is the one to expect from BGP: `BGP_SESSION_STATE_LOWERED`
covers "moved from higher state X to lower state Y", and SR Linux also emits
"Peer X was closed because …" and "an incoming BGP connection … was rejected
because …", which have no profile. They carry a reason rather than a state,
which is why they were left out rather than mapped to a state field that would
have to be invented.

Messages with no profile never reach the bridge: napalm-logs blacklists `RAW`
in its publisher by default and drops them internally. So the gaps are visible
only in the daemon's own log, and what the push path never saw does not appear
anywhere else.

### Getting it wrong first

The profile in this directory was originally written against sample messages
reconstructed from Elasticsearch, and it matched nothing at all when pointed
at live routers. Two reasons, both in `init.yml`:

- the RFC 5424 APP-NAME is the **process** (`sr_net_inst_mgr`), not the
  subsystem (`netinst`) the message files key on
- there is **one** space between the structured-data `-` and SR Linux's inner
  header, not two

The symptom of either is `Syslog message not configured for os: srlinux tag
sr_bfd_mgr` — which reads like a missing message file and is actually a broken
prefix. `docker logs napalm-logs | grep 'not configured'` is the first place
to look, and a tag there that is a *process* name means the prefix is wrong,
while a tag that is a *subsystem* name means the prefix is right and that
message type genuinely has no profile.

## Contributing this upstream

There is no SR Linux profile in napalm-logs. If it is submitted, these
files are the starting point — they are tested against a real device, and
the sample messages are in the comments so a reviewer can check them
without a lab.
