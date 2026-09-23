#!/usr/bin/env sh
# The route leak, from the only account that settles an argument: the
# provider's.
#
# Our own adj-rib-out is us saying what we think we sent. In a room full of
# people who run networks, that is not evidence -- and there is a specific
# reason it is not, which is worth knowing before standing in front of
# them.
#
# A leak built by re-announcing what you learned from your transit provider
# produces NOTHING on that provider, because its own AS is in the path and
# BGP drops it at the door. Demonstrate it that way and the honest reading
# is "loop prevention saved you", not "the automation did". The leak that
# actually reaches a provider is a more-specific of your OWN space: no loop
# to catch it, longest-prefix wins, and deaggregation is what really
# happens at 2am.
#
# So srl3 originates 203.0.113.0/24 and the two /26s inside it, and
# transit-out permits the aggregate alone. The /26s are held in by policy,
# not by absence. Relax that policy and they escape -- and AS64500 counts
# three where it counted one.
#
#   ./scripts/show-leak.sh          what the provider has right now
#   while :; do clear; ./scripts/show-leak.sh; sleep 2; done     (macOS has no `watch`)
set -eu
cd "$(dirname "$0")/.."

PEER=198.51.100.1          # us, from srl4's point of view
B='\033[1m'; D='\033[2m'; G='\033[32m'; R='\033[31m'; N='\033[0m'

frr() { docker exec clab-selfheal-srl4 vtysh -c "$1" 2>/dev/null; }

printf "${B}── AS64500 (srl4), our transit provider ──${N}\n"
printf "${D}   not our account of what we sent. Theirs, of what they got.${N}\n\n"

RECV=$(frr "show bgp ipv4 unicast neighbors $PEER received-routes")
# FRR prints "Total number of prefixes N" as its last line.
N_RECV=$(printf '%s' "$RECV" | sed -n 's/.*Total number of prefixes \([0-9]*\).*/\1/p' | tail -1)
N_RECV=${N_RECV:-0}

# FRR indents its table rows by one space, so an anchored /^\*/ matched
# nothing and the pane showed a count with no prefixes under it.
printf '%s' "$RECV" | awk '/^ *\*|^ *Network/ {print "   " $0}' | head -12

echo
if [ "$N_RECV" -le 1 ]; then
    printf "   ${G}${B}%s prefix received from AS65001${N}\n" "$N_RECV"
    printf "   ${D}the aggregate, and nothing else. This is correct.${N}\n"
else
    printf "   ${R}${B}%s prefixes received from AS65001${N}\n" "$N_RECV"
    printf "   ${R}more than the aggregate is leaving our AS.${N}\n"
fi

echo
printf "${D}   (the three prefixes AS64500 originates are not listed above:\n"
printf "    we re-announce them under the leak too, and its own AS-path\n"
printf "    loop check drops them before they are ever counted.)${N}\n"
