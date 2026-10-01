#!/usr/bin/env python3
"""Generate the bootstrap config and the fabric pillar from one address plan.

Hand-written per-device configs are how addressing plans drift from
reality. The plan lives once, here and in docs/addressing.md, and the
configs are output. Adding a fifth router is a few lines in PLAN, not a
new file to keep in step with three others.

Two outputs, one plan:

    clab/configs/<device>.cfg     bootstrap -- management, NTP, the IS-IS
                                  keychain, the loopback, and the physical
                                  interfaces with their addresses. Enough
                                  for the box to be reachable and for Salt
                                  to take over. Nothing else.

    salt/pillar/fabric.sls        the same plan as data, so Salt can render
                                  the protocol layer from it.

The split is not cosmetic. containerlab delivers a startup-config on a
best-effort basis and silently drops the tail of a long one: srl4 at 88
lines applied completely, srl1 at 113 lost its BGP neighbours, srl3 at 147
lost its eBGP session -- with no error anywhere, leaving a router that looks
configured and has no sessions. Keeping bootstrap short makes that failure
mode go away.

It is also the right shape. A real ISP does not ship routers with their
full protocol config baked in; it ships them with enough to be reachable
and lets the automation converge them to golden state. That is what ZTP is,
and it means the protocol layer -- IS-IS, BFD, BGP, policy -- is managed,
drift-detected and audited like everything else, instead of being a file
somebody edited once.

srl4 is the exception and keeps its full config, because it is the upstream
provider: there is no proxy-minion for it and the automation is not allowed
to reach it.

    python3 clab/gen-configs.py
"""

import os
import ipaddress
import pathlib

AS_OURS = 65001
AS_TRANSIT = 64500
TRANSIT_HOSTNAME = "srl4"
# What we announce to the world. One aggregate, and the two /26s inside it
# stay inside it -- a more-specific escaping is one of the leaks route_leak
# exists to catch.
CUSTOMER_AGGREGATE = "203.0.113.0/24"
# The two /26s inside the aggregate. They exist in srl3's table and must
# never leave it: transit-out permits the aggregate and nothing else, so
# they are filtered on the way out, not absent.
#
# They are the demonstration. Relaxing transit-out makes srl3 announce
# everything it knows -- but everything it knows that came FROM the
# provider is dropped by the provider's own AS-path loop check, so a leak
# built only on re-announcing transit routes shows nothing on the provider
# side and an expert is right to say BGP saved you rather than automation.
# A more-specific of your own space has no loop to catch it. It is
# accepted, it wins on longest-prefix, and deaggregation leaks are what
# actually happens. Without these two prefixes the route-leak demo proves
# nothing on the wire.
CUSTOMER_MORE_SPECIFICS = ["203.0.113.0/26", "203.0.113.64/26"]
BOGONS = [
    "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
]
# From the environment, never from here. It is a weak key on purpose -- this
# is a lab -- but a key written into source is a key in every clone of a
# public repository, and the point of a keychain is that it can be rotated.
#
# No fallback. A default would be silently adopted by everyone who forgot
# to run gen-secrets.sh, which is the same as having no key at all, and it
# would be invisible: the fabric would come up and IS-IS would authenticate
# perfectly against the shared default.
ISIS_KEY = os.environ.get("ISIS_AUTH_KEY", "").strip()
if not ISIS_KEY:
    raise SystemExit(
        "ISIS_AUTH_KEY is not set.\n"
        "  It is the IS-IS authentication key and it comes from .env, so that\n"
        "  it is not the same key in every clone of this repository.\n"
        "    ./scripts/gen-secrets.sh     writes one\n"
        "    set -a; . ./.env; set +a     then re-run this")
# Pinned, and reserved in docs/addressing.md. The devices are configured to
# send here; a syslog destination that moves stops working on the next
# restart, and nobody notices because the symptom is silence.
SYSLOG_SERVER = os.environ.get("MGMT_PREFIX", "172.30.30") + ".30"
SYSLOG_PORT = 5514
# The push detection path gets its own destination rather than a copy relayed
# from the first. The routers support several remote-servers, so each consumer
# owns a port and neither can lose the other's traffic -- and a relay in
# between would be one more process whose silence looks like health.
NAPALM_LOGS_SERVER = os.environ.get("MGMT_PREFIX", "172.30.30") + ".31"
NAPALM_LOGS_PORT = 5515

