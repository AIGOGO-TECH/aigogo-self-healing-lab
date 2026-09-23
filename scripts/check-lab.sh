#!/usr/bin/env sh
# Ask one question: is this lab COMPLETE, or merely running?
#
# Those are different questions and the difference has cost a recording.
# bootstrap.sh runs `set -e`: when the NetBox seed failed on a machine with
# no route to PyPI, the script stopped there -- and the n8n import that
# comes afterwards never ran. Every container was up. Every health check was
# green. Grafana fired correctly, Salt detected correctly, ollama answered.
# The only thing missing was the workflow that connects them, and nothing
# anywhere said so. A fault sat open for four minutes while n8n logged
#
#   Received request for unknown webhook: "POST fault" is not registered
#
# to a file nobody was reading. "docker ps" cannot detect that state, which
# is exactly why this script exists: it checks the WIRING between services,
# not the liveness of each one.
#
#   ./scripts/check-lab.sh          every check, verbose
#   ./scripts/check-lab.sh -q       only what is broken
#
# Exit code is the number of failed checks, so bootstrap.sh can act on it.
set -u
cd "$(dirname "$0")/.."

QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1

B='\033[1m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; D='\033[2m'; N='\033[0m'
FAILED=0
BROKEN=''

# ok <label> <detail>        -- passed
# bad <label> <detail> <fix> -- failed; <fix> is the command that repairs it
ok()  { [ "$QUIET" = 1 ] || printf "  ${G}[ok]${N}   %-34s ${D}%s${N}\n" "$1" "${2:-}"; }
bad() {
  FAILED=$((FAILED + 1))
  BROKEN="$BROKEN$1\n"
  printf "  ${R}[FAIL]${N} %-34s %s\n" "$1" "${2:-}"
  [ -n "${3:-}" ] && printf "         ${D}fix: %s${N}\n" "$3"
  return 0
}
warn() { printf "  ${Y}[warn]${N} %-34s %s\n" "$1" "${2:-}"; }
sec()  { [ "$QUIET" = 1 ] || printf "\n${B}%s${N}\n" "$1"; }

[ -f .env ] || { echo "no .env -- run ./scripts/gen-secrets.sh first" >&2; exit 1; }
. ./.env

# --- the devices ----------------------------------------------------------
sec "devices"

for dev in srl1 srl2 srl3 srl4; do
  if [ -n "$(docker ps -q -f "name=clab-selfheal-$dev")" ]; then
    ok "$dev is running"
  else
    bad "$dev is running" "container is gone" "./scripts/bootstrap.sh"
  fi
done

# A container can be up with its veth pairs missing: a Docker Desktop
# restart brings every node back through its restart policy and does NOT
# rebuild the links. The fabric then comes up configured and wired to
# nothing, with IS-IS correct on every interface that has no cable.
if docker exec clab-selfheal-srl1 ip -br link 2>/dev/null | grep -q 'e1-1-0.*UP'; then
  ok "the links exist" "veth pairs are up"
else
  bad "the links exist" "nodes are running, cables are not" \
      "cd clab && containerlab deploy -t topo.yml --reconfigure"
fi

# --- Salt -----------------------------------------------------------------
sec "salt"

PING=$(docker exec salt-master salt 'srl*' test.ping --out=json 2>/dev/null)
PONGS=$(printf '%s' "$PING" | grep -c 'true')
if [ "$PONGS" -ge 3 ]; then
  ok "proxy minions answer" "$PONGS of 3"
else
  bad "proxy minions answer" "only $PONGS of 3" \
      "docker compose restart salt-proxy && sleep 30"
fi

# Without a synced beacon nothing is ever DETECTED, and the failure is
# entirely silent: proxies up, master healthy, network simply unwatched.
# What each device should be watching is not the same list. route_leak
# reads what we ADVERTISE to a transit peer, and only srl3 has one; asking
# srl1 for it would be asking a core router about a session it does not
# hold. The proxy configs in salt/proxy-srl* are the source of this.
#
# Note the grep: `beacons.list --out=json` returns a JSON object whose one
# value is a YAML *string*, so the keys arrive as `iface_down:` and never
# as `"iface_down"`. Matching on the quoted form failed every device on a
# lab where all eight beacons were loaded and correct -- a check that
# reports a healthy lab broken is worse than no check at all.
COMMON="iface_down bgp_down config_drift config_drift_golden config_drift_policy p2p_mismatch prefix_limit heartbeat"
for dev in srl1 srl2 srl3; do
  LIST=$(docker exec salt-master salt "$dev" beacons.list --out=json 2>/dev/null)
  EXPECT="$COMMON"
  [ "$dev" = srl3 ] && EXPECT="$EXPECT route_leak"
  MISSING=''; COUNT=0
  for b in $EXPECT; do
    COUNT=$((COUNT + 1))
    printf '%s' "$LIST" | grep -q "$b:" || MISSING="$MISSING $b"
  done
  if [ -z "$MISSING" ]; then
    ok "$dev beacons loaded" "$COUNT watching"
  else
    bad "$dev beacons loaded" "missing:$MISSING" \
        "docker exec salt-master salt '$dev' saltutil.sync_all"
  fi
done

# Configured is not the same as running. `beacons.disable` silences every
# beacon on a minion and leaves the list intact, so the check above still
# passes on a device that is watching nothing -- and bootstrap disables
# them deliberately, for the provisioning window. A crash in that window
# leaves them off.
#
# `config.get beacons_enabled` does not report it either: it returns the
# same empty string before and after a disable. So ask the network, not
# the configuration. Every device carries a heartbeat beacon on a 60s
# interval; if its pulse is in Elasticsearch, the beacon fired, the event
# bus carried it and the returner wrote it -- three things proven by one
# question, and none of them provable by reading a config file.
heartbeats() {
docker exec salt-master curl -s --max-time 15 -u "elastic:$ELASTIC_PASSWORD" \
     'http://elasticsearch:9200/napalm-*/_search?size=0' -H 'Content-Type: application/json' \
     -d '{"query":{"bool":{"must":[{"wildcard":{"tag":"*heartbeat*"}},{"range":{"data._stamp":{"gte":"now-4m"}}}]}},"aggs":{"dev":{"terms":{"field":"data.device.keyword","size":10}}}}' 2>/dev/null |
     python3 -c 'import sys,json
try:
    b = json.load(sys.stdin)["aggregations"]["dev"]["buckets"]
    print(" ".join(x["key"] for x in b))
except Exception:
    print("")' 2>/dev/null
}
HB=$(heartbeats)
mute_devices() {
  M=''
  for dev in srl1 srl2 srl3; do
    printf '%s' "$1" | grep -q "$dev" || M="$M $dev"
  done
  printf '%s' "$M"
}
MUTE=$(mute_devices "$HB")
# The heartbeat interval is 60s and the three devices are not in step, so
# a beacon armed seconds ago has not necessarily pulsed yet. Run straight
# after bootstrap, this reported srl2 silent on a lab that was fine.
# Wait out one full interval before believing it -- but only when
# something is missing, so a healthy lab still checks instantly.
if [ -n "$MUTE" ]; then
  for _ in 1 2 3 4 5; do
    sleep 15
    HB=$(heartbeats)
    MUTE=$(mute_devices "$HB")
    [ -z "$MUTE" ] && break
  done
fi
if [ -z "$MUTE" ]; then
  ok "beacons are actually firing" "heartbeat from all 3 in the last 4m"
else
  bad "beacons are actually firing" "silent:$MUTE" \
      "docker exec salt-master salt 'srl*' beacons.enable"
fi

# A provisioning window left open authorises every override, from anyone
# who can reach salt-api. bootstrap removes it and the trap removes it, so
# finding one here means a run died somewhere neither covered.
if test -f salt/states/provisioning.window; then
  bad "no provisioning window is open" "overrides are authorised right now" \
      "rm -f salt/states/provisioning.window"
else
  ok "no provisioning window is open"
fi

# The master-side event_return loads from the master's OWN extension_modules,
# which `salt '*' saltutil.sync_all` does not populate -- that pushes to
# MINIONS. Miss it and the master keeps the unpatched upstream returner,
# every event raises inside it, and not one Salt event reaches
# Elasticsearch. Grafana then counts zero events and reports the network
# healthy for ever, while the entire detection path is dead.
if docker exec salt-master test -f /var/cache/salt/master/extmods/returners/elasticsearch.py 2>/dev/null; then
  ok "master returner is the patched one"
else
  bad "master returner is the patched one" "master will use upstream" \
      "docker exec salt-master salt-run saltutil.sync_returners && docker compose restart salt-master"
fi

# --- the source of truth --------------------------------------------------
sec "netbox"

NB=$(docker exec -i -e "T=$NETBOX_API_TOKEN" salt-master python3 - <<'PY' 2>/dev/null
import os, json, urllib.request
def get(p):
    r = urllib.request.Request("http://netbox:8080/api/" + p,
                               headers={"Authorization": "Token " + os.environ["T"]})
    return json.load(urllib.request.urlopen(r, timeout=10))
try:
    out = {"devices": get("dcim/devices/?limit=0")["count"],
           "interfaces": get("dcim/interfaces/?limit=0")["count"], "bgp": []}
    for d in get("dcim/devices/?limit=50")["results"]:
        if (d.get("local_context_data") or {}).get("bgp"):
            out["bgp"].append(d["name"])
    print(json.dumps(out))
except Exception as e:
    print(json.dumps({"error": str(e)[:80]}))
PY
)
case "$NB" in
  *'"error"'*|'')
    bad "netbox answers" "${NB:-no reply}" "./scripts/seed-netbox.sh" ;;
  *)
    DEVS=$(printf '%s' "$NB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["devices"])')
    IFS_=$(printf '%s' "$NB" | python3 -c 'import sys,json;print(json.load(sys.stdin)["interfaces"])')
    BGP=$(printf '%s' "$NB" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)["bgp"]))')
    # An empty NetBox is not an error to the drift beacons. They read it,
    # find nothing, and conclude the source of truth says nothing -- so a
    # fabric that has drifted completely looks perfectly compliant.
    if [ "$DEVS" -ge 3 ]; then ok "devices are seeded" "$DEVS devices, $IFS_ interfaces"
    else bad "devices are seeded" "only $DEVS -- the seed did not run" "./scripts/seed-netbox.sh"; fi
    # The border router's BGP intent lived only in a hand-poked database
    # once. `down -v` deleted it and no script put it back.
    if [ "$BGP" = "srl3" ]; then
      ok "border bgp intent exists" "srl3 only, as it should be"
    elif [ -z "$BGP" ]; then
      bad "border bgp intent exists" "no device carries it" "./scripts/seed-netbox.sh"
    else
      bad "border bgp intent exists" "carried by: $BGP -- srl3 alone should" \
          "./scripts/seed-netbox.sh"
    fi ;;
