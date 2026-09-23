"""
Seed NetBox to the level an ISP actually runs it at, not the bare minimum
the automation needs. A NetBox with three nameless devices in it is not
believable to anyone who operates a real one — regions, sites, racks,
tenancy, contacts, platforms, IPAM and circuits are what make it a source
of truth people trust enough to automate from.

Idempotent: safe to re-run.
"""

import json
import os
import sys

import requests

BASE = os.environ.get("NETBOX_URL", "http://netbox:8080").rstrip("/") + "/api"
# Taken from the environment; docker-compose passes it in from .env, and
# scripts/seed-netbox.sh does the same when this runs as a one-off.
TOKEN = os.environ["NETBOX_API_TOKEN"]

# The addressing, interfaces and cabling all come from clab/gen-configs.py,
# via netbox/plan.json. NetBox is the source of truth for intent; the plan
# is the source of truth for NetBox. Duplicating the addressing here is how
# the two drift apart, which is the exact failure this repo is about.
PLAN = json.load(open(os.path.join(os.path.dirname(__file__), "plan.json")))
H = {"Authorization": f"Token {TOKEN}", "Content-Type": "application/json"}

created, reused, updated, failed = [], [], [], []


def api(method, path, data=None, params=None):
    r = requests.request(method, f"{BASE}/{path}/", json=data, params=params,
                         headers=H, timeout=20)
    if r.status_code >= 400:
        failed.append(f"{method} {path}: {r.status_code} {r.text[:200]}")
        return None
    return r.json()


def _differs(found, data):
    """Which fields in `data` disagree with what NetBox already holds.

    Nested objects are compared by id: the payload carries {"id": N} from
    ident(), while NetBox returns the whole related object.
    """
    out = {}
    for key, want in data.items():
        have = found.get(key)
        if isinstance(want, dict) and "id" in want:
            if isinstance(have, dict) and have.get("id") == want["id"]:
                continue
            if have == want["id"]:
                continue
            out[key] = want
        elif isinstance(have, dict) and "value" in have:
            # choice fields come back as {"value": "active", "label": ...}
            if have["value"] != want:
                out[key] = want
        elif have != want:
            out[key] = want
    return out


def ensure(path, lookup, data, label=None):
    """Get-or-create-or-converge by a unique-ish lookup.

    The third of those matters. A seed that only creates cannot bring an
    existing NetBox back in line with the plan: change an interface
    description in the plan, re-run, and NetBox keeps the old one for ever
    while the devices get the new one -- so sync_from_netbox then pushes the
    stale description back and the drift beacon fires in a loop that never
    ends. A source of truth has to converge, not just exist.
    """
    found = api("GET", path, params=lookup)
    if found and found.get("results"):
        obj = found["results"][0]
        delta = _differs(obj, data)
        if delta:
            patched = api("PATCH", f"{path}/{obj['id']}", delta)
            if patched:
                updated.append(f"{label or path} ({', '.join(delta)})")
                return patched
        reused.append(label or path)
        return obj
    obj = api("POST", path, data)
    if obj:
        created.append(label or path)
    return obj


def ident(obj):
    return obj["id"] if obj else None


# ── Tags ──────────────────────────────────────────────────────────────
tag_auto = ensure("extras/tags", {"slug": "salt-managed"},
                  {"name": "Salt-managed", "slug": "salt-managed", "color": "3b82f6",
                   "description": "Configuration enforced by SaltStack self-heal loop"},
                  "tag:salt-managed")
tag_core = ensure("extras/tags", {"slug": "core-network"},
                  {"name": "Core Network", "slug": "core-network", "color": "8b5cf6"},
                  "tag:core-network")

# ── Tenancy ───────────────────────────────────────────────────────────
tgroup = ensure("tenancy/tenant-groups", {"slug": "service-providers"},
                {"name": "Service Providers", "slug": "service-providers"},
                "tenant-group")
tenant = ensure("tenancy/tenants", {"slug": "isp-core"},
                {"name": "ISP Core Network", "slug": "isp-core",
                 "group": ident(tgroup),
                 "description": "National transit and MPLS core"},
                "tenant")

# ── Contacts ──────────────────────────────────────────────────────────
crole_arch = ensure("tenancy/contact-roles", {"slug": "chief-architect"},
                    {"name": "Chief Architect", "slug": "chief-architect"},
                    "contact-role:architect")
crole_noc = ensure("tenancy/contact-roles", {"slug": "noc"},
                   {"name": "NOC On-call", "slug": "noc"}, "contact-role:noc")
