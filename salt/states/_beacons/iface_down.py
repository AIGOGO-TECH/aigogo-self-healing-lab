"""
Case 1 — single-device fault: a monitored interface is administratively
down. The simplest possible closed loop, and the easiest to follow on a
projector.

Fires a fault event naming the interface. It does NOT decide the fix —
the alert goes to Grafana, then to n8n, and the LLM picks which
remediation template applies. This beacon's only job is to notice.

The event carries a trace_id minted by audit.track() the first time this
interface is seen down, and reused for as long as it stays down. That id
is what ties this observation to the model's decision, the config push,
the commit on the device, and the resolution — see _modules/audit.py.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "iface_down beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    device = __grains__["id"]
    monitored = __salt__["pillar.get"](
        f"monitored_interfaces:{device}", [], unmask=True
    )
    if not monitored:
        return ret

    result = __salt__["net.interfaces"]()
    ifaces = result.get("out", {}) if isinstance(result, dict) else {}

    for name in monitored:
        data = ifaces.get(name)
        if not data:
            # No reading is not the same as a healthy reading: leave any
            # open fault for this interface open rather than closing it on
            # the strength of a failed poll.
            continue

        # Two different faults, deliberately separated, because only one of
        # them has a fix that this system is allowed to apply.
        #
        #   is_enabled False  someone shut the interface. restore_interface
        #                     un-shuts it. A closed loop.
        #
        #   is_enabled True   the config is already what it should be and the
        #   but is_up False   link is down anyway: a cut fibre, a dead
        #                     transceiver, the far end shut. There is no
        #                     runbook, and there should not be one -- nothing
        #                     Salt can push to this router will light that
        #                     link. The model is expected to answer "none"
        #                     and raise a ticket.
        #
        # Reporting both as one fault would be worse than not detecting the
        # second at all: the model would pick restore_interface, the push
        # would be an idempotent no-op, verification would fail, and the
        # trail would fill with changes that did nothing to a link nobody
        # went to look at.
        admin_down = not data.get("is_enabled", True)
        link_down = not admin_down and not data.get("is_up", True)

        if admin_down:
            fault, detail = ("interface_admin_down",
                             f"{name} on {device} is administratively down")
        elif link_down:
            fault, detail = ("interface_link_down",
                             f"{name} on {device} is enabled but the link is "
                             f"down — no configuration change on this device "
                             f"can fix that")
        else:
            fault, detail = ("interface_admin_down", "")

        tracked = __salt__["audit.track"](
            key=f"{device}/iface_down/{name}",
            faulty=admin_down or link_down,
            fault=fault,
            device=device,
            interface=name,
            detail=detail,
        )
        if not (admin_down or link_down):
            continue

        ret.append({
            "tag": "fault",
            "fault": fault,
            "device": device,
            "interface": name,
            "trace_id": tracked["trace_id"],
            "detail": detail,
        })
    return ret