# One plan. Everything below is derived from it.
PLAN = {
    "srl1": {
        "role": "core-rr",
        "loopback4": "10.255.0.1/32",
        "loopback6": "2001:db8:0:255::1/128",
        "sysid": "0000.0000.0001",
        "links": {
            "ethernet-1/1": {"peer": "srl2", "peer_interface": "ethernet-1/1",
                             "v4": "10.255.1.0/31", "v6": "2001:db8:0:1::/127"},
            "ethernet-1/2": {"peer": "srl3", "peer_interface": "ethernet-1/2",
                             "v4": "10.255.1.4/31", "v6": "2001:db8:0:1::4/127"},
        },
        "ibgp": ["10.255.0.2", "10.255.0.3"],
        "rr_clients": ["10.255.0.3"],
    },
    "srl2": {
        "role": "core-rr",
        "loopback4": "10.255.0.2/32",
        "loopback6": "2001:db8:0:255::2/128",
        "sysid": "0000.0000.0002",
        "links": {
            "ethernet-1/1": {"peer": "srl1", "peer_interface": "ethernet-1/1",
                             "v4": "10.255.1.1/31", "v6": "2001:db8:0:1::1/127"},
            "ethernet-1/2": {"peer": "srl3", "peer_interface": "ethernet-1/1",
                             "v4": "10.255.1.2/31", "v6": "2001:db8:0:1::2/127"},
        },
        "ibgp": ["10.255.0.1", "10.255.0.3"],
        "rr_clients": ["10.255.0.3"],
    },
    "srl3": {
        "role": "border",
        "loopback4": "10.255.0.3/32",
        "loopback6": "2001:db8:0:255::3/128",
        "sysid": "0000.0000.0003",
        "links": {
            "ethernet-1/1": {"peer": "srl2", "peer_interface": "ethernet-1/2",
                             "v4": "10.255.1.3/31", "v6": "2001:db8:0:1::3/127"},
            "ethernet-1/2": {"peer": "srl1", "peer_interface": "ethernet-1/2",
                             "v4": "10.255.1.5/31", "v6": "2001:db8:0:1::5/127"},
            # The transit uplink is NOT in the IGP: it is an eBGP boundary,
            # and running your IGP with a provider is how you learn why not.
            # peer_ip is stated, not derived. Computing "the other end of a
            # /31" from the local address is the kind of cleverness that
            # works until the day the plan uses a /30 or an odd-numbered
            # host, and then produces a valid-looking wrong answer.
            "ethernet-1/3": {"peer": "srl4", "peer_interface": "ethernet-1/1",
                             "v4": "198.51.100.1/31",
                             "v6": "2001:db8:ffff::1/127", "igp": False,
                             "peer_ip": "198.51.100.0"},
        },
        "ibgp": ["10.255.0.1", "10.255.0.2"],
        "rr_clients": [],
    },
    "srl4": {
        # Not ours. A separate AS whose configuration we do not control,
        # which is the normal condition of an ISP and the source of most of
        # its interesting faults.
        "role": "transit",
        "asn": AS_TRANSIT,
        "loopback4": "10.255.0.4/32",
        "loopback6": "2001:db8:0:255::4/128",
        "sysid": "0000.0000.0004",
        "links": {
            "ethernet-1/1": {"peer": "srl3", "peer_interface": "ethernet-1/3",
                             "v4": "198.51.100.0/31",
                             "v6": "2001:db8:ffff::/127", "igp": False},
        },
        "ibgp": [],
        "rr_clients": [],
        # What the upstream sends us: a default plus a couple of
        # more-specifics, so "did we actually receive routes" has a visible
        # answer. The three-node lab sat at [0/0/0] for its whole life.
        "originates": ["0.0.0.0/0", "198.18.0.0/15", "192.0.2.0/24"],
    },
}


def link_description(link):
    """The interface description, defined once.

    Both the bootstrap config and the NetBox seed use this. When they
    disagree the drift beacon fires forever: NetBox says one thing, the
    device says another, sync_from_netbox pushes NetBox's version, the
    device reboots back to the bootstrap version, and round it goes. The
    only way that ends is if both sides are generated from the same string.
    """
    if link.get("igp", True):
        return (f"P2P to {link['peer']}:{link['peer_interface']} "
                f"— IS-IS L2, MTU 9232")
    return (f"IP transit to AS{AS_TRANSIT} via {link['peer']} "
            f"— circuit TRANSIT-10G-001")


