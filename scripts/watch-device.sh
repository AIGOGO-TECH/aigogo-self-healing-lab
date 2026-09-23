#!/usr/bin/env sh
# The router's own log, live, while something is changing it.
#
# Every other pane is our account of what we did. This one is the box's:
# SR Linux writes a line for each checkpoint it generates and each commit
# it accepts, and because netsafe.py puts the trace id and the actor into
# the commit message, those lines name the decision that caused them:
#
#   Generated checkpoint NAPALM-1e219682-1 with comment selfheal
#     actor=bootstrap state=bgp_policy
#   All changes have been committed successfully by user admin session 197
#
# That is the difference between showing a configuration and showing a
# configuration being applied.
#
#   ./scripts/watch-device.sh            all three routers
#   ./scripts/watch-device.sh srl3       one of them
set -u
cd "$(dirname "$0")/.."
DEVS=${*:-srl1 srl2 srl3}

B='\033[1m'; D='\033[2m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; N='\033[0m'
printf "${B}── 2  THE ROUTERS' OWN LOG, LIVE ──${N}\n"
printf "${D}   not our account of what we pushed. Theirs, of what they committed.${N}\n\n"

# -F, not -f: SR Linux rotates /var/log/messages under a busy converge and
# a plain -f then follows a file nobody writes to any more -- a pane that
# goes quiet exactly when the interesting part starts.
for d in $DEVS; do
  docker exec "clab-selfheal-$d" tail -F -n 0 /var/log/messages 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"Generated checkpoint"*)
        ts=$(printf '%s' "$line" | awk '{print $3}')
        # SR Linux appends " on the following path /etc/opt/.../checkpoint-0.json."
        # which is forty wasted columns in a pane that has ninety.
        cmt=$(printf '%s' "$line" | sed 's/.*with comment //; s/ on the following path .*//')
        printf "${C}%s${N}  ${B}%-5s${N} ${Y}checkpoint${N}  %s\n" "$ts" "$d" "$cmt" ;;
      *"changes have been committed"*)
        ts=$(printf '%s' "$line" | awk '{print $3}')
        printf "${C}%s${N}  ${B}%-5s${N} ${G}committed${N}\n" "$ts" "$d" ;;
      *"Interface"*" is "*|*"bgp"*"Peer"*|*"BGP"*"state"*)
        # Strip the syslog prefix and the module header. SR Linux writes
        #   Sep 23 04:37:00 srl3 sr_chassis_mgr: chassis|2010|2010|00098|W: Interface ...
        # and only the part after the severity letter is worth a pane.
        ts=$(printf '%s' "$line" | awk '{print $3}')
        msg=$(printf '%s' "$line" | sed 's/.*|[A-Z]: //')
        printf "${C}%s${N}  ${B}%-5s${N} ${D}%s${N}\n" "$ts" "$d" "$(printf '%.64s' "$msg")" ;;
    esac
  done &
done
wait
