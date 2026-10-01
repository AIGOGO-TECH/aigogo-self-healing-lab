#!/usr/bin/env sh
# Run one fault class repeatedly and measure every stage of every run.
#
#   ./scripts/soak.sh interface 10        ten interface faults on srl3
#   ./scripts/soak.sh leak 10             ten route leaks
#   ./scripts/soak.sh drift 10            ten config drifts
#   ./scripts/soak.sh all 10              thirty runs, all three classes
#
#   GATE=wide ./scripts/soak.sh all 10    widen the change ceilings first
#
# A demo that worked once is an anecdote. This exists to turn the three fault
# classes on the slides into numbers with an n, because the only claim worth
# making in front of operators is one with a spread attached.
#
# Every run is measured from the audit trail rather than from this script's own
# clock, so what is reported is what the system recorded -- not what the test
# believed while it waited.
#
# Stages, per run:
#   push      napalm-logs saw a syslog message for it     (fault.observed)
#   poll      a Salt beacon raised it                     (fault.detected)
#   decided   the model chose a remediation               (decision.made)
#   applied   the config was pushed                       (change.applied)
#   verified  the outcome check passed                    (change.verified)
#   resolved  the beacon saw the fault gone               (fault.resolved)
#
# A run with `blocked` instead of `applied` is not a failure. The change gate
# refusing is the behaviour the slides claim, and the summary counts it
# separately rather than averaging it away.
#
# GATE=wide edits salt/pillar/maintenance.sls and restores it on exit, because
# at production ceilings (3 changes/hour/device, 2 devices/15min) the fourth
# run of a class is correctly refused -- which is worth proving once, and gets
# in the way of measuring ten heals. The summary always prints which ceilings
# were in force.
set -eu
cd "$(dirname "$0")/.."
. ./.env

CASE=${1:-interface}
RUNS=${2:-10}
GATE=${GATE:-prod}
# Per fault class, because they do not run on the same clock and one number
# for all three measures the slowest one wrong.
#
# An interface heals in about 40s. A route leak takes 290-310s, and the
# difference is not in Salt.
#
# The leak case cannot rotate its target: only the border router has a transit
# policy to relax, so every run raises the same device+fault+interface and
# lands in the same Grafana alert group. Consecutive runs are therefore paced
# by that group's repeat_interval, which is 5 minutes -- so the second and
# later runs of a leak soak wait out the repeat before n8n hears anything.
#
# A single 180s timeout recorded ten successful leak repairs as ten failures:
# the wait loop gave up while change.applied was still ahead of it. The runs
# were fine, the measurement was not, and a test that reports a working system
# as broken is worse than no test at all.
# These are BACKSTOPS, not measurement boundaries. The wait loop exits the
# moment a run reaches a terminal stage, so a generous timeout costs nothing on
# a run that completes -- it is only ever paid on a run that genuinely hangs.
#
# Tuning them downward was a mistake made three times here: 180s, then 300s,
# then 420s, each one chosen from the previous run's observed time and each one
# overtaken by the next. Every one of those recorded a working repair as a
# failure. A timeout that has to be tuned to the thing it is timing is not a
# timeout, it is a second measurement, and it will always be the wrong one.
case "${1:-interface}" in
  leak)  DEFAULT_TIMEOUT=900 ;;
  drift) DEFAULT_TIMEOUT=600 ;;
  all)   DEFAULT_TIMEOUT=900 ;;
  *)     DEFAULT_TIMEOUT=600 ;;
esac
TIMEOUT=${TIMEOUT:-$DEFAULT_TIMEOUT}
OUT=${OUT:-soak-$(date -u +%Y%m%dT%H%M%SZ).tsv}

PILLAR=salt/pillar/maintenance.sls
BACKUP=""
ENVBACKUP=""