def _base(name, cfg):
    """Management, time, the IGP keychain, the loopback and the links.

    Everything a box needs to be reachable and to have its interfaces
    addressed, and nothing more. Deliberately short: containerlab drops the
    tail of a long startup-config without saying so.
    """
    asn = cfg.get("asn", AS_OURS)
    lo4 = cfg["loopback4"].split("/")[0]
    out = [
        f"# {name} — bootstrap only, generated by clab/gen-configs.py",
        f"# role: {cfg['role']}    AS{asn}    router-id {lo4}",
        "# Do not edit by hand: edit PLAN in the generator and re-run it.",
        "#",
        "# The protocol layer (IS-IS, BFD, BGP, policy) is NOT here. Salt",
        "# renders it from salt/pillar/fabric.sls, so it is drift-detected",
        "# and audited like every other change.",
        "",
        "set / system json-rpc-server admin-state enable",
        "set / system json-rpc-server network-instance mgmt http admin-state enable",
        "",
        "# Every timestamp in the audit trail is compared against timestamps",
        "# from other devices. Without NTP that comparison means nothing, and",
        "# the audit trail is the product here.",
        "set / system ntp admin-state enable",
        "set / system ntp network-instance mgmt",
        "set / system ntp server 172.30.30.1 iburst true",
        "",
        "# An unauthenticated neighbour cannot join the IGP. In the clear",
        "# because this is a lab; in production it comes from a vault and is",
        "# rotated on a schedule the keychain already supports.",
        "set / system authentication keychain isis-core admin-state enable",
        "set / system authentication keychain isis-core type isis",
        "set / system authentication keychain isis-core key 1 algorithm hmac-md5",
        f'set / system authentication keychain isis-core key 1 authentication-key "{ISIS_KEY}"',
        "",
        "set / interface system0 admin-state enable",
        "set / interface system0 subinterface 0 admin-state enable",
        "set / interface system0 subinterface 0 ipv4 admin-state enable",
        f"set / interface system0 subinterface 0 ipv4 address {cfg['loopback4']}",
        "set / interface system0 subinterface 0 ipv6 admin-state enable",
        f"set / interface system0 subinterface 0 ipv6 address {cfg['loopback6']}",
        "",
    ]
    for iface, link in cfg["links"].items():
        igp = link.get("igp", True)
        out += [
            f"# {iface} -> {link['peer']}" + ("" if igp else "   (eBGP boundary, not in the IGP)"),
            f"set / interface {iface} admin-state enable",
            f'set / interface {iface} description "{link_description(link)}"',
            # 9232 so jumbo frames survive any encapsulation added later. The
            # MTU has to match on both ends or IS-IS hello padding kills the
            # adjacency while ping still works.
            f"set / interface {iface} mtu 9232",
            f"set / interface {iface} subinterface 0 admin-state enable",
            f"set / interface {iface} subinterface 0 ipv4 admin-state enable",
            f"set / interface {iface} subinterface 0 ipv4 address {link['v4']}",
            f"set / interface {iface} subinterface 0 ipv6 admin-state enable",
            f"set / interface {iface} subinterface 0 ipv6 address {link['v6']}",
        ]
    out += [
        "",
        "set / network-instance default type default",
        "set / network-instance default admin-state enable",
        "set / network-instance default interface system0.0",
    ]
    for iface in cfg["links"]:
        out.append(f"set / network-instance default interface {iface}.0")
    return out


