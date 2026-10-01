#!/usr/bin/env sh
# Bring the whole lab up from nothing, in the order it has to happen in.
#
# Most of this is now declarative — Grafana provisions itself from
# ./grafana, es-init and kibana-init run as compose services — so what is
# left here is the things compose cannot express: containerlab needs its own
# privileged run, and Salt has to be told to sync the custom modules before
# any beacon can load.
set -eu
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
STEP="starting"

# `set -e` stops this script the moment anything fails -- which is correct,
# and was also invisible. The NetBox seed once died on a machine with no
# route to PyPI, so the n8n import three steps below it never ran. Every
# container was up and healthy; the workflow that turns a detected fault
# into a decision simply did not exist. The recording that followed sat on
# an open fault for four minutes with nothing in any UI to explain it.
#
# An aborted bootstrap now says which step died, and says that the steps
# after it were skipped, because "it stopped" and "it finished" looked
# identical in a terminal full of green.
on_exit() {
  rc=$?
  [ "$rc" = 0 ] && return 0
  printf '\n\033[31m\033[1m== BOOTSTRAP DID NOT FINISH ==\033[0m\n'
  printf '\033[31mIt stopped in: %s\033[0m\n' "$STEP"
  printf '\033[2mEverything after that step was skipped. The containers that are\n'
  printf 'already up will look healthy, and the lab will not work.\n'
  printf 'Fix the error above, then run this script again -- it is idempotent.\n'
  printf 'To see exactly what is missing:  ./scripts/check-lab.sh\033[0m\n\n'
  # Step 3 silences the beacons until the devices match intent. If we died
  # anywhere between there and step 4b, they are still silenced -- and a
  # lab whose beacons are off is a lab where nothing is ever detected and
  # every service says it is fine. Turn them back on before leaving.
  docker exec salt-master salt 'srl*' beacons.enable >/dev/null 2>&1 || true
  # And close the provisioning window, or a failed run leaves overrides
  # authorised for as long as nobody notices.
  rm -f salt/states/provisioning.window 2>/dev/null || true
  exit $rc
}
trap on_exit EXIT

# --- 0. preflight ---------------------------------------------------------
[ -f .env ] || { echo "no .env — run ./scripts/gen-secrets.sh first" >&2; exit 1; }
. ./.env

command -v docker >/dev/null || { echo "docker is not on PATH" >&2; exit 1; }
# OLLAMA_URL is the address n8n uses from *inside* a container
# (host.docker.internal), which does not resolve out here. Probe the
# host's own loopback instead, on the same port.
OLLAMA_PORT=$(printf '%s' "${OLLAMA_URL:-http://host.docker.internal:11434}" |
              sed 's|.*:||; s|/.*||')
if curl -sf "http://localhost:${OLLAMA_PORT:-11434}/api/tags" >/dev/null 2>&1; then
  if ! curl -sf "http://localhost:${OLLAMA_PORT:-11434}/api/tags" |
       grep -q "${OLLAMA_MODEL:-qwen2.5:7b}"; then
    echo "WARNING: ollama is running but ${OLLAMA_MODEL:-qwen2.5:7b} is not pulled." >&2
    echo "         ollama pull ${OLLAMA_MODEL:-qwen2.5:7b}" >&2
  fi
else
  echo "WARNING: ollama does not answer on localhost:${OLLAMA_PORT:-11434}." >&2
  echo "         Everything else will come up; the decision step will not." >&2
  echo "         ollama serve &  &&  ollama pull ${OLLAMA_MODEL:-qwen2.5:7b}" >&2
fi

# Postgres applies POSTGRES_PASSWORD only when it initialises an empty data
# directory. On an existing volume, changing NETBOX_DB_PASSWORD in .env does
# nothing at all -- and the breakage is delayed until NetBox next restarts,
# which can be weeks later, and then presents as an endless
# "password authentication failed for user netbox" restart loop.
if [ "$(docker ps -q -f name=netbox-postgres)" ]; then
  if ! docker exec -e PGPASSWORD="$NETBOX_DB_PASSWORD" netbox-postgres \
       psql -U netbox -d netbox -h 127.0.0.1 -c 'select 1' >/dev/null 2>&1; then
    echo "WARNING: the Postgres volume predates the current NETBOX_DB_PASSWORD." >&2
    echo "         Postgres only reads POSTGRES_PASSWORD when it initialises an" >&2
    echo "         empty data directory, so .env and the database disagree." >&2
    echo "         Fix it once, on the running database:" >&2
    echo >&2
    echo "           docker exec netbox-postgres psql -U netbox -d netbox \\" >&2
    echo "             -c \"ALTER USER netbox WITH PASSWORD '\$NETBOX_DB_PASSWORD';\"" >&2
    echo >&2
  fi