# Called explicitly at the end AND from the EXIT trap, so every step has to be
# safe to run twice. It was not, and the tail of a completed run was two `mv:
# No such file` errors and exit 1 on a soak that had restored everything
# correctly -- which is the worst way to end a test: a real failure and a
# cosmetic one are then indistinguishable.
restore_gate() {
  if [ -n "${ENVBACKUP:-}" ] && [ -e "${ENVBACKUP:-/nonexistent}" ]; then
    mv "$ENVBACKUP" .env
    docker compose up -d n8n >/dev/null 2>&1 || true
    ENVBACKUP=""
  fi
  [ -n "${BACKUP:-}" ] && [ -e "${BACKUP:-/nonexistent}" ] || { BACKUP=""; return 0; }
  mv "$BACKUP" "$PILLAR"
  docker exec salt-master salt 'srl*' saltutil.refresh_pillar >/dev/null 2>&1 || true
  BACKUP=""
  echo "  both ceilings restored"
}
on_exit() {
  rc=$?
  restore_gate
  [ "$rc" = 0 ] || echo "soak stopped early (rc=$rc). $OUT has what completed." >&2
  exit $rc
}
trap on_exit EXIT INT TERM

widen_gate() {
  # The stale-backup test comes FIRST, and nothing is assigned before it.
  #
  # BACKUP used to be set on the line above this check, so the refusal path
  # left the EXIT trap holding a backup path that existed -- and restore_gate
  # then moved it over the pillar and announced "both ceilings restored",
  # having restored neither .env nor anything the operator had since edited by
  # hand. A guard that refuses to run and then overwrites a file on the way
  # out is worse than no guard.
  if [ -e "$PILLAR.soak-backup" ] || [ -e .env.soak-backup ]; then
    echo "REFUSING TO START: a previous soak did not restore the change" >&2
    echo "  ceilings. Whatever is in $PILLAR and .env now is NOT what this" >&2
    echo "  repository ships, and nothing measured since is valid." >&2
    echo "  Put them back by hand, then re-run:" >&2
    echo "    mv $PILLAR.soak-backup $PILLAR          # if it exists" >&2
    echo "    mv .env.soak-backup .env                # if it exists" >&2
    echo "    docker exec salt-master salt 'srl*' saltutil.refresh_pillar" >&2
    echo "    docker compose up -d n8n" >&2
    exit 3
  fi
  BACKUP="$PILLAR.soak-backup"
  # One number for both per-device ceilings, so the two halves of the gate
  # cannot disagree during the run -- which is the failure this whole flag
  # exists to avoid reproducing. 20/hour is a plausible busy-window value
  # rather than an absurd one: the point is to get out of the way of ten runs,
  # not to pretend the limit does not exist. Devices-per-window goes to the
  # number of routers, because the runs rotate across all three.
  cp "$PILLAR" "$BACKUP"
  sed -e "s/^  max_changes_per_hour: .*/  max_changes_per_hour: ${WIDE_MAX:-20}/" \
      -e 's/^  max_devices_per_window: .*/  max_devices_per_window: 3/' \
      "$BACKUP" > "$PILLAR"
  docker exec salt-master salt 'srl*' saltutil.refresh_pillar >/dev/null 2>&1

  # There are TWO ceilings and they are enforced by different things. Salt's
  # gate refuses the change; n8n's circuit breaker refuses to ask the model at
  # all. Raising only the pillar moves the first and leaves the second refusing
  # at 3 with a reason that reads exactly like the pillar's -- which is how a
  # ten-run soak came back with 10/10 detected and 1/10 healed and no
  # explanation anywhere in its own output.
  ENVBACKUP=".env.soak-backup"
  cp .env "$ENVBACKUP"
  sed "s/^MAX_CHANGES_PER_HOUR=.*/MAX_CHANGES_PER_HOUR=${WIDE_MAX:-20}/" \
      "$ENVBACKUP" > .env
  docker compose up -d n8n >/dev/null 2>&1
  # Re-imported so the workflow n8n RUNS is the one in this repository.
  #
  # This is a state change the EXIT trap does not undo, and it is the one
  # thing a soak does that is not reversible: import:workflow overwrites
  # whatever is in n8n's database, and the publish loop re-publishes every
  # workflow. Anything changed in the n8n UI and not written back to
  # n8n/*.json is lost. Said here rather than discovered later.
  if ! ./scripts/import-workflows.sh >/dev/null 2>&1; then
    echo "  WARNING: re-importing the workflows failed; n8n is running" >&2
    echo "  whatever was already in its database." >&2
  fi
  # n8n answers its port before it has re-registered the workflow's webhook.
  waited=0
  while [ "$waited" -lt 90 ]; do
    sleep 5
    waited=$((waited + 5))
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -X POST "http://${BIND_ADDR:-127.0.0.1}:5678/webhook/fault" \
      -H 'Content-Type: application/json' -d '{"probe":true}' 2>/dev/null || echo 000)
    case "$CODE" in 200|201|500) break ;; esac
  done
  echo "  both ceilings widened to ${WIDE_MAX:-20}/hour/device, 3 devices/window"
  case "${CODE:-000}" in
    200|201|500) echo "  n8n webhook answering after ${waited}s (HTTP $CODE)" ;;
    *) echo "  n8n webhook is NOT answering (HTTP ${CODE:-timeout}) after ${waited}s." >&2
       echo "  Every fault injected from here would reach nothing and the soak" >&2
       echo "  would report 0/N healed on a working lab. Refusing to measure." >&2
       echo "    docker logs n8n | tail -40" >&2
       exit 4 ;;
  esac
}