cgroup = ensure("tenancy/contact-groups", {"slug": "network-engineering"},
                {"name": "Network Engineering", "slug": "network-engineering"},
                "contact-group")
contact = ensure("tenancy/contacts", {"name": "Network Operations"},
                 {"name": "Network Operations",
                  "title": "Chief Architect",
                  "email": "noc@example.net",
                  "phone": "+000-0000000",
                  "group": ident(cgroup),
                  "description": "Owner of the network automation platform"},
                 "contact:noc")

# ── Geography ─────────────────────────────────────────────────────────
region_mn = ensure("dcim/regions", {"slug": "mongolia"},
                   {"name": "Mongolia", "slug": "mongolia"}, "region:mongolia")
region_ub = ensure("dcim/regions", {"slug": "ulaanbaatar"},
                   {"name": "Ulaanbaatar", "slug": "ulaanbaatar",
                    "parent": ident(region_mn)}, "region:ulaanbaatar")
sgroup = ensure("dcim/site-groups", {"slug": "core-pop"},
                {"name": "Core PoP", "slug": "core-pop",
                 "description": "Points of presence carrying transit"},
                "site-group")

SITES = [
    ("DC1 — Primary Core", "dc1-primary-core", region_ub,
     "Primary data centre, carrier-neutral facility"),
    ("DC2 — Secondary Core", "dc2-secondary-core", region_ub,
     "Secondary core site, geographically separated"),
    ("POP3 — Regional Edge", "pop3-regional-edge", region_mn,
     "Regional aggregation edge"),
]
sites = {}
for name, slug, region, desc in SITES:
    sites[slug] = ensure("dcim/sites", {"slug": slug},
                         {"name": name, "slug": slug, "status": "active",
                          "region": ident(region), "group": ident(sgroup),
                          "tenant": ident(tenant), "description": desc,
                          "physical_address": "Ulaanbaatar, Mongolia",
                          "time_zone": "Asia/Ulaanbaatar"},
                         f"site:{slug}")

# ── Locations and racks ───────────────────────────────────────────────
racks = {}
for i, (slug, rname) in enumerate(
        [("dc1-primary-core", "R01"), ("dc2-secondary-core", "R02"),
         ("pop3-regional-edge", "R03")], start=1):
    loc = ensure("dcim/locations", {"slug": f"{slug}-hall-a"},
                 {"name": "Hall A", "slug": f"{slug}-hall-a",
                  "site": ident(sites[slug]), "status": "active"},
                 f"location:{slug}")
    racks[slug] = ensure("dcim/racks", {"name": rname, "site_id": ident(sites[slug])},
                         {"name": rname, "site": ident(sites[slug]),
                          "location": ident(loc), "status": "active",
                          "u_height": 42, "tenant": ident(tenant),
                          "description": f"Core rack {rname}"},
                         f"rack:{rname}")

# ── Hardware ──────────────────────────────────────────────────────────
manu = ensure("dcim/manufacturers", {"slug": "nokia"},
              {"name": "Nokia", "slug": "nokia"}, "manufacturer")
dtype = ensure("dcim/device-types", {"slug": "7220-ixr-d3l"},
               {"manufacturer": ident(manu), "model": "7220 IXR-D3L",
                "slug": "7220-ixr-d3l", "u_height": 1,
                "is_full_depth": True,
                "comments": "32x100G QSFP28 — used here as core and edge"},
               "device-type")
platform = ensure("dcim/platforms", {"slug": "srlinux-24-10"},
                  {"name": "Nokia SR Linux 24.10.1", "slug": "srlinux-24-10",
                   "manufacturer": ident(manu),
                   "description": "NAPALM driver: srlinux (JSON-RPC)"},
                  "platform")
role_core = ensure("dcim/device-roles", {"slug": "core-router"},
                   {"name": "Core Router", "slug": "core-router",
                    "color": "8b5cf6", "vm_role": False}, "role:core")
role_edge = ensure("dcim/device-roles", {"slug": "edge-router"},
                   {"name": "Edge Router", "slug": "edge-router",
                    "color": "3b82f6", "vm_role": False}, "role:edge")

# ── Devices ───────────────────────────────────────────────────────────
_ROLE_OBJ = {"core-router": role_core, "edge-router": role_edge}
_SITE = {"srl1": "dc1-primary-core", "srl2": "dc2-secondary-core",
         "srl3": "pop3-regional-edge"}
