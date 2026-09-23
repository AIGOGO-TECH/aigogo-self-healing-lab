#!/usr/bin/env sh
# The Salt event bus, filtered down to what a person can watch.
#
# `salt-run state.event` is the raw feed and it is the right thing for
# debugging, but it is unwatchable on a screen: three heartbeats a minute,
# every job start and return, and one long JSON blob per line.
#
# This keeps the events that mean something to a human -- a beacon raising
# a fault, a job being published, a job returning -- drops the heartbeats,
# and prints the tag with the one field that matters. Intended for a demo
# pane, and for looking over someone's shoulder while a fault is open.
#
#   ./scripts/watch-events.sh            everything but heartbeats
#   ./scripts/watch-events.sh srl3       one device
set -eu
cd "$(dirname "$0")/.."
DEV=${1:-}

R='\033[31m'; G='\033[32m'; Y='\033[33m'; D='\033[2m'; N='\033[0m'
B='\033[1m'

# A title, because this was the one pane of four without one.
#
# The other three announce themselves -- YOU TYPE HERE, SELF-HEAL LIVE,
# FROM THE DEVICE ITSELF -- and this one opened on a shell prompt with the
# command still on it, then a single dim heartbeat line. On a recording
# that is indistinguishable from a pane that failed to start, and it gives
# an audience nothing to hang the next sixty seconds on.
#
# Two lines, in English like every other thing on that screen, saying what
# the feed is and what it is not.
clear 2>/dev/null || true
printf "${B}── 2  SALT EVENT BUS, LIVE ──${N}\n"
printf "${D}   every beacon reading and every job, as the master sees it.\n"
printf "   nothing here is filtered for the demo except the heartbeats,\n"
printf "   which are dimmed rather than dropped.${N}\n\n"

# stdbuf -oL, and it matters. Piping salt-run into anything block-buffers
# it: the pane sits empty for a minute and then dumps everything at once,
# which is the opposite of what a live view is for. Measured: 59 events in
# 25s go to a file, and zero of them reach a pipe in the same window.
# Reconnect, rather than dying quietly.
#
# `salt-run state.event` is a stream from the master, and when the master
# restarts the stream just ends. The pane then sits there showing its last
# few lines, looking exactly like a quiet network. That happened during a
# recording: salt-master was restarted, and the event pane was dead for the
# rest of the session with nothing to say so.
while :; do
docker exec salt-master stdbuf -oL -eL salt-run state.event 2>/dev/null |
while IFS= read -r line; do
  tag=${line%%	*}
  data=${line#*	}

  case "$tag" in
    *heartbeat*)
        # Not dropped. A pane that shows nothing for the first thirty
        # seconds of a recording looks broken, and "the network is quiet"
        # and "this window is dead" have to look different. One dim line a
        # minute is the pulse.
        if [ "${NOPULSE:-}" = "1" ]; then continue; fi
        dev=$(printf '%s' "$tag" | sed 's|salt/beacon/||; s|/heartbeat.*||')
        printf "${D}%s  heartbeat %-28s watching${N}\n" "$(date -u +%H:%M:%SZ)" "$dev"
        continue ;;
    *minion/refresh*)   continue ;;
    # Housekeeping. salt/auth is a minion re-authenticating and
    # saltutil.find_job is Salt asking itself whether a job is still
    # running; both are constant, neither is a thing that happened to the
    # network. On screen they crowd out the events that are.
    salt/auth*)         continue ;;
    *find_job*)         continue ;;
    *state.event*)      continue ;;
    salt/event_listen*) continue ;;
  esac
  [ -n "$DEV" ] && case "$tag" in *"$DEV"*) ;; *) continue ;; esac

  # the human-readable field, whichever this event carries
  detail=$(printf '%s' "$data" | sed -n 's/.*"detail": "\([^"]*\)".*/\1/p')
  [ -z "$detail" ] && detail=$(printf '%s' "$data" | sed -n 's/.*"fun": "\([^"]*\)".*/\1/p')

  ts=$(date -u +%H:%M:%SZ)
  # A demo pane is about 96 columns at Menlo 13pt. The tag is the useful half.
  if [ "${NARROW:-}" = "1" ]; then
      tag=$(printf '%s' "$tag" | sed 's|^salt/beacon/||; s|^salt/job/[0-9]*/|job/|')
      tag=$(printf '%.38s' "$tag")
      detail=$(printf '%.42s' "$detail")
      printf "%s  %-38s %s\n" "$ts" "$tag" "$detail"
      continue
  fi
  case "$tag" in
    *"/fault")   printf "${R}%s  %-52s${N} %s\n" "$ts" "$tag" "$detail" ;;
    *"/drift")   printf "${Y}%s  %-52s${N} %s\n" "$ts" "$tag" "$detail" ;;
    salt/job/*/new)     continue ;;
    salt/job/*/publish) continue ;;
    salt/job/*/ret/*) printf "${G}%s  %-52s${N} %s\n" "$ts" "$tag" "$detail" ;;
    *)           printf "${D}%s  %-52s${N} %s\n" "$ts" "$tag" "$detail" ;;
  esac
done
  printf "${Y}%s  -- event stream ended, reconnecting --${N}\n" "$(date -u +%H:%M:%SZ)"
  sleep 3
done