# Read one run's stages out of the audit trail, from an ISO start time.
stages() {
  docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
    -X POST "http://localhost:9200/napalm-audit/_search?size=400" \
    -H 'Content-Type: application/json' \
    -d "{\"sort\":[{\"@timestamp\":\"asc\"}],\"query\":{\"range\":{\"@timestamp\":{\"gte\":\"$1\"}}}}" \
  | START="$1" python3 -c "
import json, os, sys
from datetime import datetime

t0 = datetime.fromisoformat(os.environ['START'].replace('Z', '+00:00'))
try:
    hits = json.load(sys.stdin)['hits']['hits']
except Exception:
    print('ERR')
    raise SystemExit(0)

# Every action that ENDS a run has to be in here, or the wait loop has no
# break condition for it and the run burns its whole backstop -- 900s for a
# leak -- then writes a row of dashes indistinguishable from nothing having
# happened. decision.duplicate, change.failed, change.unverified and
# decision.rejected were all missing, and the first of those is routine:
# Grafana's repeat_interval produces it whenever the same alert group fires
# twice, which the leak case cannot avoid.
want = {
    'fault.observed': 'push',
    'fault.detected': 'poll',
    'decision.made': 'decided',
    'decision.declined': 'declined',
    'decision.duplicate': 'ended',
    'decision.rejected': 'ended',
    'decision.blocked': 'breaker',
    'change.blocked': 'blocked',
    'change.applied': 'applied',
    'change.verified': 'verified',
    'change.failed': 'ended',
    'change.unverified': 'ended',
    'fault.resolved': 'resolved',
}
first = {}
for h in hits:
    s = h['_source']
    k = want.get(s.get('action'))
    if not k or k in first:
        continue
    if k == 'push' and s.get('outcome') != 'detected':
        continue
    t = datetime.fromisoformat(s['@timestamp'].replace('Z', '+00:00'))
    first[k] = (t - t0).total_seconds()

print('\t'.join(
    ('%.2f' % first[k]) if k in first else '-'
    for k in ('push', 'poll', 'decided', 'declined', 'breaker', 'blocked',
              'applied', 'verified', 'ended', 'resolved')))
"
}

