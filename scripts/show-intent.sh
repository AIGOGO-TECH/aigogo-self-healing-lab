#!/usr/bin/env sh
# The source of truth, as the room needs to see it during provisioning.
#
#   ./scripts/show-intent.sh
#
# The provisioning clip has one claim: nobody typed this configuration on a
# router. This pane is that claim's evidence, and it belongs on screen for
# the whole clip -- opposite the pane showing the devices converging, so
# the two can be read as intent and result.
#
# It reads NetBox over the API, not a file in this repo, because a file in
# this repo would prove nothing: the interesting property is that the
# system and the audience are looking at the same object.
set -eu
cd "$(dirname "$0")/.."
. ./.env

BASE="http://${BIND_ADDR:-127.0.0.1}:8000/api"

fetch() { curl -s -H "Authorization: Token $NETBOX_API_TOKEN" "$BASE/$1"; }

{
  fetch "dcim/devices/?limit=10"
  echo '---8<---'
  fetch "dcim/interfaces/?limit=100"
} | python3 -c "
import json, sys

raw = sys.stdin.read().split('---8<---')
try:
    devs = json.loads(raw[0])['results']
    ifs  = json.loads(raw[1])['results']
except Exception:
    print('── 1  THE SOURCE OF TRUTH ──')
    print()
    print('  NetBox is not answering. Nothing can be provisioned from an')
    print('  unreachable source of truth, which is the correct behaviour.')
    raise SystemExit(0)

print('── 1  THE SOURCE OF TRUTH — NETBOX ──')
print()
print(f\"  {'device':7} {'role':13} {'site':30} {'ifaces':>6}\")
print('  ' + '-' * 60)
for d in sorted(devs, key=lambda x: x.get('name') or ''):
    n = sum(1 for i in ifs if (i.get('device') or {}).get('name') == d.get('name'))
    role = (d.get('role') or {}).get('name') or '-'
    site = (d.get('site') or {}).get('name') or '-'
    print(f\"  {d.get('name',''):7} {role:13} {site[:30]:30} {n:>6}\")

print()
print('  every interface carries its MTU and its description:')
for i in ifs:
    if i['device']['name'] == 'srl3' and i['name'].startswith('ethernet'):
        print(f\"    srl3 {i['name']:14} mtu {i.get('mtu') or '-':<6} \"
              f\"{(i.get('description') or '')[:60]}\")

# A default, not a bare next(): the device list is a paged API read, so srl3
# drops out of it as soon as the lab has more devices than the page size, and
# a StopIteration traceback is a worse answer than a missing section.
bgp = next((((d.get('local_context_data') or {}).get('bgp'))
            for d in devs if d.get('name') == 'srl3'), None)
if bgp:
    t = bgp.get('transit', {})
    orig = ', '.join(p['prefix'] for p in bgp.get('originate', []))
    print()
    print(f\"  srl3 also carries the BGP service layer:\")
    print(f\"    AS{bgp.get('asn')}  ->  transit AS{t.get('peer_as')} at {t.get('peer_ip')}\")
    print(f\"    originate: {orig}\")
    exp = (t.get('export') or {}).get('prefixes') or []
    if exp:
        print(f\"    export:    {', '.join(exp)}\")
        extra = len(bgp.get('originate', [])) - len(exp)
        if extra > 0:
            print(f\"               ^ {extra} prefix(es) are originated and NOT\")
            print(f\"                 exported. That gap is the route leak.\")

print()
print('  srl4 is deliberately absent. It is the provider, not ours,')
print('  and automation may not write to a device it does not own.')
"