def protocols(name, cfg):
    """IS-IS, BFD and BGP. Rendered by Salt for managed devices; baked into
    the bootstrap only for srl4, which has no proxy-minion because it is the
    upstream provider and the automation is not allowed to reach it."""
    asn = cfg.get("asn", AS_OURS)
    lo4 = cfg["loopback4"].split("/")[0]
    out = ["", "# --- BFD -------------------------------------------------------",
           "# 300ms x 3. Without it IS-IS takes ~27s to notice a dead neighbour",
           "# and BGP takes 90. Fast convergence and automated repair are",
           "# different jobs: BFD reroutes around a failure, it does not fix a",
           "# misconfiguration or re-enable an interface somebody shut."]
    for iface in cfg["links"]:
        out += [
            f"set / bfd subinterface {iface}.0 admin-state enable",
            f"set / bfd subinterface {iface}.0 desired-minimum-transmit-interval 300000",
            f"set / bfd subinterface {iface}.0 required-minimum-receive 300000",
            f"set / bfd subinterface {iface}.0 detection-multiplier 3",
        ]

    igp_links = [i for i, l in cfg["links"].items() if l.get("igp", True)]
    if igp_links:
        out += [
            "",
            "# --- IS-IS -----------------------------------------------------",
            "set / network-instance default protocols isis instance main admin-state enable",
            "set / network-instance default protocols isis instance main level-capability L2",
            f"set / network-instance default protocols isis instance main net [ 49.0001.{cfg['sysid']}.00 ]",
            "set / network-instance default protocols isis instance main ipv4-unicast admin-state enable",
            "set / network-instance default protocols isis instance main ipv6-unicast admin-state enable",
            "set / network-instance default protocols isis instance main authentication keychain isis-core",
            "# Signal 'do not route through me' until convergence finishes, so",
            "# a rebooting node does not black-hole traffic it cannot forward.",
            "set / network-instance default protocols isis instance main overload on-boot set-bit true",
            "set / network-instance default protocols isis instance main overload on-boot timeout 90",
            "set / network-instance default protocols isis instance main interface system0.0 passive true",
        ]
        for iface in igp_links:
            out += [
                f"set / network-instance default protocols isis instance main interface {iface}.0 circuit-type point-to-point",
                f"set / network-instance default protocols isis instance main interface {iface}.0 hello-padding adaptive",
                f"set / network-instance default protocols isis instance main interface {iface}.0 ipv4-unicast admin-state enable",
                f"set / network-instance default protocols isis instance main interface {iface}.0 ipv4-unicast enable-bfd true",
                f"set / network-instance default protocols isis instance main interface {iface}.0 ipv6-unicast admin-state enable",
                f"set / network-instance default protocols isis instance main interface {iface}.0 ipv6-unicast enable-bfd true",
            ]

    out += [
        "",
        "# --- BGP -------------------------------------------------------",
        "set / network-instance default protocols bgp admin-state enable",
        f"set / network-instance default protocols bgp autonomous-system {asn}",
        f"set / network-instance default protocols bgp router-id {lo4}",
        "set / network-instance default protocols bgp afi-safi ipv4-unicast admin-state enable",
        "set / network-instance default protocols bgp afi-safi ipv6-unicast admin-state enable",
    ]

    if cfg["ibgp"]:
        out += [
            "set / network-instance default protocols bgp group ibgp admin-state enable",
            f"set / network-instance default protocols bgp group ibgp peer-as {asn}",
            f"set / network-instance default protocols bgp group ibgp transport local-address {lo4}",
            "set / network-instance default protocols bgp group ibgp afi-safi ipv4-unicast admin-state enable",
            "set / network-instance default protocols bgp group ibgp afi-safi ipv6-unicast admin-state enable",
            "set / network-instance default protocols bgp group ibgp failure-detection fast-failover true",
        ]
        if cfg["rr_clients"]:
            out += [
                "set / network-instance default protocols bgp group ibgp route-reflector client true",
                "set / network-instance default protocols bgp group ibgp route-reflector cluster-id 10.255.0.255",
            ]
        for peer in cfg["ibgp"]:
            out += [
                f"set / network-instance default protocols bgp neighbor {peer} admin-state enable",
                f"set / network-instance default protocols bgp neighbor {peer} peer-group ibgp",
            ]

    if cfg["role"] == "transit":
        out += [
            "set / network-instance default next-hop-groups group blackhole blackhole generate-icmp true",
        ]
        for prefix in cfg["originates"]:
            out += [
                f"set / network-instance default static-routes route {prefix} admin-state enable",
                f"set / network-instance default static-routes route {prefix} next-hop-group blackhole",
            ]
        out += [
            "set / routing-policy prefix-set transit-originate prefix 0.0.0.0/0 mask-length-range exact",
            "set / routing-policy prefix-set transit-originate prefix 198.18.0.0/15 mask-length-range exact",
            "set / routing-policy prefix-set transit-originate prefix 192.0.2.0/24 mask-length-range exact",
            "set / routing-policy policy transit-export statement 10 match prefix-set transit-originate",
            "set / routing-policy policy transit-export statement 10 action policy-result accept",
            "set / routing-policy policy transit-export default-action policy-result reject",
            "set / network-instance default protocols bgp group ebgp-customer admin-state enable",
            f"set / network-instance default protocols bgp group ebgp-customer peer-as {AS_OURS}",
            "set / network-instance default protocols bgp group ebgp-customer export-policy [ transit-export ]",
            "set / network-instance default protocols bgp group ebgp-customer afi-safi ipv4-unicast admin-state enable",
            "set / network-instance default protocols bgp neighbor 198.51.100.1 admin-state enable",
            "set / network-instance default protocols bgp neighbor 198.51.100.1 peer-group ebgp-customer",
        ]

    return out


