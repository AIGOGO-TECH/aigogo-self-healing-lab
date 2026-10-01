"""Detect when this router is announcing something it should not be.

A route leak: an announcement with a perfectly valid origin, propagated
past the scope it was meant for. RFC 7908 has a taxonomy of them, and they
keep happening -- Google into NTT in 2017, which took much of Japan off the
internet for hours, and DQE through Verizon in 2019.

(Not the 2008 Pakistan Telecom / YouTube incident, which is cited for this
far more often than it should be. That was a more-specific announced by
someone who did not hold the space -- a mis-origination, which RPKI origin
validation is designed to catch. A leak has the right origin and the wrong
reach, which is why ROV does not stop one.)

What makes a leak worth a detector of its own here is a property nothing
else in this repo checks for.

There is plenty of tooling that sees leaks -- BMP streams the adj-rib-out
this beacon polls, and ARTEMIS, BGPalerter and the commercial monitors all
watch for them from the outside. The point is narrower and about this lab:

**Every other detector in this lab compares configuration to intent.**
config_drift watches descriptions, config_drift_golden watches the protocol
layer, config_drift_policy watches the routing policy itself. All three
answer "does the device's configuration match what the source of truth
says?" All three would pass while this router leaks a full table.

Because a leak is not a configuration that looks wrong. It is a
configuration that looks right and behaves wrong:

  * an export policy attached to the wrong peer-group
  * a prefix-list with one `le` too many, so more-specifics escape
  * an aggregate whose components leak alongside it
  * a policy that was correct until someone added a statement above it

In every one of those the config diffs clean. The only place the truth
exists is the post-policy adj-rib-out -- what actually went out the
session. So that is what this reads, and it compares it against the export
set NetBox declares, not against the policy that was supposed to produce
it.

That distinction is the same one the remediation states make when they
verify an OUTCOME rather than a configuration, and for the same reason:
converging to the intended configuration proves the configuration
converged. It proves nothing about what the router then did with it.

There IS a runbook for this one. Re-applying bgp_policy rebuilds the export
policy from NetBox and the extra announcements stop -- and unlike the
prefix-limit fault, that is the correct response rather than a way of
disabling the thing protecting you. The verification afterwards re-reads
the adj-rib-out, because the only proof that a leak stopped is that the
prefixes are no longer being advertised.
"""

import ipaddress
import time

# NetBox is the source of truth for what may be announced, and asking it on
# every beacon interval would be both wasteful and a new way for the
# detector to go blind. The export set changes when a human edits it, which
# is not every thirty seconds -- so it is cached, and the cache is short
# enough that a correction takes effect while the incident is still open.
INTENT_TTL = 300


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "route_leak beacon needs a list of dicts"
    return True, "valid"


def _intent(device):
    """This device's BGP intent from NetBox, cached for INTENT_TTL seconds.

    Returns None when NetBox cannot be reached AND nothing is cached --
    which must not be read as "nothing is permitted", because an empty
    permitted set would make every single announcement look like a leak.
    """
    cache = __context__.setdefault("route_leak_intent", {})
    hit = cache.get(device)
    if hit and time.time() - hit["at"] < INTENT_TTL:
        return hit["bgp"]

    nb = __salt__["pillar.get"]("netbox", {}, unmask=True)
    try:
        res = __salt__["http.query"](
            nb.get("url", "http://netbox:8080") + "/api/dcim/devices/?name=" + device,
            header_dict={"Authorization": "Token " + nb.get("token", "")},
            decode=True, decode_type="json", status=True,
        )
        if res.get("status") != 200:
            raise ValueError(f"NetBox returned {res.get('status')}")
        results = (res.get("dict") or {}).get("results") or []
        bgp = (results[0].get("config_context") or {}).get("bgp", {}) if results else {}
    except Exception:  # noqa: BLE001 - a beacon must survive this
        # Serve a stale answer rather than none. A leak detector that goes
        # quiet when its source of truth hiccups is a leak detector that is
        # off exactly when someone is editing policy.
        return hit["bgp"] if hit else None

    cache[device] = {"at": time.time(), "bgp": bgp}
    return bgp


def _intended(context):
    """The prefixes NetBox says may be announced to transit."""
    transit = (context.get("transit") or {})
    return set((transit.get("export") or {}).get("prefixes") or [])


def _covered_by(prefix, allowed):
    """Is this prefix one of the allowed aggregates, or inside one?

    A more-specific of an aggregate you are allowed to announce is still a
    leak -- it is how an aggregate's components escape -- but it is a
    different kind of leak from announcing someone else's space, and the
    detail says which.
    """
    try:
        net = ipaddress.ip_network(prefix)
    except ValueError:
        return None
    for a in allowed:
        try:
            agg = ipaddress.ip_network(a)
        except ValueError:
            continue
        if net.subnet_of(agg):
            return a
    return None


def beacon(config):
    ret = []
    device = __grains__["id"]

    context = _intent(device)
    if not context:
        # No declared BGP intent for this device: it is not a border router
        # and has nothing to leak. Silence here is correct.
        return ret

    transit = context.get("transit") or {}
    peer = transit.get("peer_ip")
    allowed = _intended(context)
    if not peer or not allowed:
        return ret

    advertised = __salt__["srlstate.advertised_to"](peer)
    if advertised is None:
        # Could not read the device. Explicitly not "it is announcing
        # nothing", which would look like the safest possible state and be
        # the least true one.
        return ret

    extra = [p for p in advertised if p not in allowed]

    leaked, more_specifics = [], []
    for prefix in extra:
        parent = _covered_by(prefix, allowed)
        (more_specifics if parent else leaked).append(prefix)

    faulty = bool(extra)
    if faulty:
        parts = []
        if leaked:
            parts.append(f"{len(leaked)} prefix(es) that are not ours to "
                         f"announce ({', '.join(leaked[:4])}"
                         f"{', ...' if len(leaked) > 4 else ''})")
        if more_specifics:
            parts.append(f"{len(more_specifics)} more-specific(s) escaping "
                         f"an aggregate ({', '.join(more_specifics[:4])}"
                         f"{', ...' if len(more_specifics) > 4 else ''})")
        detail = (f"{device} is advertising {len(extra)} prefix(es) to "
                  f"{peer} (AS{transit.get('peer_as', '?')}) that NetBox "
                  f"does not permit: " + "; ".join(parts) +
                  f". Permitted: {', '.join(sorted(allowed))}")
    else:
        detail = (f"{device} advertises only {', '.join(sorted(allowed))} "
                  f"to {peer}")

    tracked = __salt__["audit.track"](
        key=f"{device}/route_leak/{peer}",
        faulty=faulty,
        fault="route_leak",
        device=device,
        detail=detail,
    )
    if not faulty:
        return ret

    ret.append({
        "tag": "fault",
        "fault": "route_leak",
        "device": device,
        "interface": "",
        "peer": peer,
        "peer_as": transit.get("peer_as"),
        "advertised": advertised,
        "permitted": sorted(allowed),
        "leaked": leaked,
        "more_specifics": more_specifics,
        "state": "bgp_policy",
        "trace_id": tracked["trace_id"],
        "detail": detail,
    })
    return ret
