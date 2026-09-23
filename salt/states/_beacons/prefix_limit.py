"""Warn before a BGP prefix limit tears a session down.

A prefix limit is the control that stops a neighbour's mistake becoming
your outage: if an upstream leaks a full table at you, the session drops
instead of your router running out of memory. It works, and when it fires
you lose transit -- so the useful moment is the warning threshold, not the
teardown.

NAPALM cannot see this. bgp.neighbors on the srlinux driver returns -1 for
every prefix counter, so the counts come from the device's own state
datastore through srlstate.

**There is deliberately no runbook for this fault.** Raising the limit
automatically is precisely the wrong response -- the limit is the thing
protecting you, and an automation that widens it under pressure has
disabled the safety device because the safety device went off. The model is
expected to answer "none", and it becomes a ticket for whoever owns the
peering relationship.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "prefix_limit beacon needs a list of dicts"
    return True, "valid"


# SR Linux reports no configured limit as the 32-bit maximum. iBGP sessions
# inside one's own AS legitimately have none.
NO_LIMIT = 4294967295


def beacon(config):
    ret = []
    device = __grains__["id"]
    declared = __salt__["pillar.get"](f"bgp_neighbors:{device}", {}, unmask=True)
    counts = __salt__["srlstate.bgp_prefix_counts"]()
    if not counts:
        # Could not read the device. Not a verdict either way, and
        # explicitly not "the limits are fine".
        return ret

    for peer, c in counts.items():
        limit = c.get("max") or 0
        received = c.get("received") or 0
        warn_pct = c.get("warning_pct") or 80

        if limit in (0, NO_LIMIT):
            continue

        pct = (received / limit) * 100 if limit else 0
        over = bool(c.get("exceeded")) or pct >= warn_pct

        role = (declared.get(peer) or {}).get("role", "peer")
        detail = (
            f"{device} -> {peer} ({role}) has received {received} of "
            f"{limit} permitted prefixes ({pct:.0f}%, warns at {warn_pct}%)"
            + (" — LIMIT ALREADY EXCEEDED, the session is down or will be"
               if c.get("exceeded") else "")
        )

        tracked = __salt__["audit.track"](
            key=f"{device}/prefix_limit/{peer}",
            faulty=over,
            fault="bgp_prefix_limit",
            device=device,
            detail=detail,
        )
        if not over:
            continue

        ret.append({
            "tag": "fault",
            "fault": "bgp_prefix_limit",
            "device": device,
            "interface": "",
            "peer": peer,
            "peer_role": role,
            "received": received,
            "limit": limit,
            "percent": round(pct),
            "exceeded": bool(c.get("exceeded")),
            "trace_id": tracked["trace_id"],
            "detail": detail,
        })
    return ret
