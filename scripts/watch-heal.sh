#!/usr/bin/env sh
# The heal, as a story you can read out loud.
#
#   ./scripts/watch-heal.sh
#
# evidence.sh prints rows, which is the right shape for reading afterwards
# and the wrong one for standing in front of a room. Watching a pane fill
# with timestamps, you cannot say what stage the system is at, how long it
# has been there, or whether it is working or stuck.
#
# This groups the audit trail by trace and renders each one as its stages,
# so the pane answers "what is happening right now" without anyone having
# to interpret it:
#
#   srl1  ethernet-1/1 on srl1 is administratively down
#     [x] detected   12:55:30  salt-beacon:srl1
#     [x] decided    12:56:10  n8n/llama3.1 — "Ethernet port is administratively shut"
#     [ ] applying...                                        waiting 6s
#
# A fault that is refused shows the refusal in place of the remaining
# stages, because a refusal IS the outcome, not a failure to reach one.
set -eu
cd "$(dirname "$0")/.."
. ./.env
MINUTES=${1:-10}
# How tall the pane is. Without this the renderer prints three traces
# whatever the space, and in a 2x2 grid three traces do not fit -- so the
# NEWEST one, printed first, is the one that scrolls off the top. The
# single most important thing on the screen was the thing being cut.
ROWS=$(tput lines 2>/dev/null || echo 24)

while :; do
  docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
    -X POST "http://localhost:9200/napalm-audit/_search?size=200" \
    -H 'Content-Type: application/json' \
    -d "{\"sort\":[{\"@timestamp\":\"asc\"}],\"query\":{\"range\":{\"@timestamp\":{\"gte\":\"now-${MINUTES}m\"}}}}" \
  | python3 -c "
import json, sys, time
from datetime import datetime, timezone

try:
    hits = json.load(sys.stdin)['hits']['hits']
except Exception:
    print('  (audit store not answering)'); raise SystemExit

now = datetime.now(timezone.utc)
def when(s): return datetime.fromisoformat(s.replace('Z','+00:00'))

traces = {}
for h in hits:
    s = h['_source']
    t = s.get('trace_id') or ''
    if not t or s.get('action','').startswith('device.'):
        continue
    traces.setdefault(t, []).append(s)

print('\033[1m── SELF-HEAL, LIVE ──\033[0m   ' + now.strftime('%H:%M:%SZ'))
print()

if not traces:
    print('  no fault in the last ${MINUTES} minutes. The network is quiet.')
    raise SystemExit

# Render each trace into a buffer, then print only the ones that fit.
# A trace is all-or-nothing: half a trace is worse than no trace, because
# it looks like a stage that never happened.
ROWS = int('${ROWS}' or 24)
blocks = []

