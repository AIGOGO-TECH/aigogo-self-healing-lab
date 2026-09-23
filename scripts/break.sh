#!/usr/bin/env sh
# Inject one of the fault classes, then get out of the way.
#
#   ./scripts/break.sh interface [srl3]     an interface is shut
#   ./scripts/break.sh mtu       [srl1]     the two ends of a link disagree
#   ./scripts/break.sh bgp       [srl3]     a session is shut
#   ./scripts/break.sh drift     [srl1]     a description is edited by hand
#   ./scripts/break.sh prefixes  [900]      the upstream leaks a big table
#   ./scripts/break.sh leak      [srl3]     we leak transit's routes back
#   ./scripts/break.sh unknown              a fault with no runbook at all
#
# Nothing here talks to Salt. Every injection is made straight on the
# device, the way a mistake would be — which is the only kind of demo worth
# showing, because it leaves the detection to the system rather than to the
# person running the demo.
set -eu
cd "$(dirname "$0")/.."
. ./.env

FAULT=${1:-interface}
DEV=${2:-}

# Do NOT send this to /dev/null. It used to, and `break.sh mtu` spent an
# unknown length of time printing "setting ethernet-1/1 mtu to 1400" while
# the device answered
#
#   Invalid value "1400": Must be an integer in range 1450..9500
#
# and changed nothing. A fault-injection script that reports injecting a
# fault it did not inject is worse than no script: every test downstream of
# it passes for the wrong reason.
cli() {
    out=$(docker exec -i "clab-selfheal-$1" sr_cli 2>&1)
    if printf '%s' "$out" | grep -qi 'error'; then
        printf '%s\n' "$out" >&2
        echo "FAILED to inject the fault on $1 — nothing was changed" >&2
        exit 1
    fi
}

stamp() { date -u +%H:%M:%SZ; }

case "$FAULT" in
  interface)
    DEV=${DEV:-srl3}
    echo "$(stamp)  shutting ethernet-1/1 on $DEV"
    cli "$DEV" <<'X'
enter candidate
set / interface ethernet-1/1 admin-state disable
commit stay
X
    ;;

  mtu)
    DEV=${DEV:-srl1}
    # 1500, not 1400: SR Linux 24.10.1 accepts 1450..9500 and rejects
    # anything below, so the old value was refused by the device and this
    # script never noticed. The far end stays at 9232.
    echo "$(stamp)  setting ethernet-1/1 mtu to 1500 on $DEV — the far end stays at 9232"
    echo "          both configs are individually valid. $DEV will report"
    echo "          ip-mtu-too-large; the FAR END reports nothing at all,"
    echo "          and neither of them knows the other's number."
    cli "$DEV" <<'X'
enter candidate
set / interface ethernet-1/1 mtu 1500
commit stay
X
    ;;

  bgp)
    DEV=${DEV:-srl3}
    # 10.255.0.2, not 10.0.0.2. The fabric was renumbered when it grew a
    # border router and an upstream; this line was not, so `break.sh bgp`
    # was addressing a neighbour that has not existed for some time. The
    # device refused it and cli() used to throw the error away.
    PEER=${PEER:-10.255.0.2}
    echo "$(stamp)  shutting the iBGP session to $PEER on $DEV"
    cli "$DEV" <<X
enter candidate
set / network-instance default protocols bgp neighbor $PEER admin-state disable
commit stay
X
    ;;

  drift)
    DEV=${DEV:-srl1}
    echo "$(stamp)  editing an interface description by hand on $DEV"
    echo "          NetBox still says something else, so this is drift"
    cli "$DEV" <<'X'
enter candidate
set / interface ethernet-1/1 description "edited by hand at 2am"
commit stay
X
    ;;

  prefixes)
    # The upstream starts announcing far more than it should. Nothing on
    # srl3 is misconfigured: its prefix limit is doing exactly its job, and
    # the correct response is emphatically NOT to raise it -- widening a
    # limit because the limit went off disables the safety device. The
    # model is expected to decline, and it does.
    #
    # srl4 runs FRR, so this is injected in FRR's own syntax. That is the
    # point of having a different vendor upstream: a fault that arrives
    # from outside your own configuration language.
    COUNT=${DEV:-900}
    echo "$(stamp)  making srl4 (AS64500) announce $COUNT extra prefixes to srl3"
    echo "          srl3 permits 1000 and warns at 80%, so this trips the"
    echo "          warning without tearing the session down"
    python3 - "$COUNT" <<'X' > /tmp/selfheal-leak.conf
import ipaddress, sys
count = int(sys.argv[1])
nets = list(ipaddress.ip_network("100.64.0.0/10").subnets(new_prefix=24))[:count]
print("ip prefix-list TRANSIT-ORIGINATE seq 40 permit 100.64.0.0/10 le 24")
for n in nets:
    print(f"ip route {n} Null0")
print("router bgp 64500")
print("address-family ipv4 unicast")
print("redistribute static")
print("exit-address-family")
print("exit")
X
    docker cp /tmp/selfheal-leak.conf clab-selfheal-srl4:/tmp/leak.conf >/dev/null
    docker exec clab-selfheal-srl4 vtysh -f /tmp/leak.conf >/dev/null 2>&1
    rm -f /tmp/selfheal-leak.conf
    echo "          undo with: ./scripts/unbreak.sh prefixes"
    exit 0
    ;;

  leak)
    # A route leak, injected the way one actually happens: not by writing
    # "leak everything" but by relaxing one line while chasing something
    # else at 2am. transit-out's default action goes from reject to accept
    # and every route srl3 knows -- including the full transit table it
    # learned from AS64500 -- starts going back out to AS64500.
    #
    # Note what does NOT detect this. The configuration is syntactically
    # fine and internally consistent; a diff against the golden protocol
    # config passes; the session stays up; no counter moves on srl3. The
    # only place the damage exists is the adj-rib-out.
    DEV=${DEV:-srl3}
    echo "$(stamp)  relaxing transit-out default-action to accept on $DEV"
    echo "          the config still looks fine. The announcements do not."
    cli "$DEV" <<'X'
enter candidate
set / routing-policy policy transit-out default-action policy-result accept
commit stay
X
    ;;

  unknown)
    echo "$(stamp)  posting a fault no template addresses"
    echo "          the model is expected to answer \"none\" — declining is"
    echo "          a correct answer, and it becomes a ticket, not a push"
    curl -s -X POST "http://${BIND_ADDR:-127.0.0.1}:5678/webhook/fault" \
      -H 'Content-Type: application/json' \
      -d '{"device":"srl1","fault":"bgp_session_flapping","interface":"",
           "detail":"BGP peer flapping every 30s, no template exists"}' | head -c 300
    echo
    exit 0
    ;;

  *)
    sed -n '3,9p' "$0"
    exit 1
    ;;
esac

cat <<WATCH

Now watch, without touching anything:

  # the audit trail — one trace id from detection to resolution
  docker exec salt-master salt '$DEV' audit.history device=$DEV

  # the event bus, live
  docker exec salt-master salt-run state.event pretty=True

  # the device's own record of who changed it
  docker exec clab-selfheal-$DEV sr_cli "info from state /system configuration checkpoint *"

WATCH