esac

# --- the decision path ----------------------------------------------------
sec "the decision path"

WF=$(docker exec n8n n8n list:workflow 2>/dev/null)
WFN=$(printf '%s' "$WF" | grep -c '|')
if [ "$WFN" -ge 2 ]; then
  ok "n8n workflows imported" "$WFN present"
else
  bad "n8n workflows imported" "$WFN present, expected 2" \
      "./scripts/bootstrap.sh   (step 5 -- it is skipped whenever an earlier step fails)"
fi

# The check that would have caught the four-minute silence. An imported
# workflow that was never published registers no webhook, and the only
# place that shows is a line in n8n's own log.
# n8n reports healthy, and answers its port, several seconds before it has
# registered the workflow's webhook -- so this check run immediately after
# a `docker compose restart n8n` correctly failed on a lab that was about
# to be fine. Give it a bounded wait rather than a verdict on the first
# read; a registered webhook still answers on the first try.
probe_webhook() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "http://${BIND_ADDR:-127.0.0.1}:5678/webhook/fault" \
    -H 'Content-Type: application/json' -d '{"probe":true}' 2>/dev/null
}
CODE=$(probe_webhook)
case "$CODE" in
  200|201|500) : ;;
  *) for _ in 1 2 3 4 5 6; do
       sleep 10
       CODE=$(probe_webhook)
       case "$CODE" in 200|201|500) break ;; esac
     done ;;