def frr_config(name, cfg):
    """The upstream provider, in FRR instead of SR Linux.

    srl4 does one job -- hold an eBGP session and originate a default plus
    two more-specifics -- and SR Linux charges about 1.8GB of RAM for the
    privilege whether it is doing that job or sitting idle (measured: an
    otherwise-unconfigured srl4 peaked at 1.84GB). FRR does the same job in
    roughly 200MB, which is the difference between this lab fitting on a
    laptop and being OOM-killed on one.

    It is also the more honest topology. A transit provider is a different
    company running different software that you cannot log into; making it
    a fourth identical SR Linux quietly implied otherwise. The trust
    boundary is now visible in the topology file, not just asserted in a
    comment.

    The policy below is a line-for-line equivalent of the SR Linux config
    it replaces: originate exactly three prefixes, reject everything else
    outbound, and accept whatever the customer sends (which is what the
    SR Linux version did, having no import policy at all).
    """
    link = cfg["links"]["ethernet-1/1"]
    router_id = cfg["loopback4"].split("/")[0]
    # The far end is the other address in the /31. Deriving it keeps this
    # in step with PLAN instead of restating the peer's address here.
    net = ipaddress.ip_interface(link["v4"])
    peer_ip = next(str(h) for h in net.network if h != net.ip)

    out = [
        "frr defaults traditional",
        f"hostname {name}",
        "log stdout informational",
        "!",
        "interface lo",
        f" ip address {cfg['loopback4']}",
        "exit",
        "!",
        # containerlab names a linux node's first data link eth1.
        "interface eth1",
        # link_description() is written from the customer's side. From the
        # provider's side the same circuit is a customer, not an uplink.
        f" description Customer AS{AS_OURS} via {link['peer']}",
        f" ip address {link['v4']}",
        f" ipv6 address {link['v6']}",
        "exit",
        "!",
    ]

    # Something has to be in the RIB before BGP will advertise it. Null0 is
    # what a real transit router would not do, but it is what makes the
    # prefixes exist without inventing downstream customers for them.
    for prefix in cfg["originates"]:
        out.append(f"ip route {prefix} Null0")
    out.append("!")

    out += [
        f"router bgp {cfg['asn']}",
        f" bgp router-id {router_id}",
        " no bgp default ipv4-unicast",
        # SR Linux applied an export policy and no import policy. FRR
        # refuses an eBGP session with neither unless told not to, so this
        # keeps the two versions behaviourally identical.
        " no bgp ebgp-requires-policy",
        f" neighbor {peer_ip} remote-as {AS_OURS}",
        f" neighbor {peer_ip} description {link['peer']} (customer)",
        " !",
        " address-family ipv4 unicast",
        f"  neighbor {peer_ip} activate",
        f"  neighbor {peer_ip} route-map TRANSIT-EXPORT out",
        # Without this, `show bgp ipv4 unicast neighbors <peer> received-routes`
        # answers "Inbound soft reconfiguration not enabled" -- and that is
        # the one command that settles a route-leak argument, because it is
        # the PROVIDER's account of what it was sent rather than ours of
        # what we think we sent. Cheap here; on a real edge router it is a
        # full extra copy of the table and you would use BMP instead.
        f"  neighbor {peer_ip} soft-reconfiguration inbound",
    ]
    for prefix in cfg["originates"]:
        out.append(f"  network {prefix}")
    out += [
        " exit-address-family",
        "exit",
        "!",
    ]

    for i, prefix in enumerate(cfg["originates"], start=1):
        out.append(f"ip prefix-list TRANSIT-ORIGINATE seq {i * 10} "
                   f"permit {prefix}")
    out += [
        "!",
        "route-map TRANSIT-EXPORT permit 10",
        " match ip address prefix-list TRANSIT-ORIGINATE",
        "exit",
        "!",
        # Everything not originated by this AS is not ours to advertise.
        "route-map TRANSIT-EXPORT deny 20",
        "exit",
        "!",
        "line vty",
        "!",
    ]
    return out


