#!/usr/bin/env sh
# Push detection against poll detection, on the same faults and one clock.
#
#   ./scripts/compare-paths.sh            the last 48 hours
#   ./scripts/compare-paths.sh 6          the last 6 hours
#
# Both paths write to napalm-audit. The poll path -- Salt beacons -- writes
# `fault.detected` and is the only one allowed to remediate. The push path --
# napalm-logs over syslog -- writes `fault.observed` and does nothing else.
# This reads both and answers three questions:
#
#   1. When both saw a fault, which was first and by how much?
#   2. Did push see anything poll missed?
#   3. Did poll see anything push could not see at all?
#
# The third is the one that decides whether detection can move to push. A
# faster detector that is blind to half the fault classes is not an upgrade,
# and the only honest way to find that out is to run both and count.
#
# Faults are matched on device and time, NOT on name, because the names
# deliberately differ. One shut interface is `interface_admin_down` on the
# device and `interface_link_down` on the far end to the poll path, which
# fixes the first and declines the second; to syslog both ends report
# oper_status DOWN identically, so the push path calls both `interface_down`.
# Crediting push with the distinction it cannot make would be the easiest way
# to make this comparison lie.
set -eu
cd "$(dirname "$0")/.."
. ./.env

HOURS=${1:-48}
WINDOW=${WINDOW:-120}   # seconds either side that counts as the same fault

docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "http://localhost:9200/napalm-audit/_search?size=10000&track_total_hits=true" \
  -H 'Content-Type: application/json' \
  -d "{\"sort\":[{\"@timestamp\":\"desc\"}],
       \"query\":{\"bool\":{\"filter\":[
         {\"range\":{\"@timestamp\":{\"gte\":\"now-${HOURS}h\"}}},
         {\"terms\":{\"action\":[\"fault.detected\",\"fault.observed\"]}}]}}}" \
  | HOURS="$HOURS" WINDOW="$WINDOW" python3 -c "
import json, os, sys
from datetime import datetime

hours = os.environ['HOURS']
window = float(os.environ['WINDOW'])

raw = sys.stdin.read()
try:
    body = json.loads(raw)
except ValueError:
    print('the audit store did not answer with JSON. Nothing below is a')
    print('measurement -- it is a failed read:')
    print('  ' + (raw[:200].strip() or '(empty response)'))
    sys.exit(2)

# An error response carries no 'hits' key at all, so reading through it with
# .get() turns a rejected query into a report of nothing happening -- the one
# wrong answer this script must never give.
#
# No bare double quotes anywhere below this point: the whole renderer lives
# inside python3 -c \"...\" and an unescaped quote ends the shell string, so
# python silently receives a truncated program and exits 0 with no output.
if 'error' in body or 'hits' not in body:
    err = body.get('error')
    reason = err.get('reason') if isinstance(err, dict) else err
    status = body.get('status')
    print('the audit store REJECTED the query, so there is nothing to')
    print('compare. This is not an empty result:')
    print('  status ' + str(status) + ': ' + str(reason))
    sys.exit(2)

total = (body['hits'].get('total') or {}).get('value')
hits = body['hits']['hits']
# Fetched newest-first so a capped window keeps the recent end; put them back
# in order for the comparison.
hits.reverse()
if total is not None and total > len(hits):
    print(f'NOTE: {total} records in the window, {len(hits)} read. Everything')
    print(f'      below covers only the most recent {len(hits)}. Narrow the')
    print('      window with a smaller HOURS to see the rest.')
    print()

if not hits:
    print(f'nothing detected by either path in the last {hours}h.')
    print('  an empty comparison is not evidence that both paths agree --')
    print('  it is evidence that nothing happened, or that nothing recorded.')
    sys.exit(1)


def when(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))


poll, push = [], []
for h in hits:
    s = h['_source']
    row = (when(s['@timestamp']), s.get('device', '?'), s.get('fault', '?'), s)
    if s.get('action') == 'fault.detected':
        poll.append(row)
    elif s.get('outcome') == 'detected':
        push.append(row)

print(f'=== push vs poll, last {hours}h '
      f'(same fault = same device within {window:.0f}s) ===')
print()
# Deliberately not presented as a ratio. The poll path writes ONE
# fault.detected per fault lifecycle (audit.track reuses the trace id while a
# fault stays faulty); the push path writes one row per syslog message. So the
# raw counts measure transition-dedup against message-rate, and comparing them
# directly flatters push by whatever the message rate happens to be.
pd = len({(d, f) for _, d, f, _ in poll})
sd = len({(d, f) for _, d, f, _ in push})
print(f'  poll path (beacons)      {len(poll):5} records   {pd:3} distinct device+fault')
print(f'  push path (napalm-logs)  {len(push):5} records   {sd:3} distinct device+fault')
print()
print('  The record counts are NOT comparable: the poll path writes one per')
print('  fault lifecycle, the push path one per syslog message. Read the')
print('  distinct column, and the three lists below.')
print()

def family(fault):
    '''The subsystem a fault name belongs to.

    Matching on time alone paired a shut interface on one router with an
    IS-IS adjacency on the same router two seconds away, and reported the
    push path as having detected the interface fault. Nearest-in-time is the
    right tie-breaker and the wrong first criterion: one event on a link
    produces interface, IS-IS, BFD and LLDP messages within milliseconds, so
    something has to say which of them answers the poll path's fault.

    The subsystem prefix does it, and it does it without a table mapping
    every poll fault to every push fault -- which would be another place for
    the two paths to be silently taught to agree.
    '''
    return fault.split('_', 1)[0]


used = set()
matched = []
for pt, pdev, pfault, _ in poll:
    best, best_key = None, None
    for i, (st, sdev, sfault, _) in enumerate(push):
        if i in used or sdev != pdev:
            continue
        gap = (pt - st).total_seconds()
        if abs(gap) > window:
            continue
        # Same subsystem first, closest in time second.
        key = (0 if family(sfault) == family(pfault) else 1, abs(gap))
        if best_key is None or key < best_key:
            best, best_key, best_gap = i, key, gap
    if best is not None:
        used.add(best)
        matched.append((pt, pdev, pfault, push[best][2], best_gap))

if matched:
    print('BOTH SAW IT  (lead > 0 means push was first)')
    print(f\"  {'poll time':15} {'dev':5} {'poll fault':22} {'push fault':20} {'lead':>8}\")
    print('  ' + '-' * 76)
    for pt, dev, pf, sf, gap in matched:
        print(f'  {pt.strftime(\"%m-%d %H:%M:%S\"):15} {dev:5} {pf:22} {sf:20} '
              f'{gap:+7.2f}s')
    leads = sorted(g for *_, g in matched)
    n = len(leads)
    # Mean of the two middle values for an even count. Taking the upper one
    # made the median equal the best case at n=2, which reads as a result.
    mid = leads[n // 2] if n % 2 else (leads[n // 2 - 1] + leads[n // 2]) / 2
    print()
    print(f'  median lead {mid:+.2f}s     best {leads[-1]:+.2f}s     '
          f'worst {leads[0]:+.2f}s')
    ahead = sum(1 for g in leads if g > 0)
    print(f'  push was first on {ahead} of {len(leads)}')
    print()

only_push = [r for i, r in enumerate(push) if i not in used]
if only_push:
    print('PUSH ONLY  — the poll path never raised these')
    for st, dev, fault, s in only_push:
        print(f'  {st.strftime(\"%m-%d %H:%M:%S\")} {dev:5} {fault:22} '
              f\"{s.get('reason','')}\")
    print()
    print('  Each of these is either a fault the beacons do not watch, or one')
    print('  they watch and missed. The difference matters and only reading')
    print('  them decides it.')
    print()

# Keyed on the fault as well as the time and device: two poll faults sharing a
# device and a timestamp would otherwise both be treated as matched when only
# one was, hiding a genuinely missed fault in the one list that must not hide
# anything.
matched_poll = {(pt, dev, pf) for pt, dev, pf, _, _ in matched}
only_poll = [(pt, dev, f) for pt, dev, f, _ in poll
             if (pt, dev, f) not in matched_poll]
if only_poll:
    by_fault = {}
    for _, _, f in only_poll:
        by_fault[f] = by_fault.get(f, 0) + 1
    print('POLL ONLY  — no syslog message carried these')
    for f, n in sorted(by_fault.items(), key=lambda x: -x[1]):
        print(f'  {n:4}  {f}')
    print()
    print('  This is the list that decides whether detection can move to')
    print('  push. A fault class that appears here is one the device does not')
    print('  log, so no profile and no daemon can ever catch it -- the config')
    print('  is valid, the session stays up, and nothing is emitted.')
    print()

print('Nothing above changed a router. The push path records and does not act.')
"