_DESC = {
    "srl1": "Core router and route reflector. Two sides of the core triangle; "
            "reflects to the border router together with srl2.",
    "srl2": "Core router and route reflector, same cluster as srl1. Losing "
            "either reflector does not lose the client's routes.",
    "srl3": "Border router. Holds the eBGP session to AS64500 and is an "
            "RR client of both core routers.",
}
DEVICES = [
    (name, _SITE[name], _ROLE_OBJ[d["role"]], 10 + i * 2,
     f"SIM-{name.upper()}-000{i + 1}", f"AIGOGO-000{i + 1}", _DESC[name])
    for i, (name, d) in enumerate(sorted(PLAN["devices"].items()))
]
devices = {}
for name, site_slug, role, pos, serial, asset, desc in DEVICES:
    devices[name] = ensure("dcim/devices", {"name": name},
                           {"name": name, "device_type": ident(dtype),
                            "role": ident(role), "site": ident(sites[site_slug]),
                            "rack": ident(racks[site_slug]), "position": pos,
                            "face": "front", "status": "active",
                            "platform": ident(platform), "tenant": ident(tenant),
                            "serial": serial, "asset_tag": asset,
                            "description": desc,
                            "tags": [{"slug": "salt-managed"}, {"slug": "core-network"}]},
                           f"device:{name}")
    # keep existing devices in step with the richer model
    if devices[name]:
        api("PATCH", f"dcim/devices/{devices[name]['id']}",
            {"role": ident(role), "site": ident(sites[site_slug]),
             "rack": ident(racks[site_slug]), "position": pos, "face": "front",
             "platform": ident(platform), "tenant": ident(tenant),
             "serial": serial, "asset_tag": asset, "description": desc,
             "tags": [{"slug": "salt-managed"}, {"slug": "core-network"}]})

# ── Contact assignments ───────────────────────────────────────────────
for name, dev in devices.items():
    if not dev:
        continue
    ensure("tenancy/contact-assignments",
           {"object_id": dev["id"], "contact_id": ident(contact)},
           {"object_type": "dcim.device", "object_id": dev["id"],
            "contact": ident(contact), "role": ident(crole_arch),
            "priority": "primary"},
           f"contact-assignment:{name}")

# ── IPAM ──────────────────────────────────────────────────────────────
rir = ensure("ipam/rirs", {"slug": "rfc1918"},
             {"name": "RFC1918", "slug": "rfc1918", "is_private": True}, "rir")
ensure("ipam/aggregates", {"prefix": "10.0.0.0/8"},
       {"prefix": "10.0.0.0/8", "rir": ident(rir),
        "description": "Private space used by the core"}, "aggregate")
# Documentation space (RFC 5737) for what we announce and for the transit
# interconnect, so nothing in this lab can collide with real addressing.
rir_doc = ensure("ipam/rirs", {"slug": "rfc5737"},
                 {"name": "RFC5737 documentation", "slug": "rfc5737",
                  "is_private": False}, "rir:doc")
for agg, note in [("203.0.113.0/24", "Customer aggregate announced to transit"),
                  ("198.51.100.0/24", "Transit interconnect space")]:
    ensure("ipam/aggregates", {"prefix": agg},
           {"prefix": agg, "rir": ident(rir_doc), "description": note},
           f"aggregate:{agg}")

PREFIXES = [tuple(row) for row in PLAN["prefixes"]] + [
    ("172.30.30.0/24", "Out-of-band management", "active"),
]
for pfx, desc, status in PREFIXES:
    ensure("ipam/prefixes", {"prefix": pfx},
           {"prefix": pfx, "status": status, "tenant": ident(tenant),
            "description": desc}, f"prefix:{pfx}")

# ── Interfaces + addresses ────────────────────────────────────────────
# Only interfaces that genuinely exist on the device — a description in
# NetBox for an interface the router doesn't have would fail the config push.
IFACES = {name: [tuple(row) for row in d["interfaces"]]
          for name, d in PLAN["devices"].items()}