esac
case "$CODE" in
  200|201|500) ok "the fault webhook is registered" "POST /webhook/fault -> $CODE" ;;
  404) bad "the fault webhook is registered" "404 -- imported but not published" \
           "docker exec n8n n8n publish:workflow --id=a1b2c3d4-fault-remediation-0001 && docker compose restart n8n" ;;
  *)   bad "the fault webhook is registered" "no answer (${CODE:-timeout})" "docker compose restart n8n" ;;
esac

# n8n reaches ollama at host.docker.internal, which does not resolve out
# here; probe the host's own loopback on the same port.
OPORT=$(printf '%s' "${OLLAMA_URL:-http://host.docker.internal:11434}" | sed 's|.*:||; s|/.*||')
TAGS=$(curl -sf --max-time 10 "http://localhost:${OPORT:-11434}/api/tags" 2>/dev/null)
if [ -z "$TAGS" ]; then
  bad "ollama answers" "nothing on localhost:${OPORT:-11434}" "ollama serve &"
elif printf '%s' "$TAGS" | grep -q "${OLLAMA_MODEL:-llama3.1}"; then
  ok "ollama answers" "${OLLAMA_MODEL:-llama3.1} is pulled"
else
  bad "ollama answers" "running, but ${OLLAMA_MODEL:-llama3.1} is not pulled" \
      "ollama pull ${OLLAMA_MODEL:-llama3.1}"
