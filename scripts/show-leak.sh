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
N_RECV=$(printf '%s' "$RECV" | sed -n 's/.*Total number of prefixes \([0-9]*\).*/\1/p' | tail -1)
N_RECV=${N_RECV:-0}

# Group what arrived, instead of printing the table.
#
# A BGP table is the right output for an operator with time and the wrong
# one for a room: ten rows of prefixes read as noise, and the thing that
# matters -- that three of them are our routers' loopbacks and three more
# are the links between them -- is only visible to someone who already
# knows the addressing. Naming each group says it in one line.
PFX=$(printf '%s' "$RECV" | awk '/^ *\*/ {print $2}')
say_group() {   # say_group <label> <regex> <meaning>
    n=$(printf '%s\n' "$PFX" | grep -cE "$2" || true)
    [ "${n:-0}" = 0 ] && return
    list=$(printf '%s\n' "$PFX" | grep -E "$2" | tr '\n' ' ' | cut -c1-44)
    printf "   ${B}%2s${N}  %-16s ${D}%-46s%s${N}\n" "$n" "$1" "$list" "$3"
}

printf "   ${B}%s prefixes received from AS65001${N}\n\n" "$N_RECV"
say_group "loopbacks"      '^10\.255\.0\.'        "our routers' own identities"
say_group "p2p links"      '^10\.255\.1\.'        "the links between them"
say_group "more-specifics" '^203\.0\.113\.(0/26|64/26)' "our space, deaggregated"
say_group "the aggregate"  '^203\.0\.113\.0/24$'  "the only one permitted"
say_group "transit link"   '^198\.51\.100\.'      "the link to this provider"
echo
if [ "$N_RECV" -le 1 ]; then
    printf "   ${G}${B}This is correct — the aggregate, and nothing else.${N}\n"
else
    printf "   ${R}${B}Our internal topology is on a transit provider's router.${N}\n"
    printf "   ${R}RFC 7908 Type 6: internal and more-specific prefixes, leaked.${N}\n"
fi

echo
printf "${D}   (the three prefixes AS64500 originates are not listed above:\n"
printf "    we re-announce them under the leak too, and its own AS-path\n"
printf "    loop check drops them before they are ever counted.)${N}\n"
