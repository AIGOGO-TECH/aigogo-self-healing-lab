#!/usr/bin/env sh
# Populate NetBox with the lab's sites, racks, tenancy, contacts, devices,
# interfaces, IPAM and cabling, then learn MAC/speed/duplex from the live
# devices. Idempotent: re-running reuses whatever already exists.
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env -- run ./scripts/gen-secrets.sh first" >&2; exit 1; }
. ./.env

# Run inside salt-master, for the same reason discover.py does below.
#
# This used to start a python:3.12-slim on the lab network and `pip install
# requests` at the top of every run. That needs PyPI, and the lab network
# has no route to it:
#
#   Failed to establish a new connection: [Errno 101] Network is unreachable
#   WARNING: Retrying (Retry(total=4, ...)) ... /simple/requests/
#
# It also meant bootstrap.sh could not run without internet, and seeded
# nothing when it failed -- leaving NetBox empty, which every drift beacon
# and bgp_policy then reads as "the source of truth says nothing".
#
# salt-master already has requests, is already on the right network, and is
# already the place the next step runs.
# The whole directory, not just the script: seed.py reads plan.json from
# beside itself, and the old throwaway container had netbox/ mounted whole.
run() {
  docker exec salt-master rm -rf /tmp/nb >/dev/null 2>&1 || true
  docker cp netbox salt-master:/tmp/nb >/dev/null
  docker exec -e "NETBOX_API_TOKEN=$NETBOX_API_TOKEN" \
              -e "NETBOX_URL=${NETBOX_URL:-http://netbox:8080}" \
              salt-master python3 "/tmp/nb/$1"
}

# NetBox applies SUPERUSER_API_TOKEN only when it first creates the
# superuser. On an existing database the token in .env is simply wrong, and
# every call below returns 403 "Invalid token" -- including the ones the
# config_drift beacon makes, where nobody is watching.
echo "--- reconciling the API token with .env ---"
docker exec -i \
  -e "NETBOX_API_TOKEN=$NETBOX_API_TOKEN" \
  -e "NETBOX_SUPERUSER_NAME=${NETBOX_SUPERUSER_NAME:-admin}" \
  netbox /opt/netbox/netbox/manage.py shell < netbox/ensure-token.py \
  | grep "netbox-token:"

echo
echo "--- seeding NetBox ---"
run seed.py
echo
echo "--- discovering live interface attributes ---"
# Run inside salt-master, not in a throwaway python container. This script
# has to talk to Salt, and the only place `salt` is on PATH is the master
# itself. In a python:3.12-slim it fell back to `docker exec`, which is not
# installed there and has no socket -- so this step had never actually run
# through bootstrap.sh.
docker cp netbox/discover.py salt-master:/tmp/discover.py >/dev/null
docker exec -e "NETBOX_API_TOKEN=$NETBOX_API_TOKEN" \
            -e "NETBOX_URL=${NETBOX_URL:-http://netbox:8080}" \
            salt-master python3 /tmp/discover.py
