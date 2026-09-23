"""
Custom beacon: detect when a device's running config has drifted from what
NetBox says it should be, without committing anything.

Reuses the same NetBox-fetch + Jinja template as states/sync_from_netbox.sls
(duplicated here rather than factored into a shared _modules/ helper — for a
conference demo, a beacon a reader can open and read top-to-bottom beats one
more layer of indirection; refactor if this grows).

Loads the candidate with test=True, commit=False (nothing touches the
device), diffs it against the running config, then discards the candidate.
Fires one event per interval only when there IS a diff.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "config_drift beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    nb = __salt__["pillar.get"]("netbox", {}, unmask=True)
    device = __grains__["id"]

    try:
        resp = __salt__["http.query"](
            f"{nb.get('url')}/api/dcim/interfaces/?device={device}",
            header_dict={"Authorization": f"Token {nb.get('token', '')}"},
            decode=True,
            decode_type="json",
        )
        results = resp.get("dict", {}).get("results", [])
    except Exception as exc:  # NetBox unreachable — no drift verdict possible
        return [{"tag": "error", "error": str(exc)}]

    interfaces = {i["name"]: i.get("description", "") for i in results}
    if not interfaces:
        return ret

    # test=True already diffs against the candidate and discards it —
    # a separate net.compare_config() call afterward finds nothing, because
    # there is no candidate left pending by then. The diff lives directly on
    # this return value.
    result = __salt__["net.load_template"](
        template_name="salt://napalm_srlinux_from_netbox.jinja",
        context={"interfaces": interfaces},
        test=True,
        commit=False,
    )
    diff_text = result.get("diff", "") if isinstance(result, dict) else ""
    drifted = bool(diff_text.strip())

    tracked = __salt__["audit.track"](
        key=f"{device}/drift/netbox",
        faulty=drifted,
        fault="config_drift",
        device=device,
        detail="running config differs from NetBox",
    )
    if drifted:
        ret.append({
            "tag": "drift", "device": device, "diff": diff_text,
            "state": "sync_from_netbox",
            "trace_id": tracked["trace_id"],
        })
    return ret
