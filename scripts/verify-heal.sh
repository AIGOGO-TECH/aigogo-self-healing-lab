#!/bin/sh
# Confirm a heal by asking WHO did it, not what the device looks like.
#
# Watching admin-state alone cannot tell an automated remediation from an
# engineer in another terminal, so it cannot answer the one question a test
# of the automation is asking.
#
#   ./scripts/verify-heal.sh srl3 ethernet-1/1 <epoch-seconds-of-the-break>
set -eu
cd "$(dirname "$0")/.."
. ./.env
DEV=${1:-srl3}; IFACE=${2:-ethernet-1/1}; SINCE=${3:-$(( $(date -u +%s) - 600 ))}
FROM=$(date -u -r "$SINCE" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$SINCE" +%Y-%m-%dT%H:%M:%SZ)

state=$(docker exec "clab-selfheal-$DEV" sr_cli \
        "info from state /interface $IFACE admin-state" 2>/dev/null \
        | grep -o "enable\|disable" | head -1)
echo "device says: $IFACE is $state"

docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=20" \
  -H 'Content-Type: application/json' \
  -d "{\"sort\":[{\"@timestamp\":\"asc\"}],\"query\":{\"bool\":{\"filter\":[
       {\"term\":{\"device\":\"$DEV\"}},
       {\"terms\":{\"action\":[\"change.applied\",\"change.verified\"]}},
       {\"range\":{\"@timestamp\":{\"gte\":\"$FROM\"}}}]}}}" \
  | python3 -c "
import json, sys
h = json.load(sys.stdin)['hits']['hits']
if not h:
    print('audit trail says: NOBODY. No change.applied since the break.')
    print('  -> if the interface is up, a human did it. That is not a heal.')
    sys.exit(1)
for x in h:
    s = x['_source']
    print(f\"audit trail says: {s['@timestamp'][11:19]}  {s['action']}  \"
          f\"by {s.get('actor')}  ({s.get('state')})  trace={s.get('trace_id')}\")
"
