"""
Case 2 — the fault that lives BETWEEN two devices: the two ends of a P2P
link disagree on MTU. Neither device's own config is wrong on its own
terms, which is exactly why per-device monitoring never catches it, and
why IS-IS adjacency dies (hello padding) while ping still works.

Uses the Salt **mine**: every proxy publishes its own net.interfaces, so
each device can read its peer's actual values. That cross-minion data
sharing is the thing Salt has and a per-host playbook run does not.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "p2p_mismatch beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    ret = []
    device = __grains__["id"]
    links = __salt__["pillar.get"](f"p2p_links:{device}", {}, unmask=True)
    if not links:
        return ret

    local = __salt__["net.interfaces"]().get("out", {})
    # Peer data comes from the mine, not from a direct connection — this
    # device never talks to its neighbour, only to the master.
    mine = __salt__["mine.get"]("srl*", "net.interfaces") or {}

    for iface, link in links.items():
        peer = link.get("peer")
        peer_iface = link.get("peer_interface")
        agreed = link.get("mtu")

        local_mtu = (local.get(iface) or {}).get("mtu")
        peer_data = (mine.get(peer) or {}).get("out", {})
        peer_mtu = (peer_data.get(peer_iface) or {}).get("mtu")

        if local_mtu is None or peer_mtu is None:
            # The mine has no reading for one side. Not a verdict either way.
            continue

        mismatched = local_mtu != peer_mtu
        detail = (
            f"{device}:{iface} mtu {local_mtu} != "
            f"{peer}:{peer_iface} mtu {peer_mtu} (agreed {agreed})"
        )

        # Both ends of the link run this beacon and both will see the same
        # disagreement, so one fault produces two events. The key is built
        # from the link's endpoints sorted, not from this device, so the two
        # sides mint the *same* trace id rather than two competing ones.
        ends = sorted([f"{device}:{iface}", f"{peer}:{peer_iface}"])
        tracked = __salt__["audit.track"](
            key=f"p2p_mtu/{ends[0]}--{ends[1]}",
            faulty=mismatched,
            fault="p2p_mtu_mismatch",
            device=device,
            interface=iface,
            detail=detail,
        )
        if not mismatched:
            continue

        # Only the side whose MTU disagrees with the agreed value needs to
        # change. The other side reporting is still useful as an observation,
        # but it is flagged so the decision layer does not treat it as a
        # second, independent fault.
        ret.append({
            "tag": "fault",
            "fault": "p2p_mtu_mismatch",
            "device": device,
            "interface": iface,
            "peer": peer,
            "peer_interface": peer_iface,
            "local_mtu": local_mtu,
            "peer_mtu": peer_mtu,
            "agreed_mtu": agreed,
            "offending_side": agreed is not None and local_mtu != agreed,
            "trace_id": tracked["trace_id"],
            "detail": detail,
        })
    return ret