# Rotate the target between runs.
#
# Grafana groups notifications by device + fault + interface, with
# group_interval 30s and repeat_interval 5m. That is correct for an operator --
# one broken interface must not become one alert per evaluation -- and it means
# the same fault injected twice on the same interface inside the window is
# collapsed into one notification. The second run then measures detection
# perfectly and never reaches the model at all.
#
# Rotating the device makes each run its own alert group, so N runs are N
# distinct faults rather than one fault reported N times. It also exercises
# more of the fabric, which is the better test anyway.
#
# The leak case cannot rotate: only the border router has a transit policy to
# relax. It relies on the settle below being longer than group_interval.
target_for() {
  case "$CASE" in
    interface|drift)
      case $(( ($1 - 1) % 3 )) in
        0) echo srl3 ;;
        1) echo srl1 ;;
        2) echo srl2 ;;
      esac ;;
    leak) echo srl3 ;;
  esac
}

inject() {
  TARGET=$(target_for "$1")
  case "$CASE" in
    interface) ./scripts/break.sh interface "$TARGET" >/dev/null 2>&1 ;;
    leak)      ./scripts/break.sh leak      "$TARGET" >/dev/null 2>&1 ;;
    drift)     ./scripts/break.sh drift     "$TARGET" >/dev/null 2>&1 ;;
    *) echo "unknown case: $CASE (interface|leak|drift|all)" >&2; exit 2 ;;
  esac
}

# Put the device back by hand when the loop did not. Done as a human -- these
# do not count against the ceilings -- so a refused run does not poison the
# next one's starting state.
reset_case() {
  T=$(target_for "$1")
  case "$CASE" in
    interface)
      docker exec -i "clab-selfheal-$T" sr_cli >/dev/null 2>&1 <<'X' || true
enter candidate
set / interface ethernet-1/1 admin-state enable
commit stay
X
      ;;
    leak)
      docker exec salt-master salt "$T" state.apply bgp_policy \
        pillar='{"actor":"soak-reset","actor_type":"human"}' >/dev/null 2>&1 || true
      ;;
    drift)
      docker exec salt-master salt "$T" state.apply sync_from_netbox \
        pillar='{"actor":"soak-reset","actor_type":"human"}' >/dev/null 2>&1 || true
      ;;
  esac
}

