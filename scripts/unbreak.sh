#!/usr/bin/env sh
# Undo an injected fault. Most of break.sh is undone by the automation
# itself -- that is the whole point -- but the prefix leak is not:
#
#   prefixes   the leak is on srl4, which has no proxy-minion and is
#              deliberately outside the automation's reach. Nothing in this
#              stack will ever clean it up, and that is correct: you do not
#              fix your upstream's mistakes, you phone them.
#
# This undoes it in place, with FRR's own negation commands.
#
# NOT by restarting srl4, which was the obvious first answer and is wrong:
# containerlab builds the veth between srl3:e1-3 and srl4:eth1 at deploy
# time, and `docker restart` destroys it. The container comes back with its
# configuration intact, no eth1, and a BGP session that will never leave
# Active -- which looks exactly like a routing problem and is not one.
set -eu
cd "$(dirname "$0")/.."

case "${1:-prefixes}" in
  prefixes)
    echo "withdrawing the leaked prefixes on srl4 (in place, no restart)"
    docker exec -i clab-selfheal-srl4 vtysh >/dev/null <<'X'
configure terminal
router bgp 64500
 address-family ipv4 unicast
  no redistribute static
 exit-address-family
exit
no ip prefix-list TRANSIT-ORIGINATE seq 40
end
X
    # The static routes themselves are harmless once they are no longer
    # redistributed, but leaving 900 of them behind makes the next run's
    # "before" state a lie.
    docker exec clab-selfheal-srl4 sh -c \
      'vtysh -c "show running-config" | grep "^ip route 100\.64\." |
       sed "s/^/no /" > /tmp/undo.conf; [ -s /tmp/undo.conf ] &&
       vtysh -f /tmp/undo.conf >/dev/null 2>&1; rm -f /tmp/undo.conf' || true
    echo "done. srl3 should be back to 3 received prefixes within a minute."
    ;;
  *)
    sed -n '3,16p' "$0"
    exit 1
    ;;
esac
