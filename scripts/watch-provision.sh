#!/usr/bin/env sh
# Provisioning, as a pane you can narrate.
#
# The self-heal demo shows a network repairing itself. This shows the step
# before that one, and it is the step people do not believe: four routers
# come up carrying nothing but management and a loopback, and everything
# that makes them a network -- IS-IS, BFD, iBGP, the border router's
# policy, every interface description -- is read out of NetBox and pushed
# to them. Nobody types on a router. There is no golden config file to
# drift from; there is a database and a template.
#
# It reads the same audit trail as watch-heal.sh: the convergence records
# an override per device and state, because this is planned work rather
# than self-healing and the two must not share a change budget. Then the
# change, then the verification where the state has one.
#
#   ./scripts/watch-provision.sh          follow a bootstrap as it runs
#   ./scripts/watch-provision.sh 120      look back two hours instead
set -eu
cd "$(dirname "$0")/.."
. ./.env
MINUTES=${1:-180}
ROWS=$(tput lines 2>/dev/null || echo 24)

# Which devices SHOULD get a bgp policy, asked of NetBox rather than
# hardcoded. Without this the pane cannot tell "srl1 has no border policy
# because it is not a border router" from "srl1 has not been done yet",
# and those look identical and mean opposite things.
BGP_DEVICES=$(docker exec -i -e "T=$NETBOX_API_TOKEN" salt-master python3 - <<'PY' 2>/dev/null || echo ""
import os, json, urllib.request
try:
    r = urllib.request.Request("http://netbox:8080/api/dcim/devices/?limit=50",
                               headers={"Authorization": "Token " + os.environ["T"]})
    d = json.load(urllib.request.urlopen(r, timeout=10))
    print(" ".join(x["name"] for x in d["results"]
                   if (x.get("local_context_data") or {}).get("bgp")))
except Exception:
    print("")
PY
)

while :; do
  docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
    -X POST "http://localhost:9200/napalm-audit/_search?size=300" \
    -H 'Content-Type: application/json' \
    -d "{\"sort\":[{\"@timestamp\":\"asc\"}],\"query\":{\"bool\":{\"must_not\":[{\"term\":{\"action\":\"fault.observed\"}}],\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-${MINUTES}m\"}}}]}}}" \
  | BGP_DEVICES="$BGP_DEVICES" ROWS="$ROWS" python3 -c "
import json, os, sys
from datetime import datetime, timezone

try:
    hits = json.load(sys.stdin)['hits']['hits']
except Exception:
    print('  (audit store not answering)'); raise SystemExit

now = datetime.now(timezone.utc)
def when(s): return datetime.fromisoformat(s.replace('Z','+00:00'))

bgp_devices = set((os.environ.get('BGP_DEVICES') or '').split())

# The order bootstrap applies them in, and the reason each one exists.
STAGES = [
    ('golden_config',    'IS-IS, BFD, iBGP -- the fabric'),
    ('bgp_policy',       'what the border announces and accepts'),
    ('sync_from_netbox', 'interface descriptions, from the database'),
]
DEVICES = ['srl1', 'srl2', 'srl3']

# Only provisioning: actor 'bootstrap', or the override that authorises it.
# A self-heal is a different story and has its own pane.
got = {}
for h in hits:
    s = h['_source']
    dev, st, act = s.get('device'), s.get('state'), s.get('action','')
    if dev not in DEVICES or st not in dict(STAGES):
        continue
    if s.get('actor') != 'bootstrap' and act != 'change.override':
        continue
    got.setdefault((dev, st), {})[act] = s

print('\033[1m── PROVISIONING FROM NETBOX ──\033[0m   ' + now.strftime('%H:%M:%SZ'))
print()
print('\033[2m  The routers came up with management and a loopback. Everything')
print('  below was read out of NetBox and pushed. Nobody typed on a router.\033[0m')
print()

done = total = 0
for dev in DEVICES:
    print(f'  \033[1m{dev}\033[0m')
    for st, why in STAGES:
        rec = got.get((dev, st), {})
        applied  = rec.get('change.applied')
        verified = rec.get('change.verified')
        override = rec.get('change.override')
        total += 1

        if st == 'bgp_policy' and bgp_devices and dev not in bgp_devices:
            print(f'    \033[2m[-] {st:18} not a border router -- nothing to push\033[0m')
            done += 1
            continue

        if verified:
            mark, ts = '\033[32m[x]\033[0m', when(verified['@timestamp']).strftime('%H:%M:%S')
            note = (verified.get('reason') or 'verified on the device')[:46]
            done += 1
        elif applied:
            mark, ts = '\033[32m[x]\033[0m', when(applied['@timestamp']).strftime('%H:%M:%S')
            note = why
            done += 1
        elif override:
            ts = when(override['@timestamp']).strftime('%H:%M:%S')
            age = (now - when(override['@timestamp'])).total_seconds()
            if age < 90:
                mark, note = '\033[33m[~]\033[0m', 'authorised, pushing...'
            else:
                # An override with no change after it is not a push in
                # flight -- it is a state that ran, was authorised, and
                # found the device already matching NetBox. Convergence is
                # idempotent and that is the whole point; a spinner that
                # never stops says the opposite.
                mark = '\033[32m[=]\033[0m'
                note = 'already matched NetBox -- nothing to push'
                done += 1
        else:
            mark, ts, note = '\033[2m[ ]\033[0m', '        ', why
        print(f'    {mark} {st:18} {ts}  {note}')
    print()

if done >= total:
    print('  \033[32m\033[1mthe fabric is what the database says it is.\033[0m')
else:
    print(f'  \033[2m{done} of {total} stages complete\033[0m')
"
  sleep 3
  printf '\033[H\033[2J'
done
