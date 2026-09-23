"""Detect when a device's BGP policy no longer matches NetBox.

The third source of truth, and the one that matters most on a border
router. config_drift watches interface descriptions, which are
documentation. This watches what the router announces and accepts, which is
the business.

The fault it exists for is not dramatic and that is the point: somebody
removes a bogon filter to chase a problem at 2am, the problem goes away for
an unrelated reason, and the filter never goes back. Nothing breaks. The
config still looks fine. Months later an upstream leaks a full table or a
private prefix and the missing line is suddenly the whole incident.

Same mechanism as config_drift: render what NetBox says the policy should
be, load it as a candidate with test=True so the device diffs it for us,
and discard. Nothing is committed here -- this beacon only ever reads.

Named config_drift_policy so the existing reactor glob
(salt/beacon/*/config_drift*/drift) picks it up without a new rule. The
event carries the state to apply, so one reactor covers every source of
truth.
"""

import logging

log = logging.getLogger(__name__)


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "config_drift_policy beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    device = __grains__["id"]
    nb = __salt__["pillar.get"]("netbox", {}, unmask=True)

    try:
        resp = __salt__["http.query"](
            f"{nb.get('url')}/api/dcim/devices/?name={device}",
            header_dict={"Authorization": f"Token {nb.get('token', '')}"},
            decode=True,
            decode_type="json",
            status=True,
        )
    except Exception as exc:  # noqa: BLE001 - NetBox down is not drift
        return [{"tag": "error", "error": str(exc)}]

    if resp.get("status") != 200:
        # A source of truth that is not answering tells us nothing about
        # whether the device has drifted. Reporting "no drift" here would
        # be a lie, and reporting drift would start a remediation against
        # an empty policy.
        return ret

    results = resp.get("dict", {}).get("results", [])
    bgp = (results[0].get("config_context", {}) or {}).get("bgp", {}) if results else {}
    if not bgp:
        # No bgp context on this device's role: not a border router.
        return ret

    result = __salt__["net.load_template"](
        template_name="salt://templates/bgp_policy.jinja",
        context={"bgp": bgp},
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
    drifted = bool(diff_text.strip())

    tracked = __salt__["audit.track"](
        key=f"{device}/drift/bgp_policy",
        faulty=drifted,
        fault="policy_drift",
        device=device,
        detail="BGP policy on the device differs from NetBox intent",
    )
    if drifted:
        ret.append({
            "tag": "drift",
            "device": device,
            "diff": diff_text,
            "state": "bgp_policy",
            "trace_id": tracked["trace_id"],
        })
    return ret