iface_ids = {}
for dname, rows in IFACES.items():
    dev = devices.get(dname)
    if not dev:
        continue
    for iname, itype, idesc, addr in rows:
        iface = ensure("dcim/interfaces",
                       {"device_id": dev["id"], "name": iname},
                       {"device": dev["id"], "name": iname, "type": itype,
                        "description": idesc, "enabled": True,
                        "mtu": 9232 if iname.startswith("ethernet") else None,
                        "mgmt_only": iname == "mgmt0"},
                       f"iface:{dname}:{iname}")
        if iface:
            api("PATCH", f"dcim/interfaces/{iface['id']}",
                {"type": itype, "description": idesc,
                 "mtu": 9232 if iname.startswith("ethernet") else None,
                 "mgmt_only": iname == "mgmt0"})
            iface_ids[(dname, iname)] = iface["id"]
            if addr:
                ip = ensure("ipam/ip-addresses", {"address": addr},
                            {"address": addr, "status": "active",
                             "tenant": ident(tenant),
                             "assigned_object_type": "dcim.interface",
                             "assigned_object_id": iface["id"],
                             "description": f"{dname} {iname}"},
                            f"ip:{addr}")
                if ip and iname == "system0":
                    api("PATCH", f"dcim/devices/{dev['id']}",
                        {"primary_ip4": ip["id"]})

# ── Cables between the P2P links ──────────────────────────────────────
CABLES = [((a[0], a[1]), (b[0], b[1])) for a, b in PLAN["cables"]]
for (da, ia), (db, ib) in CABLES:
    aid, bid = iface_ids.get((da, ia)), iface_ids.get((db, ib))
    if not aid or not bid:
        continue
    existing = api("GET", "dcim/cables", params={"termination_a_id": aid})
    if existing and existing.get("results"):
        reused.append(f"cable:{da}-{db}")
        continue
    obj = api("POST", "dcim/cables",
              {"a_terminations": [{"object_type": "dcim.interface", "object_id": aid}],
               "b_terminations": [{"object_type": "dcim.interface", "object_id": bid}],
               "status": "connected", "type": "smf-os2", "tenant": ident(tenant),
               "label": f"{da}:{ia} <-> {db}:{ib}"})
    if obj:
        created.append(f"cable:{da}-{db}")

# ── Circuits — what makes it read as an ISP ───────────────────────────
provider = ensure("circuits/providers", {"slug": "upstream-transit"},
                  {"name": "Upstream Transit Provider", "slug": "upstream-transit",
                   "description": "IP transit supplier"}, "provider")
ctype = ensure("circuits/circuit-types", {"slug": "ip-transit"},
               {"name": "IP Transit", "slug": "ip-transit"}, "circuit-type")
circuit = ensure("circuits/circuits", {"cid": "TRANSIT-10G-001"},
                 {"cid": "TRANSIT-10G-001", "provider": ident(provider),
                  "type": ident(ctype), "status": "active",
                  "tenant": ident(tenant),
                  "description": "10G IP transit landing at DC1",
                  "commit_rate": 10000000}, "circuit")
if circuit:
    ensure("circuits/circuit-terminations",
           {"circuit_id": circuit["id"], "term_side": "A"},
           {"circuit": circuit["id"], "term_side": "A",
            "termination_type": "dcim.site",
            "termination_id": ident(sites["dc1-primary-core"]),
            "port_speed": 10000000}, "circuit-termination")

# ── BGP intent, on the device ─────────────────────────────────────────
#
# This is what bgp_policy renders from, and what config_drift_policy and
# route_leak compare the device against. It is NetBox data rather than a
# pillar file on purpose: the point of the border-router story is that the
# routing policy has the same source of truth as everything else, and is
# edited where a human would edit it.
#
# It was missing from this script entirely. The context existed only in
# whichever NetBox database had been poked by hand, so `docker compose down
# -v` deleted it and a fresh clone never had it. All three consumers then
# reported "no bgp config context in NetBox -- not a border router, nothing
# to do" and did nothing, with nothing failing.
#
# It goes in the device's local_context_data, not in a config context
# object. A config context was tried first and is wrong here: NetBox
# assigns them by region, site, role, platform, tenant or tag -- there is
# no per-device assignment -- so binding "the prefixes srl3 announces" to
# the edge-router ROLE handed the same eBGP intent to srl1 and srl2 as
# well, and they are core routers with no transit session at all. Verified:
# all three devices reported a bgp context. local_context_data merges into
# config_context for exactly one device, which is what this data is.
for name, spec in PLAN["devices"].items():
    bgp = spec.get("bgp")
    if not bgp or name not in devices:
        continue
    api("PATCH", f"dcim/devices/{ident(devices[name])}",
        {"local_context_data": {"bgp": bgp}})
    print(f"  bgp intent: {name} (announced, accepted, filtered)")

# ── Report ────────────────────────────────────────────────────────────
print(f"created {len(created)}, updated {len(updated)}, "
      f"reused {len(reused)}, failed {len(failed)}")
for line in updated:
    print(f"  converged: {line}")
for f in failed:
    print("  FAILED:", f)
sys.exit(1 if failed else 0)
