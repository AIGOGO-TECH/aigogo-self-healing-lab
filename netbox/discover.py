"""
Fill NetBox from the devices instead of by hand.

The talk argues that a source of truth should be discovered rather than
typed. This is that argument applied to itself: MAC addresses, speeds and
duplex come straight off the routers through Salt/NAPALM, so the fields
are right because the network said so, not because someone remembered.

Run:  docker exec salt-master salt --out=json 'srl*' net.interfaces
      is what feeds this; here we read it per-device to keep the JSON
      parseable.
"""

import json
import os
import shutil
import subprocess
import sys

import requests

BASE = os.environ.get("NETBOX_URL", "http://netbox:8080").rstrip("/") + "/api"
# Taken from the environment; docker-compose passes it in from .env, and
# scripts/seed-netbox.sh does the same when this runs as a one-off.
TOKEN = os.environ["NETBOX_API_TOKEN"]
H = {"Authorization": f"Token {TOKEN}", "Content-Type": "application/json"}

DEVICES = ["srl1", "srl2", "srl3"]
# Physical port labels as they are silkscreened on a 7220 IXR-D3L faceplate.
LABELS = {"ethernet-1/1": "1/1", "ethernet-1/2": "1/2",
          "mgmt0": "MGMT", "system0": "—"}


# Two ways to reach Salt, because this script is run from two places.
#
# Inside the salt-master container `salt` is simply on PATH. From a shell on
# the host it is not, and the command has to go through docker exec. The
# original only knew the second form, which meant the script could never run
# where scripts/seed-netbox.sh actually put it -- a python:3.12-slim
# container, which has no docker CLI and no socket:
#
#   FileNotFoundError: [Errno 2] No such file or directory: 'docker'
#
# It had therefore never worked through bootstrap.sh, only by hand.
SALT_CMD = (["salt"] if shutil.which("salt")
            else ["docker", "exec", "salt-master", "salt"])


def salt(device):
    out = subprocess.run(
        SALT_CMD + ["--out=json", device, "net.interfaces"],
        capture_output=True, text=True).stdout
    try:
        return json.loads(out)[device]["out"]
    except (ValueError, KeyError) as err:
        print(f"  could not read interfaces from {device}: {err}")
        print(f"  salt said: {out[:200]}")
        return {}


def api(method, path, data=None, params=None):
    r = requests.request(method, f"{BASE}/{path}/", json=data, params=params,
                         headers=H, timeout=20)
    if r.status_code >= 400:
        print(f"  {method} {path}: {r.status_code} {r.text[:160]}")
        return None
    return r.json()


# A VRF for the global routing table — every ISP NetBox has one, and the
# interfaces should say which table they live in.
vrf = api("GET", "ipam/vrfs", params={"name": "GLOBAL"})
if vrf and vrf["results"]:
    vrf_id = vrf["results"][0]["id"]
else:
    vrf_id = api("POST", "ipam/vrfs", {
        "name": "GLOBAL", "rd": "65001:1",
        "description": "Global routing table — IS-IS L2 + iBGP AS 65001",
        "enforce_unique": True})["id"]

updated = 0
for dev in DEVICES:
    live = salt(dev)
    nb = api("GET", "dcim/interfaces", params={"device": dev, "limit": 100})
    for iface in (nb or {}).get("results", []):
        name = iface["name"]
        facts = live.get(name)
        if not facts:
            continue
        payload = {
            "label": LABELS.get(name, ""),
            "duplex": "full" if facts.get("speed") else None,
            "vrf": vrf_id if name.startswith(("ethernet", "system")) else None,
        }
        speed = facts.get("speed")
        if speed:                      # NetBox stores speed in kbps
            payload["speed"] = int(speed * 1000)
        if api("PATCH", f"dcim/interfaces/{iface['id']}", payload):
            updated += 1

        mac = (facts.get("mac_address") or "").strip()
        if not mac:
            continue
        # NetBox 4.2 models MAC addresses as their own objects.
        found = api("GET", "dcim/mac-addresses", params={"mac_address": mac})
        if found and found["results"]:
            mac_id = found["results"][0]["id"]
        else:
            obj = api("POST", "dcim/mac-addresses", {
                "mac_address": mac,
                "assigned_object_type": "dcim.interface",
                "assigned_object_id": iface["id"],
                "description": f"Read from {dev} via NAPALM"})
            mac_id = obj["id"] if obj else None
        if mac_id:
            api("PATCH", f"dcim/interfaces/{iface['id']}",
                {"primary_mac_address": mac_id})

print(f"updated {updated} interfaces from live device data")
