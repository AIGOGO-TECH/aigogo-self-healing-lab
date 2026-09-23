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

## Not wired into this lab yet

The lab still detects by polling. Switching detection over is a separate
change with its own risk: napalm-logs is one more process to keep alive,
and a syslog message that never arrives is silence, which this repo has
already learned not to treat as health (`docs/lessons.md` §11, §20, §56).
Both paths are worth running together before either is trusted alone.

## Contributing this upstream

There is no SR Linux profile in napalm-logs. If it is submitted, these
files are the starting point — they are tested against a real device, and
the sample messages are in the comments so a reviewer can check them
without a lab.
