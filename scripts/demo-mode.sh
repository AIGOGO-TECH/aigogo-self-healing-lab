#!/usr/bin/env sh
# Make room on the laptop before recording, and give it back afterwards.
#
# The problem is arithmetic, not configuration. This lab is developed on a
# 16 GB machine whose Docker VM is allocated 11.7 GB, and llama3.1 needs
# 5.1 GB of HOST memory -- it runs natively, not in a container. 11.7 plus
# 5.1 is 16.8 on a machine that has 16, so the model's arrival is paid for
# in swap.
#
# Measured through one real decision, with nothing else running:
#
#   14:59:35  swap=4674M  free=34%  load=6.3   <- fault injected
#   15:00:14  swap=7563M  free=27%  load=8.2   <- the model loads
#   15:01:27  swap=5922M  free=56%  load=5.1   <- settled
#
# Nearly three gigabytes of swap in forty seconds, and those forty seconds
# are the interesting part of the demo: detection, decision, push. A screen
# recorder is writing video through the same window. This is where the
# machine stalls, and it stalls on camera.
#
# Two things fix it, and neither is subtle:
#
#   1. load the model BEFORE the recording starts, and keep it loaded.
#      Ollama unloads after five minutes idle by default, so between takes
#      it evaporates and the next take pays for it again. Pinning it means
#      the 5.1 GB is already resident when you press record.
#
#   2. stop what the demo does not show. Kibana alone is ~1 GB, and the
#      four-pane screen never opens it.
#
#   ./scripts/demo-mode.sh on     # before recording
#   ./scripts/demo-mode.sh off    # afterwards
#   ./scripts/demo-mode.sh        # just report the headroom
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env" >&2; exit 1; }
. ./.env

B='\033[1m'; D='\033[2m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'

# Services the four-pane demo never shows. Grafana stays: it is the
# detector. NetBox stays: every drift beacon reads it. Elasticsearch stays:
# it IS the audit trail, which is pane 3.
SPARE="kibana docker-logs docker-stats"

report() {
  SWAP=$(sysctl -n vm.swapusage | sed 's/.*used = \([0-9.]*\)M.*/\1/')
  FREE=$(memory_pressure 2>/dev/null | tail -1 | grep -o '[0-9]*%' || echo '?')
  # `|| echo 0` would never fire: the pipeline's status is awk's, and awk
  # succeeds while printing nothing when the router is not running. The
  # empty string would then reach $(( )) as `$(( / 1024 ))`, a syntax error
  # -- on a torn-down lab, which is exactly when this is run.
  VMKB=$(docker exec clab-selfheal-srl1 grep MemFree /proc/meminfo 2>/dev/null | awk '{print $2}')
  case "${VMKB:-}" in
    ''|*[!0-9]*) VMFREE="" ;;
    *)           VMFREE=$(( VMKB / 1024 )) ;;
  esac
  LOAD=$(uptime | sed 's/.*averages: //' | awk '{print $1}')
  # No backslash-escaped quotes in here. The shell string is single-quoted,
  # so python can use double quotes freely -- escaping them made python see
  # a SyntaxError, which `except` cannot catch because it happens at
  # compile time, so the command printed nothing and exited 1. Under
  # `set -e` that killed the script with no message at all.
  RESIDENT=$(curl -s --max-time 5 http://localhost:11434/api/ps 2>/dev/null |
    python3 -c 'import sys, json
try:
    m = json.load(sys.stdin).get("models") or []
    print("%.1f GB resident" % (m[0]["size"] / 1073741824) if m else "NOT LOADED")
except Exception:
    print("ollama not answering")' 2>/dev/null || echo "ollama not answering")
  printf "\n  ${B}host${N}        swap %sM used   memory free %s   load %s\n" "$SWAP" "$FREE" "$LOAD"
  if [ -n "$VMFREE" ]; then
    printf "  ${B}docker vm${N}   %s MB free inside the VM\n" "$VMFREE"
  else
    printf "  ${B}docker vm${N}   ${D}routers are not running${N}\n"
  fi
  printf "  ${B}%-11s${N} %s\n" "${OLLAMA_MODEL:-llama3.1}" "$RESIDENT"

  # Can a take start right now? Two ceilings answer that, and they are not
  # the same question. The per-device budget refuses a fourth change to one
  # router in an hour; the blast radius refuses a change to a THIRD router
  # within fifteen minutes, however small each one was. A re-take on a
  # different router ten minutes later hits the second one and looks, on
  # the pane, exactly like a broken lab.
  WINDOW=$(docker exec salt-master curl -s --max-time 15 -u "elastic:$ELASTIC_PASSWORD" \
    'http://elasticsearch:9200/napalm-audit/_search?size=50' -H 'Content-Type: application/json' \
    -d '{"sort":[{"@timestamp":"asc"}],"query":{"bool":{"must":[{"term":{"action":"change.applied"}},{"range":{"@timestamp":{"gte":"now-15m"}}}],"must_not":[{"term":{"actor_type":"human"}}]}}}' 2>/dev/null |
    python3 -c '
import sys, json, datetime
try:
    hits = json.load(sys.stdin)["hits"]["hits"]
except Exception:
    print("?|could not read the audit trail"); raise SystemExit
devs, first = [], None
for h in hits:
    src = h["_source"]
    if src["device"] not in devs:
        devs.append(src["device"])
    first = first or src["@timestamp"]
if not devs:
    print("0|clear — any router, right now")
else:
    free = (datetime.datetime.strptime(first[11:19], "%H:%M:%S")
            + datetime.timedelta(minutes=15)).strftime("%H:%M:%S")
    print("%d|%s — a third router is refused until %s" % (len(devs), " ".join(devs), free))
' 2>/dev/null || echo "?|could not read the audit trail")
  # NDEV, not N: N is the reset escape, and assigning to it here blanked
  # every colour on the rest of the report.
  NDEV=${WINDOW%%|*}; WHO=${WINDOW#*|}
  printf "  ${B}blast radius${N}  %s of 2 devices in the last 15m: %s\n" "$NDEV" "$WHO"

  for dev in srl1 srl2 srl3; do
    USED=$(docker exec salt-master salt "$dev" audit.recent device="$dev" \
           action=change.applied minutes=60 unattended_only=True --out=json 2>/dev/null |
           tr -dc '0-9' | tail -c 1)
    USED=${USED:-?}
    case "$USED" in
      0|1) MARK="${G}ok${N}" ;;
      2)   MARK="${Y}one change left${N}" ;;
      3)   MARK="${R}spent — will be refused${N}" ;;
      # Unknown is not spent. Reporting "will be refused" for a lab that is
      # simply not running sends you hunting a rate limit that does not exist.
      *)   MARK="${D}unknown — lab not running${N}" ;;
    esac
    printf "  ${B}%s${N}        %s of 3 changes this hour   %b${N}\n" "$dev" "$USED" "$MARK"
  done
  case "$RESIDENT" in
    "NOT LOADED")
      printf "  ${Y}-> the model will load during your take, and cost ~3 GB of swap\n"
      printf "     when it does. Run: ./scripts/demo-mode.sh on${N}\n" ;;
    *GB*) printf "  ${G}-> the model is already resident; the spike is behind you${N}\n" ;;
  esac
  echo
}