run_case() {
  echo
  echo "=== $CASE x $RUNS ==="
  i=1
  while [ "$i" -le "$RUNS" ]; do
    T0=$(date -u +%Y-%m-%dT%H:%M:%S)
    printf '  %-5s run %2d/%-2d %-5s ' "$CASE" "$i" "$RUNS" "$(target_for "$i")"
    inject "$i"
    # Wait for the run to reach a terminal stage rather than a fixed sleep: a
    # fixed sleep either wastes minutes or truncates the slow runs, and both
    # corrupt the numbers this exists to produce.
    waited=0
    while [ "$waited" -lt "$TIMEOUT" ]; do
      sleep 10
      waited=$((waited + 10))
      ROW=$(stages "${T0}Z")
      case "$ROW" in
        *ERR*) break ;;
      esac
      RESOLVED=$(printf '%s' "$ROW" | cut -f10)
      ENDED=$(printf '%s' "$ROW" | cut -f9)
      BLOCKED=$(printf '%s' "$ROW" | cut -f6)
      BREAKER=$(printf '%s' "$ROW" | cut -f5)
      DECLINED=$(printf '%s' "$ROW" | cut -f4)
      DECIDED=$(printf '%s' "$ROW" | cut -f3)
      APPLIED=$(printf '%s' "$ROW" | cut -f7)
      # Resolved is the only clean finish.
      [ "$RESOLVED" != "-" ] && break
      # A terminal non-repair: duplicate, rejected, failed, or applied but
      # never confirmed. Nothing further will happen for this run.
      [ "$ENDED" != "-" ] && [ "$waited" -ge 60 ] && break
      # Refused by either ceiling: nothing further will happen this run.
      [ "$BLOCKED" != "-" ] && [ "$APPLIED" = "-" ] && [ "$waited" -ge 60 ] && break
      [ "$BREAKER" != "-" ] && [ "$DECIDED" = "-" ] && [ "$APPLIED" = "-" ] \
        && [ "$waited" -ge 60 ] && break
      # A decline on its own is NOT terminal. One shut interface raises two
      # faults and the far end is always correctly declined, so treating a
      # decline as the end of the run cut every interface run off before its
      # fault.resolved arrived -- and reported 0/N healed on a lab that was
      # healing every time. Only a decline with no decision and no change
      # behind it means there is nothing left to wait for.
      [ "$DECLINED" != "-" ] && [ "$DECIDED" = "-" ] && [ "$APPLIED" = "-" ] \
        && [ "$waited" -ge 90 ] && break
    done
    printf '%s\t%s\t%s\t%s\n' "$CASE" "$i" "${T0}Z" "$ROW" >> "$OUT"
    printf 'push=%-6s poll=%-6s breaker=%-6s applied=%-6s resolved=%s\n' \
      "$(printf '%s' "$ROW" | cut -f1)" "$(printf '%s' "$ROW" | cut -f2)" \
      "$(printf '%s' "$ROW" | cut -f5)" "$(printf '%s' "$ROW" | cut -f7)" \
      "$(printf '%s' "$ROW" | cut -f10)"
    reset_case "$i"
    # Wait for the fabric to be genuinely clean rather than for a fixed time.
    # A fixed sleep either wastes minutes or starts the next run on top of this
    # one's recovery, and the second corrupts the next run's first timestamps.
    # At least 45s regardless of how clean the trail looks: Grafana's
    # group_interval is 30s, so re-firing inside it is collapsed into the
    # previous notification and the next run silently loses its remediation.
    settle=0
    while [ "$settle" -lt 90 ]; do
      sleep 10
      settle=$((settle + 10))
      OPEN=$(docker exec salt-master salt 'srl*' audit.open_faults \
             --out=json --static 2>/dev/null \
             | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(99); raise SystemExit
print(sum(len(v) for v in d.values() if isinstance(v, dict)))" 2>/dev/null || echo 99)
      # open_faults going to zero says the beacons are happy. It does not say
      # n8n has finished: a decision for the previous run can still be in
      # flight, and it lands in the next run's window and is attributed to it
      # -- which is how a run came back with a decline recorded 0.56s after
      # its own injection, faster than any beacon interval allows.
      #
      # So also require the trail itself to be quiet. The push path is
      # excluded because it reacts to link state within milliseconds and would
      # keep the trail 'busy' through the whole settle.
      QUIET=$(docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
        -X POST 'http://localhost:9200/napalm-audit/_count' \
        -H 'Content-Type: application/json' \
        -d '{"query":{"bool":{"filter":[{"range":{"@timestamp":{"gte":"now-20s"}}}],
             "must_not":[{"term":{"action":"fault.observed"}}]}}}' 2>/dev/null \
        | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['count'])
except Exception:
    print(99)" 2>/dev/null || echo 99)
      [ "${OPEN:-99}" = 0 ] && [ "${QUIET:-99}" = 0 ] && [ "$settle" -ge 45 ] && break
    done
    # The loop above is capped, so it can give up with the fabric still busy
    # -- and both readers above print 99 on any failure to read, which the
    # condition can then never satisfy. Saying so matters: an un-settled start
    # is how one run's records get attributed to the next, and a silent
    # degradation to a blind sleep is indistinguishable from a clean settle.
    if [ "${OPEN:-99}" != 0 ] || [ "${QUIET:-99}" != 0 ]; then
      printf '      (settle gave up after %ss: open=%s recent-records=%s -- the next run may inherit records from this one)\n' \
        "$settle" "${OPEN:-?}" "${QUIET:-?}" >&2
    fi
    i=$((i + 1))
  done
}

