#!/usr/bin/env sh
# Restore from a backup made by scripts/backup.sh.
#
#   ./scripts/restore.sh backups/20260915T051200Z
#
# Deliberately not automatic end-to-end: restoring Elasticsearch over a
# running cluster and re-keying Salt are both things that should be typed
# on purpose. This does the parts that are safe and prints the parts that
# are not.
set -eu
cd "$(dirname "$0")/.."
SRC=${1:?usage: ./scripts/restore.sh <backup-dir>}
[ -f "$SRC/MANIFEST.txt" ] || { echo "$SRC does not look like a backup" >&2; exit 1; }
[ -f .env ] || { echo "no .env — restore it first, nothing else will work" >&2; exit 1; }
. ./.env

# Docker names volumes <project>_<volume>, and the project is the directory
# name unless COMPOSE_PROJECT_NAME says otherwise. Hardcoding "selfheal-lab"
# meant this script silently backed up nothing the moment someone cloned the
# repo into a differently named directory -- which is exactly what a fresh
# clone does.
PROJECT=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}

echo "restoring from $SRC"
cat "$SRC/MANIFEST.txt"
printf '\nThis will overwrite the running NetBox database and n8n volume. Continue? [y/N] '
read -r reply
[ "$reply" = "y" ] || exit 1

echo "--- netbox ---"
docker exec -i netbox-postgres pg_restore -U netbox -d netbox --clean --if-exists \
  < "$SRC/netbox.dump"

echo "--- n8n ---"
docker compose stop n8n >/dev/null
docker run --rm -v ${PROJECT}_n8n-data:/d -v "$(cd "$SRC" && pwd)":/in \
  alpine sh -c 'rm -rf /d/* && tar xzf /in/n8n-data.tgz -C /d'
docker compose start n8n >/dev/null

echo "--- salt PKI ---"
for v in salt-keys salt-pki-srl1 salt-pki-srl2 salt-pki-srl3; do
  [ -f "$SRC/$v.tgz" ] || continue
  docker run --rm -v "${PROJECT}_$v:/d" -v "$(cd "$SRC" && pwd)":/in \
    alpine sh -c "rm -rf /d/* && tar xzf /in/$v.tgz -C /d"
done

cat <<MANUAL

Done, except for Elasticsearch, which is deliberately left to you.

  1. Put the snapshot repository back:
       docker run --rm -v ${PROJECT}_es-snapshots:/s -v "$(cd "$SRC" && pwd)":/in \\
         alpine tar xzf /in/elasticsearch-snapshots.tgz -C /s

  2. List what is in it:
       docker exec elasticsearch curl -u elastic:\$ELASTIC_PASSWORD \\
         http://localhost:9200/_snapshot/selfheal/_all

  3. Restore one. Indices must be closed or absent first, which is why this
     is not scripted — restoring the audit trail over a live one is not
     something to do by accident:
       docker exec elasticsearch curl -u elastic:\$ELASTIC_PASSWORD -X POST \\
         http://localhost:9200/_snapshot/selfheal/<name>/_restore

Then restart the proxies so they re-present their restored keys:

  docker compose restart salt-proxy-srl1 salt-proxy-srl2 salt-proxy-srl3

MANUAL
