"""
Source-of-truth #2 beacon: same drift-detection mechanism as
config_drift.py, but the "truth" comes from pillar/YAML instead of an
HTTP call to NetBox. Proves the reactor loop (heal_drift.sls) doesn't
care where truth comes from — it just applies whatever state name the
firing beacon tells it to.
"""


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
