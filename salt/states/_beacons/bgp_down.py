"""
Case 4 — a BGP session is down.

The fault class every ISP engineer in the room has actually been paged
for. Reads sessions through NAPALM (bgp.neighbors) and compares against
the neighbours declared in pillar, so a session that has disappeared
entirely is caught as well as one that is merely not established.
"""


import logging
import time


log = logging.getLogger(__name__)


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "bgp_down beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    device = __grains__["id"]
    expected = __salt__["pillar.get"](f"bgp_neighbors:{device}", {}, unmask=True)
    if not expected:
        return ret

    # --- correlated fault suppression -------------------------------------
    # These sessions ride the loopbacks, so they depend on IS-IS, which
    # depends on the physical links. A monitored interface going down takes
    # BGP with it a minute later -- and without this check the system treats
    # that as a second, independent fault, opens a second trace, asks the
    # model again, and pushes restore_bgp_neighbor to a device whose BGP is
    # not the problem. That remediation then succeeds idempotently and
    # achieves nothing, which is the failure mode worth naming: a repeatable
    # outcome is not evidence of the intended one.
    #
    # So while an interface fault is open on this device, a BGP session down
    # is reported as a symptom and not remediated. The suppression is itself
    # recorded, once, so the audit trail explains the silence.
    monitored = __salt__["pillar.get"](
        f"monitored_interfaces:{device}", [], unmask=True)
    live_ifaces = (__salt__["net.interfaces"]() or {}).get("out", {})
    # Either kind of interface fault takes the adjacency, and therefore the
    # session, with it. The first version of this only looked at is_enabled,
    # so a link that went down on its own -- the far end shut, a cut fibre --
    # still produced an independent BGP fault, which is the exact cascade
    # this exists to stop.
    underlying = [
        name for name, data in live_ifaces.items()
        if name in monitored
        and (not data.get("is_enabled", True) or not data.get("is_up", True))
    ]

    # And for a while afterwards. A session does not come back the instant
    # the link does: IS-IS has to re-form the adjacency and BGP has to leave
    # Connect, which together take tens of seconds. Without this the
    # sequence on a real heal was
    #
    #   restore_interface applied and verified
    #   ... 50s later, BGP still converging ...
    #   restore_bgp_neighbor decided and pushed
    #
    # -- a remediation for a fault that was already fixing itself. It would
    # have succeeded, idempotently, and done nothing, which is exactly the
    # class of "successful" change this whole design is trying not to make.
    settle = int(__salt__["pillar.get"](
        "maintenance:bgp_settle_seconds", 120, unmask=True))
    if not underlying:
        # max() over an empty generator raises, and the generator IS empty
        # whenever net.interfaces returns nothing -- which happens every time
        # the proxy's device session has dropped. The guard was on `monitored`
        # being non-empty, which is the wrong question: the interfaces are
        # declared in pillar and the readings come from the device, and it is
        # the readings that go missing. The beacon then died with
        # "Unable to start bgp_down beacon, max() iterable argument is empty"
        # and stopped watching BGP entirely.
        flaps = [
            data.get("last_flapped") or 0
            for name, data in live_ifaces.items()
            if name in monitored
        ]
        recent_up = max(flaps) if flaps else 0
        if recent_up and (time.time() - float(recent_up)) < settle:
            underlying = [f"an interface came up {int(time.time() - float(recent_up))}s ago"]

    result = __salt__["bgp.neighbors"]()

    # "I could not read the device" is not "every session is down".
    #
    # Without this check they are the same thing to the code below: an
    # unreachable device returns nothing, `live` stays empty, and every
    # neighbour declared in pillar is reported as `missing`. Observed, with
    # srl2's container paused so that NAPALM got No route to host:
    #
    #   09:09:07  fault.detected    open       iBGP session srl2 -> 10.255.0.1
    #                                          (route-reflector) is missing
    #   09:09:07  fault.detected    open       iBGP session srl2 -> 10.255.0.3
    #                                          (rr-client) is missing
    #   09:09:28  decision.made     accepted   "iBGP session is
    #                                           administratively shut"
    #   09:09:38  change.requested  no-change  An exception occurred...
    #
    # Two invented faults, the model woken and given a wrong premise -- it
    # said the session was administratively shut; the box was gone -- and a
    # salt-api round trip spent on a device no push can reach. The only
    # thing that stopped a config change was the push failing too.
    #
    # It also burns the per-device rate limit and the fleet blast radius
    # that a real fault would need, on a device whose actual problem is
    # that somebody has to walk to it.
    if not isinstance(result, dict) or not result.get("result"):
        log.warning("bgp_down: cannot read %s (%s) -- no verdict",
                    device, str(result.get("comment", ""))[:200]
                    if isinstance(result, dict) else type(result).__name__)
        return ret

    out = result.get("out") or {}

    live = {}
    for vrf, by_as in out.items():
        for asn, peers in (by_as or {}).items():
            for p in peers or []:
                addr = p.get("remote_address")
                if addr:
                    live[addr] = p

    for peer_ip, meta in expected.items():
        p = live.get(peer_ip)
        state = (p or {}).get("connection_state", "missing")
        down = not (p and p.get("up") and state == "established")
        detail = (
            f"iBGP session {device} -> {peer_ip} "
            f"({meta.get('role', 'peer')}) is {state}, expected established"
        )

        if down and underlying:
            # Track it under its own key so the suppression is recorded once
            # rather than every 20 seconds, and cleared when it lifts.
            __salt__["audit.track"](
                key=f"{device}/bgp_suppressed/{peer_ip}",
                faulty=True,
                fault="bgp_session_down_symptom",
                device=device,
                detail=(f"{detail} — suppressed: {', '.join(underlying)} "
                        f"is administratively down on {device}, so this "
                        f"session is a symptom, not a fault"),
            )
            continue

        __salt__["audit.track"](
            key=f"{device}/bgp_suppressed/{peer_ip}", faulty=False,
            fault="bgp_session_down_symptom", device=device,
        )

        tracked = __salt__["audit.track"](
            key=f"{device}/bgp_down/{peer_ip}",
            faulty=down,
            fault="bgp_session_down",
            device=device,
            detail=detail,
        )
        if not down:
            continue

        ret.append({
            "tag": "fault",
            "fault": "bgp_session_down",
            "device": device,
            "interface": "",
            "peer": peer_ip,
            "peer_role": meta.get("role", ""),
            "state": state,
            "trace_id": tracked["trace_id"],
            "detail": detail,
        })
    return ret