fi

# --- 1. devices -----------------------------------------------------------
# containerlab has to run privileged, on the host network, with the docker
# socket — so it cannot be a compose service. It also creates the
# clab-selfheal network that everything else attaches to, which is why it
# is first and not merely early.
# --- 0b. render the device configs -------------------------------------
# Rendered here rather than committed. A committed config puts the IS-IS
# authentication key in the repository whatever it was read from, and pins
# MGMT_PREFIX for everyone who clones -- a topology on one subnet with
# startup-configs on another. Running the generator from bootstrap is also
# what stops it being a manual step a clone depends on.
STEP="rendering the device configs"
say "rendering the device configs from clab/gen-configs.py"
( set -a; . ./.env; set +a; python3 clab/gen-configs.py ) | sed 's/^/  /'

STEP="deploying the routers"
say "deploying the routers"

clab() {   # clab <extra containerlab args...>
  ( cd clab && docker run --rm --privileged --network host --pid host \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$PWD:$PWD" -w "$PWD" \
      --env-file ../.env \
      "${CLAB_IMAGE:-ghcr.io/srl-labs/clab:0.79.0}" \
      containerlab deploy -t topo.yml "$@" )
}

# "Is srl1 running?" is not the same question as "does this lab have a
# topology?", and the difference is not academic. containerlab builds the
# veth pairs between nodes at deploy time; a Docker Desktop restart brings
# every container back through its restart policy and does NOT rebuild
# them. The nodes come up configured, healthy, and wired to nothing.
#
# This check skipped the deploy on exactly that state once. bootstrap ran
# to completion, printed its URLs, and left a fabric whose every interface
# was oper-down -- with IS-IS correctly configured on all of them, so
# golden_config reported "Already in the desired state" while there was no
# network at all. Ask about a link, not about a container.
links_up() {
  docker exec clab-selfheal-srl1 ip -br link 2>/dev/null |
    grep -q 'e1-1-0.*UP'
}

# Whether the routers were REPLACED matters to the proxies, which is why
# this is recorded rather than just done. See the restart below.
DEVICES_REPLACED=0
if ! docker network inspect clab-selfheal >/dev/null 2>&1 ||
   [ -z "$(docker ps -q -f name=clab-selfheal-srl1)" ]; then
  clab
  DEVICES_REPLACED=1
elif ! links_up; then
  echo "nodes are running but their links are gone (a host restart does"
  echo "this) — reconfiguring the topology"
  clab --reconfigure
  DEVICES_REPLACED=1
else
  echo "already deployed and wired, skipping"
fi

# --- 2. the stack ---------------------------------------------------------
STEP="building and starting the stack"
say "building and starting the stack"
docker compose up -d --build

STEP="waiting for the stack to report healthy"
say "waiting for the stack to report healthy"
# es-init and kibana-init are one-shot: compose already ordered everything
# behind them, so by the time this returns, the index templates, ILM
# policies, Elasticsearch users and Kibana data views all exist.
#
# Fifteen minutes, not five. On a first run NetBox applies its entire
# migration history to an empty database, which on a laptop takes longer
# than the old timeout -- so the loop gave up, the script carried on, and
# the NetBox seed then failed against a database that was still migrating.
# It also now says what it is waiting for, because a silent five-minute
# wait is indistinguishable from a hang.
for i in $(seq 1 90); do
  waiting=$(docker compose ps --format '{{.Name}} {{.Status}}' |
            grep "health: starting" | awk '{print $1}' | tr '\n' ' ')
  [ -z "$waiting" ] && break
  [ $((i % 6)) = 0 ] && echo "  still starting: $waiting"
  sleep 10
done
docker compose ps --format '{{.Name}}\t{{.Status}}'

# --- 2b. the master's own returner ----------------------------------------
# salt/states/_returners/elasticsearch.py is a patched copy of the upstream
# returner. `salt '*' saltutil.sync_all` pushes custom code to MINIONS; a
# master-side event_return runs on the master and loads from the master's
# own extension_modules, which only the runner below populates.
#
# Miss this and the failure is silent and total: the master keeps using the
# unpatched returner, every event raises inside it, not one Salt event ever
# reaches Elasticsearch, and the Grafana rule -- which counts events --
# reports the network healthy for ever. The whole detection path is dead
# and every service says it is fine.
STEP="syncing the master's returner and restarting it"
say "syncing the master's returner and restarting it"
docker exec salt-master salt-run saltutil.sync_returners 2>&1 | grep -E "returners\." || true
docker compose restart salt-master >/dev/null
for _ in $(seq 1 30); do
  docker compose ps salt-master --format '{{.Status}}' | grep -q healthy && break
  sleep 5
done

# --- 3. Salt: sync the custom code ---------------------------------------
# Without this the beacons do not exist on the minions, so nothing is ever
# detected, and the failure is silent: the proxies are up, the master is
# healthy, and the network is simply never watched.
STEP="syncing beacons, modules and states to the proxy minions"
say "syncing beacons, modules and states to the proxy minions"

# A proxy minion holds an open session to its device. `containerlab
# --reconfigure` does not restart a container, it REPLACES it, so every
# proxy is left talking to something that no longer exists -- and it does
# not notice, because nothing asks it to. It answers the master, reports
# healthy, and returns "Minion did not return" for every device call.
#
# This is what a woken-up laptop looks like from inside: the four routers
# are up, their veth pairs are gone, and once those are rebuilt the
# proxies still cannot reach anything. Six checks fail and only the first
# one names the cause. Diagnosed once by hand; now it is part of the step.
if [ "$DEVICES_REPLACED" = 1 ]; then
  echo "  the routers were replaced — restarting the proxies so they"
  echo "  reconnect to the new containers"
  docker compose restart salt-proxy-srl1 salt-proxy-srl2 salt-proxy-srl3 >/dev/null
fi

# Wait for all three to answer, not merely for the command to exit. With
# one proxy still down, `salt 'srl*' test.ping` prints two successes and
# returns non-zero, and the old loop treated that as "keep waiting" only
# by accident.
PROXIES=0
for _ in $(seq 1 40); do
  PROXIES=$(docker exec salt-master salt 'srl*' test.ping --out=json 2>/dev/null |
            grep -c 'true' || true)
  [ "${PROXIES:-0}" -ge 3 ] && break
  sleep 5
done
if [ "${PROXIES:-0}" -lt 3 ]; then
  echo "only ${PROXIES:-0} of 3 proxy minions answer after 200s." >&2
  echo "Nothing below this can work. Look at one of them:" >&2
  echo "  docker logs salt-proxy-srl1 | tail -40" >&2
  exit 1
fi
echo "  $PROXIES of 3 proxy minions answering"
# Silence them BEFORE syncing the code that makes them work, not after.
# The first attempt at this put the disable after sync_all, and it did not
# take: three proxies busy syncing every module do not answer promptly,
# `salt 'srl*' beacons.disable` returned "Minion did not return" for some
# of them, and the output was sent to /dev/null. So the beacons kept
# watching, and the reactor still converged golden_config on all three
# before bootstrap got there --
#
#   14:44:58  fault.detected  bgp_session_down   (after the "disable")
#   14:45:50  change.applied  salt-reactor/config_drift  golden_config
#
# -- which is a quieter version of exactly the bug it was meant to fix, and
# invisible for exactly the same reason: a step that cannot report failure.
# It now confirms that every minion said yes.
silence_beacons() {
  for attempt in 1 2 3; do
    got=$(docker exec salt-master salt 'srl*' beacons.disable --out=json 2>/dev/null |
          grep -c '"result": true' || true)
    [ "${got:-0}" -ge 3 ] && { echo "  beacons silenced on 3 of 3"; return 0; }
    echo "  only ${got:-0} of 3 minions confirmed the silence, retrying"
    sleep 10
  done
  echo "could not silence the beacons on all three proxies." >&2
  echo "Provisioning would be counted against each device's change budget." >&2
  return 1
}
echo "  silencing the beacons until the devices match intent"
silence_beacons

docker exec salt-master salt 'srl*' saltutil.sync_all
docker exec salt-master salt 'srl*' saltutil.refresh_pillar

# The beacons start watching the moment they are synced -- which is before
# NetBox has been seeded and before any device has been converged. That
# ordering produced a race the automation won: NetBox filled up at step 4,
# every beacon immediately saw "this device does not match the source of
# truth", and the drift reactor converged all three routers itself. By the
# time step 4b ran, there was nothing left to do, so bootstrap left no
# audit record at all.
#
# It worked. It also spent the change budget doing it: three unattended
# changes to srl3 inside two minutes, which is the per-device ceiling. The
# first real fault injected afterwards was correctly refused --
#
#   [!] BLOCKED   circuit breaker: 3 changes to srl3 in the last hour
#
# -- and a freshly built lab was rate-limited out of its own demo for an
# hour. The ceiling was right. The provisioning should not have been
# counted against it.
#
# A maintenance freeze is the wrong instrument: by design it outranks the
# override, so bootstrap could not converge through it. What is actually
# wanted is narrower and more honest -- nothing watches until there is
# something worth watching. Re-armed at the end of step 4b, and by the
# trap above if we never get there. (The disable itself happens above,
# before sync_all, so that the window is as narrow as it can be.)

# --- 4. NetBox ------------------------------------------------------------
STEP="seeding NetBox"
say "seeding NetBox"
./scripts/seed-netbox.sh

# --- 4b. converge the devices to the source of truth ----------------------
# Freshly deployed routers have none of NetBox's intent on them, so all
# three drift at once -- and the blast radius limit correctly refuses the
# third, because "every device in the fleet needs changing right now" is
# indistinguishable from a systemic mistake. It is only distinguishable by
# a human saying so.
#
# So initial provisioning is done deliberately here, with an override that
# skips the two ceilings and writes a change.override record naming who did
# it and why. A limit quietly set high enough never to trip would have been
# the easy answer and a much worse one.
# Retried once: a proxy can answer test.ping before it has finished
# opening its device session, and the first push then fails from inside the
# NAPALM driver. Converging is idempotent, so a second attempt costs
# nothing and turns a startup race into a non-event.
converge() {   # converge <device> <state>
  for attempt in 1 2; do
    out=$(docker exec salt-master salt "$1" state.apply "$2" \
      pillar='{"actor":"bootstrap","actor_type":"human","override":"initial provisioning"}' 2>&1)
    if printf '%s' "$out" | grep -q "Failed:    0"; then
      printf '%s' "$out" | grep -E "Succeeded|Comment" | head -2
      return 0
    fi
    [ "$attempt" = 1 ] && { echo "  $1: first attempt failed, retrying in 15s"; sleep 15; }
  done
  # Returns non-zero, rather than ending on a grep whose exit status
  # reports whether it matched. A step that cannot fail cannot be trusted
  # to have run.
  echo "  $1: $2 failed twice" >&2
  printf '%s' "$out" | grep -E "Succeeded|Failed|Comment" | head -3 >&2
  return 1
}

STEP="converging the devices to their source of truth"
# Open the provisioning window.
#
# audit.change_allowed() honours an `override` only while salt://.provisioning
# exists on the master. That is the one thing a salt-api caller cannot
# produce -- pillar passed as a kwarg merges over the master's, so an
# override asserted in pillar was authorising itself. Initial provisioning
# is the only legitimate override there is, it lasts about a minute, and it
# now looks like one from the outside: a window that opens, is used, and
# closes.
# Written on the HOST, not in the container: salt/states is mounted at
# /srv/salt read-only, so the master cannot create anything there --
# "cannot create /srv/salt/.provisioning: Read-only file system" is how
# the first attempt died, four minutes into a bootstrap.
#
# The host is also the better place for it. The property that matters is
# that a salt-api caller cannot produce this file, and a caller reaching
# the API has no way to write to this filesystem at all.
printf '%s\n' "opened by bootstrap.sh at $(date -u +%FT%TZ)" > salt/states/provisioning.window

# Silence them again, because the first silence may no longer hold.
#
# `beacons.disable` is a runtime option on the minion, not a file: a proxy
# that restarts comes back with its beacons ENABLED. Between the first
# silence and here lies the NetBox seed and the discovery pass, which take
# minutes -- long enough for a health check, Docker, or a person to bounce
# a proxy. It has happened: a hand-restarted proxy came back watching, saw
# three freshly-replaced routers that matched nothing in NetBox, and the
# reactor converged all of them before bootstrap reached this line. The
# provisioning was then charged to every device's hourly budget, and the
# lab was rate-limited out of its own demo.
#
# Re-silencing is idempotent and costs one round trip.
silence_beacons

say "converging the devices to their source of truth"

# Order matters, and so does what is in this list. A freshly deployed
# router carries its bootstrap config and nothing else: management, the
# loopback, the physical interfaces. The protocol layer is deliberately NOT
# baked in -- that is what ZTP means, and it is why golden_config exists.
#
# This step used to converge only the interface DESCRIPTIONS, which meant a
# clean `./scripts/bootstrap.sh` finished, printed its URLs, and left a
# fabric with no IS-IS adjacencies and no BGP sessions at all. Every
# service reported healthy. The first thing anyone cloning this repo would
# have seen is a lab that looks up and has no network.
#
# golden_config first (IS-IS, BFD, iBGP, eBGP), then bgp_policy (what the
# border router announces and accepts), then the descriptions.
for dev in srl1 srl2 srl3; do
  converge "$dev" golden_config
done

# Run on every device: the state reads NetBox and decides for itself
# whether the device has a bgp context. srl1 and srl2 answer "not in
# scope", which is the correct answer and a cheap one.
for dev in srl1 srl2 srl3; do
  converge "$dev" bgp_policy
done

# All three from NetBox. srl3 was converged from pillar/YAML here, left
# over from when it was the demonstration of a second source of truth --
# but its drift beacon watches NetBox, so bootstrap was writing pillar's
# descriptions and the beacon was immediately reporting them as drift.
# A fresh install disagreed with itself within twenty seconds.
for dev in srl1 srl2 srl3; do
  converge "$dev" sync_from_netbox
done

# Close it again the moment provisioning is done. An override window left
# open is the same hole with a longer fuse.
rm -f salt/states/provisioning.window

# Intent exists and the devices match it. Now it is worth watching them.
say "arming the beacons"
docker exec salt-master salt 'srl*' beacons.enable

# --- 5. n8n ---------------------------------------------------------------
# import leaves a workflow inactive, publish needs a restart to take effect.
#
# Both of those `|| true`s used to hide a real failure. n8n opens its port
# and passes /healthz before it has a schema -- on a fresh volume, five
# hundred migrations run AFTER compose calls it healthy -- so this step
# imported into a database that did not exist yet, swallowed the error,
# and left n8n with no workflows at all. Everything downstream stayed
# green. The only evidence was a line in n8n's own log, minutes later,
# during a recording:
#
#   Received request for unknown webhook: "POST fault" is not registered
#
# So: wait for the database, not the port; then import, then CHECK, and
# retry rather than assume. An import that cannot be confirmed is a
# failure, and this step now says so instead of moving on.
STEP="importing the workflows"
say "importing the workflows"

echo "  waiting for n8n's database (the port has been open for a while)"
for _ in $(seq 1 60); do
  docker exec n8n n8n list:workflow >/dev/null 2>&1 && break
  sleep 5
done

import_workflows() {
  for f in fault-remediation heal-explainer; do
    docker cp "n8n/$f-workflow.json" "n8n:/tmp/$f.json" >/dev/null
    docker exec n8n n8n import:workflow --input="/tmp/$f.json" 2>&1 |
      grep -vi "deactivating" || true
  done
}

for attempt in 1 2 3; do
  import_workflows
  COUNT=$(docker exec n8n n8n list:workflow 2>/dev/null | grep -c '|' || true)
  [ "$COUNT" -ge 2 ] && break
  echo "  n8n reports $COUNT of 2 workflows -- attempt $attempt, retrying in 20s"
  sleep 20
done

if [ "${COUNT:-0}" -lt 2 ]; then
  echo "n8n has $COUNT of 2 workflows after three attempts." >&2
  echo "Nothing will act on a detected fault until this is fixed:" >&2
  echo "  docker logs n8n | tail -40" >&2
  exit 1
fi

docker exec n8n n8n list:workflow 2>/dev/null | while IFS='|' read -r id _; do
  [ -n "$id" ] && docker exec n8n n8n publish:workflow --id="$id" >/dev/null 2>&1 || true
done
docker compose restart n8n >/dev/null

# --- 6. did any of that actually connect? --------------------------------
# Up to here every step reported on itself. This asks the different
# question: whether the services are wired to each other. It is the only
# check in the file that can fail after every earlier step succeeded.
STEP="checking the lab"
say "checking that the pieces are actually connected"
if ./scripts/check-lab.sh; then
  :
else
  printf '\033[31mThe stack is up but incomplete -- see the failures above.\033[0m\n'
  trap - EXIT
  exit 1
fi

trap - EXIT
cat <<URLS

  NetBox     http://${BIND_ADDR:-127.0.0.1}:8000   ${NETBOX_SUPERUSER_NAME:-admin} / see .env
  Kibana     http://${BIND_ADDR:-127.0.0.1}:5601   elastic / see .env
  Grafana    http://${BIND_ADDR:-127.0.0.1}:3000   ${GRAFANA_ADMIN_USER:-admin} / see .env
  n8n        http://${BIND_ADDR:-127.0.0.1}:5678   create the owner account on first visit
  salt-api   http://${BIND_ADDR:-127.0.0.1}:8001

Break something and watch it heal:

  ./scripts/break.sh interface srl3

Follow the audit trail:

  docker exec salt-master salt srl3 audit.history device=srl3

URLS