case "${1:-report}" in
  on)
    printf "${B}== making room ==${N}\n"
    for svc in $SPARE; do
      if [ -n "$(docker ps -q -f "name=^${svc}$")" ]; then
        MEM=$(docker stats --no-stream --format '{{.MemUsage}}' "$svc" 2>/dev/null | awk -F'/' '{print $1}')
        echo "  stopping $svc (was using $MEM) — the demo never opens it"
        docker stop "$svc" >/dev/null
      fi
    done

    # Pin the model in memory. keep_alive accepts a duration; -1 would pin
    # it forever, which is worse than it sounds on a 16 GB machine -- it
    # never gives the memory back, including after the recording. Two hours
    # covers a session and expires on its own if this script is forgotten.
    printf "${B}== warming the model ==${N}\n"
    echo "  loading ${OLLAMA_MODEL:-llama3.1} and pinning it for 2 hours"
    curl -s --max-time 180 http://localhost:11434/api/generate \
      -d '{"model":"'"${OLLAMA_MODEL:-llama3.1}"'","prompt":"ready","stream":false,"keep_alive":"2h"}' \
      >/dev/null 2>&1 || {
        echo "  ollama is not answering on localhost:11434." >&2
        echo "  Open Ollama.app (or run: ollama serve &), then run this again." >&2
        echo "  Without it the decision step does nothing and the demo just sits there." >&2
      }
    report
    printf "  ${D}Record now. Between takes the model stays resident, so only the\n"
    printf "  first decision pays for the load. When you are done:\n"
    printf "    ./scripts/demo-mode.sh off${N}\n\n"
    ;;
  off)
    printf "${B}== giving it back ==${N}\n"
    for svc in $SPARE; do
      echo "  starting $svc"
      docker compose up -d "$svc" >/dev/null 2>&1 || true
    done
    echo "  releasing the model"
    curl -s --max-time 30 http://localhost:11434/api/generate \
      -d '{"model":"'"${OLLAMA_MODEL:-llama3.1}"'","prompt":"","keep_alive":0}' >/dev/null 2>&1 || true
    report
    ;;
  *) report ;;
esac
