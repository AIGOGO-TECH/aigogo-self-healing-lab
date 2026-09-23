"""Detect when a device's protocol layer no longer matches the fabric plan.

IS-IS, BFD and BGP sessions. This is the config that "never changes" --
which is exactly why nobody notices when it does. A BFD timer widened
during a troubleshooting session, an IS-IS metric adjusted to move traffic
and never moved back, an authentication keychain removed to make an
adjacency come up: each one is invisible, survives reboots, and quietly
changes how the network behaves under failure.

Renders the same template golden_config.sls applies, from the same pillar,
and diffs it against the device. Read-only: test=True loads a candidate,
the device computes the diff, and the candidate is discarded.

Named config_drift_golden so the existing reactor glob picks it up. The
event names the state to apply, so one reactor rule covers interface
descriptions, BGP policy and the protocol layer alike.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "config_drift_golden beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    device = __grains__["id"]
    fabric = __salt__["pillar.get"]("fabric", {}, unmask=True)
    dev = (fabric.get("devices") or {}).get(device)
    if not dev:
        # Not in the fabric plan. srl4 is the case that matters: the
        # upstream provider's router, which this automation does not manage.
        return ret

    result = __salt__["net.load_template"](
        template_name="salt://templates/golden_config.jinja",
        context={
            "dev": dev,
            "asn": fabric.get("asn"),
            "transit_asn": fabric.get("transit_asn"),
            "keychain": fabric.get("isis_keychain"),
            "cluster_id": fabric.get("rr_cluster_id"),
            # Must match golden_config.sls exactly. When the template grew a
            # syslog server and only the state was updated, this beacon died
            # with "Jinja variable 'syslog_server' is undefined" and stopped
            # watching the protocol layer -- silently, because a beacon that
            # cannot start simply produces nothing.
            "syslog_server": fabric.get("syslog_server"),
            "syslog_port": fabric.get("syslog_port"),
        },
        test=True,
        commit=False,
    )
    diff_text = result.get("diff", "") if isinstance(result, dict) else ""
    drifted = bool(diff_text.strip())

    tracked = __salt__["audit.track"](
        key=f"{device}/drift/golden",
        faulty=drifted,
        fault="protocol_drift",
        device=device,
        detail="IS-IS, BFD or BGP session config differs from the fabric plan",
    )
    if drifted:
        ret.append({
            "tag": "drift",
            "device": device,
            "diff": diff_text,
            "state": "golden_config",
            "trace_id": tracked["trace_id"],
        })
    return ret