def frr_vtysh():
    """vtysh reads its own file, and complains on every single invocation
    if it is missing. 'service integrated-vtysh-config' belongs here rather
    than in frr.conf: it is the declaration that frr.conf is the one
    configuration file, which is a statement about vtysh, not about FRR."""
    return [
        f"hostname {TRANSIT_HOSTNAME}",
        "service integrated-vtysh-config",
        "",
    ]


def frr_daemons():
    """Which FRR daemons start. Everything not needed stays off -- each one
    that runs is memory this node exists to save."""
    on = {"zebra", "bgpd", "staticd"}
    names = ["zebra", "bgpd", "ospfd", "ospf6d", "ripd", "ripngd", "isisd",
             "pimd", "pim6d", "ldpd", "nhrpd", "eigrpd", "babeld", "sharpd",
             "pbrd", "bfdd", "fabricd", "vrrpd", "pathd", "staticd"]
    out = [f"{n}={'yes' if n in on else 'no'}" for n in names]
    out += [
        "",
        'zebra_options="  -A 127.0.0.1 -s 90000000"',
        'bgpd_options="   -A 127.0.0.1"',
        'staticd_options="-A 127.0.0.1"',
        "",
    ]
    return out


def render_netbox_plan():
    """The same plan again, shaped for the NetBox seed.

    NetBox is the source of truth for intent, but the plan is the source of
    truth for NetBox -- otherwise the addressing lives in two places and
    they drift, which is the failure this whole repo is about.
    """
    import json
    mgmt = {"srl1": "172.30.30.21/24", "srl2": "172.30.30.22/24",
            "srl3": "172.30.30.23/24", "srl4": "172.30.30.24/24"}
    roles = {"core-rr": "core-router", "border": "edge-router"}

    devices = {}
    for name, cfg in PLAN.items():
        if cfg["role"] == "transit":
            # Modelled as a provider circuit, not as one of our devices.
            continue
        ifaces = [
            ["system0", "virtual",
             "Loopback — IS-IS router ID and BGP transport", cfg["loopback4"]],
            ["mgmt0", "1000base-t",
             "Out-of-band management — salt-proxy reaches the device here",
             mgmt[name]],
        ]
        for iface, link in cfg["links"].items():
            ifaces.append([iface, "100gbase-x-qsfp28",
                           link_description(link), link["v4"]])
        devices[name] = {
            "role": roles[cfg["role"]],
            "interfaces": ifaces,
        }
        # The BGP intent, for the border router only.
        #
        # This is what bgp_policy renders from and what config_drift_policy
        # and route_leak compare against. It lived only in a NetBox
        # database until now -- created by hand once, never generated --
        # so `docker compose down -v` took it with it and a fresh clone
        # never had it at all. Every one of those three then decided the
        # device was "not a border router, nothing to do", silently.
        if cfg["role"] == "border":
            transit_link = next(
                (l for l in cfg["links"].values() if l["peer"] == "srl4"), None)
            if transit_link:
                net = ipaddress.ip_interface(transit_link["v4"])
                peer_ip = next(str(h) for h in net.network if h != net.ip)
                devices[name]["bgp"] = {
                    "asn": AS_OURS,
                    "originate": [
                        {"prefix": CUSTOMER_AGGREGATE,
                         "description": "customer aggregate, sites A and B"},
                    ] + [
                        # Present in the table, absent from the announcement.
                        # transit-out permits the aggregate only, so these
                        # are held in by policy rather than by not existing
                        # -- which is what makes relaxing that policy a
                        # visible leak on the provider's side instead of a
                        # no-op. See CUSTOMER_MORE_SPECIFICS above.
                        {"prefix": spec,
                         "description": "site subnet, must not leave the aggregate"}
                        for spec in CUSTOMER_MORE_SPECIFICS
                    ],
                    "transit": {
                        "peer_as": AS_TRANSIT,
                        "peer_ip": peer_ip,
                        "export": {"prefixes": [CUSTOMER_AGGREGATE]},
                        "import": {
                            # Our own space coming back at us is either a
                            # leak or a hijack. Either way, not ours to
                            # learn from a transit provider.
                            "reject_own": [CUSTOMER_AGGREGATE],
                            "reject_bogons": BOGONS,
                            "accept_default": True,
                            "max_prefix_length": 24,
                        },
                    },
                }

    cables = []
    seen = set()
    for name, cfg in PLAN.items():
        for iface, link in cfg["links"].items():
            ends = tuple(sorted([(name, iface),
                                 (link["peer"], link["peer_interface"])]))
            if ends in seen or link["peer"] == "srl4" or name == "srl4":
                continue
            seen.add(ends)
            cables.append([list(ends[0]), list(ends[1])])

    prefixes = [
        ["10.255.0.0/24", "Loopbacks — one /32 per router, IS-IS advertised", "container"],
        ["10.255.1.0/24", "Infrastructure point-to-point links, /31 each", "container"],
        ["198.51.100.0/31", "Transit interconnect — provider space, not ours", "active"],
        ["203.0.113.0/24", "Customer aggregate — what we announce to AS64500", "container"],
        ["203.0.113.0/26", "Site A customers", "active"],
        ["203.0.113.64/26", "Site B customers", "active"],
    ]

    return json.dumps({"devices": devices, "cables": cables,
                       "prefixes": prefixes,
                       "asn": AS_OURS, "transit_asn": AS_TRANSIT}, indent=2) + "\n"


