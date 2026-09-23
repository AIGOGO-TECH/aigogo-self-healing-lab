"""Read arbitrary operational state off an SR Linux box, as JSON.

NAPALM's getters are a lowest-common-denominator view: portable across
vendors, and therefore missing most of what any particular vendor knows.
On this driver `bgp.neighbors` returns -1 for every prefix counter, so
"are we about to hit the prefix limit on our transit session" -- an
ordinary ISP question -- is unanswerable through it.

SR Linux's own CLI will emit any subtree of the state datastore as JSON,
so this asks the device directly:

    salt srl3 srlstate.get '/network-instance default protocols bgp neighbor'

The point is not this one beacon. It is that adding a detector for
something the vendor exposes no longer requires a NAPALM feature request --
which is the difference between a demo that watches four things and a
system somebody could actually extend.
"""

import json
import logging

log = logging.getLogger(__name__)

__virtualname__ = "srlstate"


def __virtual__():
    return __virtualname__


def _device():
    """The proxy-minion's existing connection. Never opens a second one:
    SR Linux's JSON-RPC server tolerates few concurrent sessions, and a
    beacon polling every 20 seconds is exactly how you find that out."""
    try:
        dev = __proxy__["napalm.get_device"]()
        return (dev or {}).get("DRIVER")
    except (NameError, KeyError, TypeError, AttributeError):
        return None


def get(path, default=None):
    """Return a state subtree as parsed JSON, or `default` on any failure.

    Returning a default rather than raising is deliberate: this is called
    from beacons, and a beacon that raises stops watching. A failed read is
    "I do not know", which callers must not treat as "nothing is wrong".
    """
    driver = _device()
    if driver is None:
        log.error("srlstate.get: no proxy connection available")
        return default
    try:
        out = driver.cli([f"info from state {path} | as json"])
        raw = list(out.values())[0] if isinstance(out, dict) else out
        return json.loads(raw) if isinstance(raw, str) else raw
    except Exception as err:  # noqa: BLE001 - a beacon must survive this
        log.error("srlstate.get(%s) failed: %s", path, err)
        return default


def bgp_prefix_counts(network_instance="default"):
    """Per-neighbour prefix counters and limits, flattened.

    {peer: {received, active, rejected, max, warning_pct, exceeded}}
    """
    # `neighbor *`, not `neighbor`: SR Linux's CLI wants a key for a list
    # node before it will accept a pipe, and refuses the bare node name.
    tree = get(f"/network-instance {network_instance} protocols bgp neighbor *")
    if not tree:
        return {}

    out = {}
    for ni in tree.get("network-instance", []):
        for nbr in (ni.get("protocols", {}).get("bgp", {}) or {}).get("neighbor", []):
            peer = nbr.get("peer-address")
            if not peer:
                continue
            for af in nbr.get("afi-safi", []):
                if af.get("afi-safi-name") != "ipv4-unicast":
                    continue
                limits = (af.get("ipv4-unicast", {}) or {}).get(
                    "prefix-limit-received", {}) or {}
                out[peer] = {
                    "received": af.get("received-routes"),
                    "active": af.get("active-routes"),
                    "rejected": af.get("rejected-routes"),
                    "max": limits.get("max-received-routes"),
                    "warning_pct": limits.get("warning-threshold-pct"),
                    "exceeded": limits.get("prefix-limit-exceeded"),
                }
    return out


def advertised_to(peer, network_instance="default", afi="ipv4-unicast"):
    """Every prefix this router is actually ADVERTISING to one neighbour.

    Not what the export policy says it should advertise -- what came out
    the other side of it. The difference is the whole point: a policy can
    be attached to the wrong peer-group, a prefix-list can carry one `le`
    too many, an aggregate can leak its components, and in every one of
    those cases the configuration reads correctly and the announcement is
    wrong. Only the post-policy adj-rib-out knows.

    Returns a sorted list of prefixes, or None when the device could not be
    read -- which is "I do not know", not "it is announcing nothing".
    """
    # `route * neighbor <peer> path-id *`: SR Linux requires a key for
    # every list node in the path before it will accept the pipe, and
    # `route` has three of them.
    tree = get(f"/network-instance {network_instance} bgp-rib afi-safi {afi} "
               f"{afi} rib-in-out rib-out-post route * neighbor {peer} "
               f"path-id *")
    if tree is None:
        return None

    prefixes = set()
    for ni in tree.get("network-instance", []):
        for af in (ni.get("bgp-rib", {}) or {}).get("afi-safi", []):
            rib = ((af.get(afi, {}) or {}).get("rib-in-out", {}) or {})
            for route in (rib.get("rib-out-post", {}) or {}).get("route", []):
                if route.get("neighbor") == peer and route.get("prefix"):
                    prefixes.add(route["prefix"])
    return sorted(prefixes)
