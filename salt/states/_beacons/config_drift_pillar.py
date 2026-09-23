"""
Source-of-truth #2 beacon: same drift-detection mechanism as
config_drift.py, but the "truth" comes from pillar/YAML instead of an
HTTP call to NetBox. Proves the reactor loop (heal_drift.sls) doesn't
care where truth comes from — it just applies whatever state name the
firing beacon tells it to.
"""

import logging

log = logging.getLogger(__name__)


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "config_drift_pillar beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    truth = __salt__["pillar.get"]("device_truth", {}, unmask=True)
    interfaces = truth.get("interfaces", {})
    if not interfaces:
        return ret

    result = __salt__["net.load_template"](
        template_name="salt://napalm_srlinux_from_netbox.jinja",
        context={"interfaces": interfaces},
        test=True,
        commit=False,
    )
    # A failed read is not a clean device.
    #
    # net.load_template returns {"result": False, ...} when the session has
    # dropped, the JSON-RPC call timed out or the template would not render.
    # Without this check that became diff_text = "", which became
    # drifted = False, which called audit.track(faulty=False) -- and that
    # closes any open fault and writes a fault.resolved record with a
    # duration. An unreachable router therefore produced an audit trail
    # saying its drift had been resolved.
    #
    # bgp_down.py and iface_down.py already refuse to have an opinion
    # without a reading ("no reading is not the same as a healthy
    # reading"). These four -- the ones wired to the reactor -- did not.
    if not isinstance(result, dict) or not result.get("result"):
        log.warning("%s: cannot read %s (%s) -- no verdict this pass",
                    __name__.rsplit(".", 1)[-1], device,
                    (result or {}).get("comment", "no comment")
                    if isinstance(result, dict) else type(result).__name__)
        return ret

    diff_text = result.get("diff", "") if isinstance(result, dict) else ""
    device = __grains__["id"]
    drifted = bool(diff_text.strip())

    tracked = __salt__["audit.track"](
        key=f"{device}/drift/pillar",
        faulty=drifted,
        fault="config_drift",
        device=device,
        detail="running config differs from pillar",
    )
    if drifted:
        ret.append({
            "tag": "drift",
            "device": device,
            "diff": diff_text,
            "state": "sync_from_pillar",
            "trace_id": tracked["trace_id"],
        })
    return ret