echo "soak: $CASE x $RUNS, gate=$GATE, results -> $OUT"
[ "$GATE" = wide ] && widen_gate
printf 'case\trun\tstart\tpush\tpoll\tdecided\tdeclined\tbreaker\tblocked\tapplied\tverified\tended\tresolved\n' > "$OUT"

if [ "$CASE" = all ]; then
  for c in interface leak drift; do
    CASE=$c
    case "$c" in
      leak)  TIMEOUT=${TIMEOUT_LEAK:-900} ;;
      drift) TIMEOUT=${TIMEOUT_DRIFT:-600} ;;
      *)     TIMEOUT=${TIMEOUT_INTERFACE:-600} ;;
    esac
    run_case
  done
  CASE=all
else
  run_case
fi

restore_gate
echo
GATE="$GATE" WIDE_MAX="${WIDE_MAX:-20}" python3 - "$OUT" <<'PY'
import statistics as st
import sys, os

rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])][1:]
cols = ['push', 'poll', 'decided', 'declined', 'breaker', 'blocked',
        'applied', 'verified', 'ended', 'resolved']

print('=' * 72)
wide = os.environ.get('GATE') == 'wide'
wmax = os.environ.get('WIDE_MAX', '20')
print(f'SUMMARY  n={len(rows)}  ceilings during the run: '
      + (f'WIDENED to {wmax}/hour/device, 3 devices/window, BOTH halves'
         if wide else 'as shipped (3/hour/device, 2 devices/15min)'))
print('=' * 72)

by_case = {}
for r in rows:
    by_case.setdefault(r[0], []).append(r)

for case, rs in by_case.items():
    print()
    print(f'{case}   n={len(rs)}')
    for i, c in enumerate(cols):
        vals = []
        for r in rs:
            v = r[3 + i] if len(r) > 3 + i else '-'
            if v not in ('-', '', 'ERR'):
                vals.append(float(v))
        if not vals:
            print(f'  {c:9} 0/{len(rs)}')
            continue
        line = (f'  {c:9} {len(vals)}/{len(rs)}   '
                f'min {min(vals):6.2f}s  median {st.median(vals):6.2f}s  '
                f'max {max(vals):6.2f}s')
        if len(vals) > 1:
            line += f'  stdev {st.stdev(vals):5.2f}'
        print(line)

    # The two numbers the slides actually claim.
    healed = sum(1 for r in rs if len(r) > 12 and r[12] not in ('-', '', 'ERR'))
    breaker = sum(1 for r in rs if len(r) > 7 and r[7] not in ('-', '', 'ERR'))
    gated = sum(1 for r in rs if len(r) > 8 and r[8] not in ('-', '', 'ERR'))
    leads = []
    for r in rs:
        # Guarded like the three counts above. A run whose Elasticsearch read
        # failed writes a FOUR-field row (case, run, start, ERR), and indexing
        # r[4] on it raised IndexError here -- after the per-stage table had
        # printed and before the two headline lines, so a completed soak lost
        # exactly the numbers it exists to produce and then reported itself as
        # having stopped early.
        if len(r) < 5:
            continue
        p, q = r[3], r[4]
        if p not in ('-', '', 'ERR') and q not in ('-', '', 'ERR'):
            leads.append(float(q) - float(p))
    print(f'  --> resolved {healed}/{len(rs)}    '
          f'n8n breaker refused {breaker}/{len(rs)}    '
          f'salt gate refused {gated}/{len(rs)}')
    if leads:
        print(f'  --> push ahead of poll on {sum(1 for x in leads if x > 0)}'
              f'/{len(leads)} by a median of {st.median(leads):+.2f}s')
print()
print('Every number above was read out of the audit trail, not timed by the')
print('test. A blank stage means no record, which is a result, not a gap.')
PY
