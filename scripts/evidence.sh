#!/usr/bin/env sh
# Print the complete audit timeline for one fault, with elapsed times.
#
#   ./scripts/evidence.sh                      the last 15 minutes, everything
#   ./scripts/evidence.sh srl3                 the last 15 minutes, one device
#   ./scripts/evidence.sh srl3 60              the last 60 minutes
#   ./scripts/evidence.sh trace:<trace-id>     one trace, start to finish
#
# This exists because a claim on a slide has to come from somewhere, and
# "I remember it took about forty seconds" is not somewhere. Every number
# that goes in front of an audience should be copied out of this output.
#
# It reads the audit trail only. It never looks at the device, because the
# device cannot tell you who changed it -- which is the whole reason the
# audit trail exists.
set -eu
cd "$(dirname "$0")/.."
. ./.env

ARG=${1:-}
MINUTES=${2:-15}

case "$ARG" in
  trace:*)  QUERY="{\"term\":{\"trace_id\":\"${ARG#trace:}\"}}" ;;
  "")       QUERY="{\"range\":{\"@timestamp\":{\"gte\":\"now-${MINUTES}m\"}}}" ;;
  *)        QUERY="{\"bool\":{\"filter\":[{\"term\":{\"device\":\"$ARG\"}},
                    {\"range\":{\"@timestamp\":{\"gte\":\"now-${MINUTES}m\"}}}]}}" ;;
esac

docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=100" \
  -H 'Content-Type: application/json' \
  -d "{\"sort\":[{\"@timestamp\":\"asc\"}],\"query\":$QUERY}" \
  | python3 -c "
import json, os, sys
from datetime import datetime

hits = json.load(sys.stdin).get('hits', {}).get('hits', [])
if not hits:
    print('nothing in the audit trail for that query.')
    print('  an empty trail is not proof that nothing happened -- it is')
    print('  proof that nothing was recorded, which is worse.')
    sys.exit(1)

def when(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))

t0 = when(hits[0]['_source']['@timestamp'])
traces = {}
narrow = os.environ.get('NARROW') == '1'
if narrow:
    print(f\"{'time':8} {'+s':>5} {'action':18} {'outcome':9} detail\")
    print('-' * 92)
else:
    print(f\"{'time':8}  {'+s':>6}  {'device':6} {'action':18} {'outcome':9} {'actor':22} detail\")
    print('-' * 150)
for h in hits:
    s = h['_source']
    t = when(s['@timestamp'])
    traces.setdefault(s.get('trace_id', ''), []).append((t, s))
    reason = (s.get('reason') or '').replace('\n', ' ')[:70]
    if narrow:
        print(f\"{s['@timestamp'][11:19]} {(t - t0).total_seconds():5.0f} \"
              f\"{s.get('action',''):18} {s.get('outcome',''):9} {reason[:46]}\")
    else:
        print(f\"{s['@timestamp'][11:19]}  {(t - t0).total_seconds():6.1f}  \"
              f\"{(s.get('device') or '-'):6} {s.get('action',''):18} \"
              f\"{s.get('outcome',''):9} {(s.get('actor') or '-'):22} {reason}\")

print()
for tid, rows in traces.items():
    if not tid or len(rows) < 2:
        continue
    span = (rows[-1][0] - rows[0][0]).total_seconds()
    acts = ' -> '.join(r[1].get('action','') for r in rows)
    print(f'trace {tid}')
    print(f'  {span:.1f}s   {acts}')
"