fi

RULES=$(curl -s --max-time 10 -u "${GRAFANA_ADMIN_USER:-admin}:$GRAFANA_ADMIN_PASSWORD" \
        "http://${BIND_ADDR:-127.0.0.1}:3000/api/v1/provisioning/alert-rules" 2>/dev/null)
if printf '%s' "$RULES" | grep -q 'Network fault detected'; then
  ok "grafana rule is provisioned"
else
  bad "grafana rule is provisioned" "the detector has no trigger" \
      "docker compose restart grafana"
fi

# --- the evidence ---------------------------------------------------------
sec "the audit trail"

ES=$(docker exec salt-master curl -s --max-time 10 -u "elastic:$ELASTIC_PASSWORD" \
     'http://elasticsearch:9200/napalm-audit/_count' 2>/dev/null)
if printf '%s' "$ES" | grep -q '"count"'; then
  CNT=$(printf '%s' "$ES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
  ok "napalm-audit is writable" "$CNT records"
else
  bad "napalm-audit is writable" "no answer from elasticsearch" \
      "docker compose restart elasticsearch"
fi

# Salt's own events, which is what the Grafana rule actually counts. A
# healthy Elasticsearch with an empty event index means the master-side
# returner is not running, not that the network is quiet.
EV=$(docker exec salt-master curl -s --max-time 10 -u "elastic:$ELASTIC_PASSWORD" \
     'http://elasticsearch:9200/napalm-*/_count' 2>/dev/null)
if printf '%s' "$EV" | grep -q '"count"'; then
  EVC=$(printf '%s' "$EV" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
  if [ "$EVC" -gt 0 ]; then ok "salt events are landing" "$EVC indexed"
  else bad "salt events are landing" "index is empty -- detection is dead" \
           "docker exec salt-master salt-run saltutil.sync_returners && docker compose restart salt-master"; fi
else
  bad "salt events are landing" "cannot read the index" "docker compose restart elasticsearch"
fi

# --- verdict --------------------------------------------------------------
echo
if [ "$FAILED" = 0 ]; then
  printf "${G}${B}the lab is complete.${N}  Break something:  ./scripts/break.sh interface srl3\n\n"
else
  printf "${R}${B}the lab is RUNNING BUT INCOMPLETE -- %s check(s) failed.${N}\n" "$FAILED"
  printf "${D}Every container can be healthy while the wiring between them is not.\n"
  printf "Do not record a demo in this state; the fault will simply sit open.${N}\n\n"
fi
exit "$FAILED"
