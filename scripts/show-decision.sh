#!/usr/bin/env sh
# What the model was asked, and what it answered — from the audit trail.
#
# The n8n UI shows this too, and shows it well, but switching windows in
# the middle of a take costs fifteen seconds of navigation and a login
# screen if the session has expired. Everything the UI would show about
# the decision is already in Elasticsearch, because the workflow writes
# it there before it acts: the fault as n8n received it, the model and
# the execution it ran under, and the model's reply exactly as it came
# back, before any parsing.
#
#   ./scripts/show-decision.sh          the most recent decision
#   ./scripts/show-decision.sh srl3     the most recent one for a device
set -u
cd "$(dirname "$0")/.."
. ./.env
DEV=${1:-}
B='\033[1m'; D='\033[2m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'

FILTER='{"terms":{"action":["decision.made","decision.declined"]}}'
[ -n "$DEV" ] && FILTER="$FILTER,{\"term\":{\"device\":\"$DEV\"}}"

# Two records, not one. The decision carries the model's reply; the
# fault.detected record on the same trace carries what the model was
# actually shown. Printing only the decision put the model's own
# one-word reason under the heading IN, which is the opposite of the
# point -- the whole question is whether the text it was given led
# anywhere sensible.
docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=40" \
  -H 'Content-Type: application/json' \
  -d "{\"sort\":[{\"@timestamp\":\"desc\"}],\"query\":{\"bool\":{\"must\":[$FILTER]}}}" \
| ELASTIC_PASSWORD="$ELASTIC_PASSWORD" python3 -c "
import json, sys
B='\033[1m'; D='\033[2m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
try:
    h = json.load(sys.stdin)['hits']['hits']
except Exception:
    print('  (audit store not answering)'); raise SystemExit
if not h:
    print('  no decision yet'); raise SystemExit
s = h[0]['_source']; d = s.get('detail') or {}
# the fault as it was handed to the model, from the same trace
import subprocess, os
tid = s.get('trace_id','')
shown = ''
if tid:
    q = json.dumps({'size':1,'sort':[{'@timestamp':'asc'}],
                    'query':{'bool':{'must':[{'term':{'trace_id':tid}},
                                             {'term':{'action':'fault.detected'}}]}}})
    try:
        out = subprocess.run(['docker','exec','elasticsearch','curl','-s','-u',
              'elastic:' + os.environ['ELASTIC_PASSWORD'],'-X','POST',
              'http://localhost:9200/napalm-audit/_search','-H',
              'Content-Type: application/json','-d',q],
              capture_output=True, text=True, timeout=15).stdout
        hits = json.loads(out)['hits']['hits']
        if hits: shown = hits[0]['_source'].get('reason','')
    except Exception:
        pass
print(f'{B}── 2  WHAT THE MODEL WAS ASKED, AND WHAT IT SAID ──{N}')
print(f'{D}   from the audit trail, written before anything was applied{N}')
print()
print(f'{D}   IN   the fault, as n8n received it{N}')
print(f'        {B}{s.get(\"device\",\"?\")}{N}   {C}{s.get(\"fault\",\"?\")}{N}')
r = shown or (s.get('reason') or '')
import textwrap
for line in textwrap.wrap(r, 62)[:4]:
    print(f'        {D}{line}{N}')
print()
print(f'{D}   MODEL{N}  {d.get(\"model\",\"?\")}   {D}execution {d.get(\"execution_id\",\"?\")}{N}')
print()
print(f'{D}   OUT  the reply, exactly as it came back{N}')
raw = str(d.get('llm_raw','')).strip() or '(not recorded)'
for line in textwrap.wrap(raw, 62)[:5]:
    print(f'        {Y}{line}{N}')
print()
ok = s.get('action') == 'decision.made'
col = G if ok else Y
print(f'   {col}{B}→ {\"chose\" if ok else \"declined\"}: {s.get(\"state\") or \"none\"}{N}')
print(f'   {D}trace {s.get(\"trace_id\",\"\")}{N}')
"
