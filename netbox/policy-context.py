"""The BGP service layer, as NetBox intent.

Day-0 and the golden config give the border router a session to AS64500.
They deliberately do not say what it may announce or accept, because that
is the layer an ISP changes weekly and gets wrong -- a prefix-list edited
at 2am, a filter removed "temporarily", an aggregate that stops being
announced. It belongs in the source of truth, not in a template.

NetBox models this as a config context: structured JSON attached to a
device role, which NetBox renders per device. No plugin needed -- ASNs and
config contexts are both first-class in NetBox 4.

Salt reads the rendered context in states/bgp_policy.sls and converges the
device to it, through audited.config like everything else. That is what
makes "somebody removed the bogon filter" a detectable fault rather than a
post-mortem finding.
"""
import json
import os

import requests

BASE = os.environ.get("NETBOX_URL", "http://netbox:8080").rstrip("/") + "/api"
H = {"Authorization": f"Token {os.environ['NETBOX_API_TOKEN']}",
     "Content-Type": "application/json"}

CONTEXT = {
    "bgp": {
        "asn": 65001,
        # What we put in the routing table so that we have something to
        # announce. A blackhole aggregate is how every ISP originates space
        # it has not fully assigned yet.
        "originate": [
            {"prefix": "203.0.113.0/24",
             "description": "customer aggregate, sites A and B"}
        ],
        "transit": {
            "peer_as": 64500,
            "peer_ip": "198.51.100.0",
            "export": {
                # Announce the aggregate and nothing else. The default-reject
                # at the end of the policy is what stops an accidental
                # transit-provider impression of your network.
                "prefixes": ["203.0.113.0/24"]
            },
            "import": {
                "accept_default": True,
                # Anything longer than a /24 from a transit provider is
                # either a mistake or an attack.
                "max_prefix_length": 24,
                # Never accept our own space back from upstream.
                "reject_own": ["203.0.113.0/24"],
                # The classic filter. Removing it is the fault worth
                # detecting: nothing breaks immediately, and then one day
                # it does.
                "reject_bogons": [
                    "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8",
                    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
                    "224.0.0.0/4", "240.0.0.0/4"
                ],
            },
        },
    }
}


def main():
    role = requests.get(f"{BASE}/dcim/device-roles/?slug=edge-router",
                        headers=H, timeout=20).json()["results"][0]
    lookup = requests.get(f"{BASE}/extras/config-contexts/?name=bgp-border",
                          headers=H, timeout=20).json()
    payload = {
        "name": "bgp-border",
        "weight": 1000,
        "description": "BGP service layer for border routers: what we "
                       "announce, what we accept, and what we filter",
        "is_active": True,
        "roles": [role["id"]],
        "data": CONTEXT,
    }
    if lookup["results"]:
        cid = lookup["results"][0]["id"]
        r = requests.patch(f"{BASE}/extras/config-contexts/{cid}/",
                           headers=H, json=payload, timeout=20)
        print(f"config context bgp-border updated ({r.status_code})")
    else:
        r = requests.post(f"{BASE}/extras/config-contexts/", headers=H,
                          json=payload, timeout=20)
        print(f"config context bgp-border created ({r.status_code})")
    if r.status_code >= 400:
        print(r.text[:400])


if __name__ == "__main__":
    main()
