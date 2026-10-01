#!/usr/bin/env sh
# The blast-radius gate, as a number the room can watch move.
#
#   ./scripts/show-gate.sh
#
# This is the pane that explains the refusal. One shut interface raises two
# faults -- the device that was shut and the far end reporting its link
# down -- and the second one gets refused, which is the behaviour worth
# defending in front of operators. Without this pane the refusal in the
# audit trail looks like a bug; with it, the audience can see the counter
# that caused it before it trips.
#
# The limits come from pillar, not from here. Editing them live and
# watching the gate change its mind is a better demo than any slide about
# guardrails.
set -eu
cd "$(dirname "$0")/.."

STATE=${1:-restore_interface}

M=$(docker exec salt-master salt srl1 pillar.get maintenance --out=json --static 2>/dev/null \
    | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['srl1']))" 2>/dev/null || echo '{}')

G=$(docker exec salt-master salt 'srl*' audit.change_allowed "state=$STATE" \
      --out=json --static 2>/dev/null || echo '{}')

printf '%s\n%s\n' "$M" "$G" | python3 -c "
import json, sys

lines = sys.stdin.read().splitlines()
m = json.loads(lines[0] or '{}')
g = json.loads('\n'.join(lines[1:]) or '{}')

print('── 1  THE BLAST-RADIUS GATE ──')
print()
if m.get('enabled'):
    print('  MAINTENANCE FREEZE IS ON — nothing will be changed')
    print(f\"  reason: {m.get('reason') or '(none given)'}\")
    print()

per_dev = m.get('max_changes_per_hour', '?')
fleet   = m.get('max_devices_per_window', '?')
window  = m.get('fleet_window_minutes', '?')
settle  = m.get('bgp_settle_seconds', '?')

print(f'  limits:  {per_dev} changes/hour per device'
      f'     {fleet} devices per {window} min')
print(f'           {settle}s BGP settle between changes')
print()
print(f\"  {'device':7} {'changes/h':>10} {'fleet':>6}   next change\")
print('  ' + '-' * 52)
for d in sorted(g):
    v = g[d] if isinstance(g[d], dict) else {}
    ok = v.get('allowed')
    mark = '\033[32mALLOWED\033[0m' if ok else '\033[31mREFUSED\033[0m'
    why = '' if ok else '  ' + (v.get('reason') or '')[:60]
    print(f\"  {d:7} {str(v.get('recent','?')):>10} \"
          f\"{str(v.get('fleet_changed','?')):>6}   {mark}{why}\")
print()
print('  A device at its ceiling is not a device that needs another')
print('  push. It is a device that needs a human.')
"