for tid in list(traces)[-4:][::-1]:
    buf = []
    emit = buf.append
    rows = traces[tid]
    by = {}
    for r in rows:
        by.setdefault(r.get('action'), r)
    first = rows[0]
    age = (now - when(first['@timestamp'])).total_seconds()

    dev = first.get('device','?')
    # The title is the FAULT, never the model's answer to it. When a trace
    # has no fault.detected inside the window -- the detection scrolled out
    # of it, or the decision arrived on a trace of its own -- this used to
    # fall back to rows[0], whose reason on a refused fault is the model's
    # decline text. The pane then read
    #
    #   srl2  No template actually addresses a physical issue...
    #     [x] detected          n8n/llama3.1
    #
    # which states the refusal as the fault, credits the model with the
    # detection, and prints no time for it. Three false claims in two
    # lines, on the one pane the demo is narrated from.
    det = by.get('fault.detected')
    if det:
        why = det.get('reason','') or det.get('fault','') or ''
    else:
        why = (first.get('fault','') or 'fault').replace('_',' ')
        why += '  (detected before this window)'
    emit(f\"  \033[1m{dev}\033[0m  {why[:74]}\")

    def line(ok, label, rec, extra=''):
        mark = '\033[32m[x]\033[0m' if ok else '\033[2m[ ]\033[0m'
        ts   = when(rec['@timestamp']).strftime('%H:%M:%S') if rec else '        '
        emit(f'    {mark} {label:11} {ts}  {extra[:58]}')

    line(bool(det), 'detected', det, first.get('actor','') if det else '')

    blocked  = by.get('change.blocked') or by.get('decision.blocked')
    declined = by.get('decision.declined')
    decided  = by.get('decision.made')
    applied  = by.get('change.applied')
    verified = by.get('change.verified')
    unver    = by.get('change.unverified') or by.get('change.failed')
    resolved = by.get('fault.resolved')

    if declined:
        emit(f\"    \033[33m[-] DECLINED\033[0m    {when(declined['@timestamp']).strftime('%H:%M:%S')}  \"
              f\"{(declined.get('reason') or '')[:58]}\")
        emit('        \033[2mnothing to push. This becomes a ticket, not a change.\033[0m')
    elif blocked and not decided:
        emit(f\"    \033[33m[!] BLOCKED\033[0m     {when(blocked['@timestamp']).strftime('%H:%M:%S')}  \"
              f\"{(blocked.get('reason') or '')[:58]}\")
    else:
        # Two paths reach a change and only one of them asks the model.
        # The reactor's drift loop compares the device against NetBox and
        # applies the matching state directly -- there is no decision to
        # make, which is the point: drift has exactly one right answer.
        # Rendering that path as 'asking the model...' put a pending
        # spinner on a trace that finished ten minutes ago and credited a
        # model that was never consulted.
        reactor = bool(applied) and 'reactor' in str(applied.get('actor',''))
        if reactor and not decided:
            emit('    \033[32m[x]\033[0m decided     '
                  + when(applied['@timestamp']).strftime('%H:%M:%S')
                  + '  salt-reactor — drift has one right answer, no model asked')
        else:
            line(bool(decided), 'decided', decided,
                 (decided.get('actor','') + ' — ' + (decided.get('reason') or '')) if decided else 'asking the model...')
        if blocked and not applied:
            # The model said yes and the gate said no. This used to render
            # as 'applied ... waiting...', which describes a push that is
            # about to happen -- the opposite of what occurred, on the pane
            # the demo is narrated from. It is also the best thirty seconds
            # in the whole system and deserves to be legible.
            emit('    \033[33m[!] BLOCKED\033[0m     '
                  + when(blocked['@timestamp']).strftime('%H:%M:%S')
                  + '  ' + (blocked.get('reason') or '')[:58])
            emit('        \033[2mthe model decided; the gate refused anyway.\033[0m')
        else:
            line(bool(applied), 'applied', applied, 'revert timer armed' if applied else 'waiting...')
        if blocked and not applied:
            pass
        elif unver and not verified:
            emit(f\"    \033[31m[!] NOT VERIFIED\033[0m {when(unver['@timestamp']).strftime('%H:%M:%S')}  \"
                  f\"the device will revert it\")
        else:
            if verified:
                line(True, 'verified', verified,
                     verified.get('reason') or 'the OUTCOME, not the config')
            elif resolved:
                # Resolved with no outcome check: the state carried no
                # verify clause. golden_config is the honest example:
                # IS-IS being configured has no cheap post-condition worth
                # asserting, so the state does not claim one. Saying that
                # is better than a spinner that never stops.
                emit('    \033[2m[-] verified     '
                      + '         this state has no outcome check\033[0m')
            else:
                line(False, 'verified', None, 'checking the device...')

    line(bool(resolved), 'resolved', resolved, '' if resolved else '')

    state = 'done' if resolved else ('refused' if (declined or blocked) else 'in progress')
    emit(f'    \033[2mt+{age:.0f}s   {state}\033[0m')
    emit('')
    blocks.append(buf)

# Two rows for the header, one for the note, one of slack for the prompt.
budget = ROWS - 4
shown = 0
for b in blocks:
    if len(b) > budget:
        break
    print('\n'.join(b))
    budget -= len(b)
    shown += 1

hidden = len(blocks) - shown
if hidden:
    print(f'  \033[2m{hidden} older trace(s) hidden -- pane is {ROWS} rows. '
          f'Full history:  ./scripts/evidence.sh\033[0m')
if shown == 0 and blocks:
    # Nothing fits at all. Say so rather than showing an empty pane, which
    # reads as a quiet network.
    print('  \033[33mpane too short to render a trace. Make the font smaller,\033[0m')
    print('  \033[33mor run ./scripts/watch-heal.sh in a full-height window.\033[0m')
"
  sleep 3
  # not `clear`: it needs TERM, which a pane started by a script may
  # not have. The escape does the same thing everywhere.
  printf '\033[H\033[2J'
done