def render_pillar():
    """The same plan, as data Salt can render from."""
    import json
    managed = {n: c for n, c in PLAN.items() if c["role"] != "transit"}
    body = {
        "fabric": {
            "asn": AS_OURS,
            "transit_asn": AS_TRANSIT,
            "isis_keychain": "isis-core",
            "syslog_server": SYSLOG_SERVER,
            "syslog_port": SYSLOG_PORT,
            # Rendered as a second remote-server by golden_config. Both
            # destinations are listed so the template does not have to know
            # how many consumers there are.
            "syslog_destinations": [
                {"host": SYSLOG_SERVER, "port": SYSLOG_PORT},
                {"host": NAPALM_LOGS_SERVER, "port": NAPALM_LOGS_PORT},
            ],
            "rr_cluster_id": "10.255.0.255",
            "devices": {
                n: {
                    "role": c["role"],
                    "loopback4": c["loopback4"],
                    "loopback6": c["loopback6"],
                    "sysid": c["sysid"],
                    "links": c["links"],
                    "ibgp": c["ibgp"],
                    "rr_clients": c["rr_clients"],
                }
                for n, c in managed.items()
            },
        }
    }
    header = """# Generated by clab/gen-configs.py — do not edit by hand.
#
# The fabric as data. Salt renders the protocol layer from this
# (states/golden_config.sls), so IS-IS, BFD and BGP are managed,
# drift-detected and audited rather than baked into a startup-config
# nobody looks at again.
#
# srl4 is absent on purpose: it is the upstream provider's router, it has
# no proxy-minion, and the automation is not allowed to reach it.
"""
    return header + json.dumps(body, indent=2) + "\n"


if __name__ == "__main__":
    outdir = pathlib.Path(__file__).parent / "configs"
    outdir.mkdir(exist_ok=True)
    for name, cfg in PLAN.items():
        if cfg["role"] == "transit":
            # The provider's router runs FRR, not SR Linux -- see
            # frr_config() for why. It has no proxy-minion either way, so
            # all of its configuration lives in files bind-mounted at boot.
            for fname, lines in ((f"{name}-frr.conf", frr_config(name, cfg)),
                                 (f"{name}-vtysh.conf", frr_vtysh()),
                                 (f"{name}-daemons", frr_daemons())):
                path = outdir / fname
                path.write_text("\n".join(lines) + "\n")
                print(f"wrote {path.name:16s} {len(lines):4d} lines")
            continue

        lines = _base(name, cfg)
        path = outdir / f"{name}.cfg"
        path.write_text("\n".join(lines) + "\n")
        print(f"wrote {path.name:16s} {len(lines):4d} lines")

    pillar = pathlib.Path(__file__).parent.parent / "salt" / "pillar" / "fabric.sls"
    pillar.write_text(render_pillar())

    nb = pathlib.Path(__file__).parent.parent / "netbox" / "plan.json"
    nb.write_text(render_netbox_plan())
    print(f"wrote netbox/plan.json")
    print(f"wrote {pillar.relative_to(pillar.parent.parent.parent)}")
