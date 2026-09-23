#!/usr/bin/env sh
# Back up everything that cannot be rebuilt from this repository.
#
# What is NOT backed up, on purpose: the containerlab devices and the
# Elasticsearch indices that only hold telemetry. Those are reproducible.
# What is backed up is state with no other copy -- the audit trail above
# all, because a change record that exists on one disk is not a record.
#
#   ./scripts/backup.sh [destination-dir]
set -eu
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env — run ./scripts/gen-secrets.sh first" >&2; exit 1; }
. ./.env

# Docker names volumes <project>_<volume>, and the project is the directory
# name unless COMPOSE_PROJECT_NAME says otherwise. Hardcoding "selfheal-lab"
# meant this script silently backed up nothing the moment someone cloned the
# repo into a differently named directory -- which is exactly what a fresh
# clone does.
PROJECT=${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}

DEST=${1:-./backups}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# Elasticsearch rejects an uppercase snapshot name, and the directory name
# above is deliberately not lowercased: the ISO stamp stays readable on
# disk, the snapshot gets its own lowercase form.
SNAP_NAME=$(printf '%s' "$STAMP" | tr 'A-Z' 'a-z')
OUT="$DEST/$STAMP"
mkdir -p "$OUT"
echo "backing up to $OUT"

es() {
  docker exec elasticsearch curl -sf -u "elastic:$ELASTIC_PASSWORD" "$@"
}

# --- 1. Elasticsearch snapshot -------------------------------------------
# The audit trail and the event history. A snapshot, not an export: it is
# consistent, incremental, and restorable into a cluster of a different size.
echo "--- elasticsearch snapshot ---"
# Checked explicitly rather than with `cmd && echo`. In POSIX sh, `set -e`
# does not fire for the left-hand side of an &&, so the first version of
# this reported a successful backup while taking no snapshot at all -- the
# single worst failure mode a backup script can have.
if ! es "http://localhost:9200/_snapshot/selfheal" >/dev/null 2>&1; then
  echo "FATAL: the snapshot repository 'selfheal' is not registered." >&2
  echo "       Elasticsearch needs path.repo=/snapshots, which only takes" >&2
  echo "       effect when the container is recreated:" >&2
  echo "         docker compose up -d --force-recreate elasticsearch es-init" >&2
  exit 1
fi

# curl runs inside the elasticsearch container, so its output has to come
# back over stdout — writing it to a file would put the file in there.
# -f is dropped deliberately: on failure the body IS the diagnosis, and
# curl -f throws it away.
SNAP=$(docker exec elasticsearch curl -s -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "http://localhost:9200/_snapshot/selfheal/$SNAP_NAME?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d '{"indices":"napalm-*,docker-stats,.ds-napalm-audit-*,.ds-lab-logs-*","include_global_state":false,"ignore_unavailable":true}')
STATE=$(printf '%s' "$SNAP" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('snapshot',{}).get('state','NONE'))" \
  2>/dev/null || echo UNPARSEABLE)
if [ "$STATE" != "SUCCESS" ]; then
  echo "FATAL: snapshot state is $STATE, not SUCCESS" >&2
  printf '%s\n' "$SNAP" >&2
  exit 1
fi
SHARDS=$(printf '%s' "$SNAP" | python3 -c \
  "import json,sys; s=json.load(sys.stdin)['snapshot']['shards']; print(f\"{s['successful']}/{s['total']} shards\")" 2>/dev/null || echo "")
echo "snapshot $SNAP_NAME: $STATE, $SHARDS"

docker run --rm -v ${PROJECT}_es-snapshots:/s -v "$(cd "$OUT" && pwd)":/out \
  alpine tar czf /out/elasticsearch-snapshots.tgz -C /s . 2>/dev/null
echo "snapshot repository archived"

# --- 2. NetBox ------------------------------------------------------------
# The source of truth. pg_dump, not a volume tar: a Postgres data directory
# copied while the server is running is not a backup.
echo "--- netbox ---"
docker exec netbox-postgres pg_dump -U netbox -Fc netbox > "$OUT/netbox.dump"
echo "netbox database dumped ($(wc -c < "$OUT/netbox.dump") bytes)"

# --- 3. n8n ---------------------------------------------------------------
# Workflows and credentials separately, and the volume as well. The
# credential export is encrypted with N8N_ENCRYPTION_KEY, so it is useless
# without .env -- which is why .env is in the manifest below and must be
# kept somewhere this archive is not.
echo "--- n8n ---"
docker exec n8n n8n export:workflow --all --output=/tmp/workflows.json >/dev/null 2>&1 \
  && docker cp n8n:/tmp/workflows.json "$OUT/n8n-workflows.json" >/dev/null
docker exec n8n n8n export:credentials --all --output=/tmp/creds.json >/dev/null 2>&1 \
  && docker cp n8n:/tmp/creds.json "$OUT/n8n-credentials-encrypted.json" >/dev/null 2>&1 || true
docker run --rm -v ${PROJECT}_n8n-data:/d -v "$(cd "$OUT" && pwd)":/out \
  alpine tar czf /out/n8n-data.tgz -C /d . 2>/dev/null
echo "n8n workflows, credentials and volume archived"

# --- 4. Salt PKI ----------------------------------------------------------
# Losing these means every proxy is rejected as an impostor on next start.
echo "--- salt keys ---"
for v in salt-keys salt-pki-srl1 salt-pki-srl2 salt-pki-srl3; do
  docker run --rm -v "${PROJECT}_$v:/d" -v "$(cd "$OUT" && pwd)":/out \
    alpine tar czf "/out/$v.tgz" -C /d . 2>/dev/null
done
echo "salt PKI archived"

# --- 5. Grafana -----------------------------------------------------------
# Only what provisioning cannot rebuild: alert state history, silences,
# annotations. Everything else comes from ./grafana in this repo.
docker run --rm -v ${PROJECT}_grafana-data:/d -v "$(cd "$OUT" && pwd)":/out \
  alpine tar czf /out/grafana-data.tgz -C /d . 2>/dev/null

cat > "$OUT/MANIFEST.txt" <<MANIFEST
selfheal-lab backup $STAMP

  elasticsearch-snapshots.tgz    audit trail, events, logs, telemetry
  netbox.dump                    source of truth (pg_dump -Fc)
  n8n-workflows.json             workflows, plain JSON
  n8n-credentials-encrypted.json credentials, encrypted with N8N_ENCRYPTION_KEY
  n8n-data.tgz                   n8n volume (sqlite: executions, settings)
  salt-keys.tgz                  master PKI
  salt-pki-srl{1,2,3}.tgz        proxy minion keypairs
  grafana-data.tgz               alert state, silences, annotations

NOT in this archive, and required to restore it:
  .env                           every secret, including N8N_ENCRYPTION_KEY
                                 and ELASTIC_PASSWORD. Keep it somewhere
                                 this archive is not. Without it the n8n
                                 credential export cannot be decrypted and
                                 Elasticsearch cannot be reached.

Restore: ./scripts/restore.sh $OUT
MANIFEST

echo
echo "done: $OUT"
du -sh "$OUT"
echo
echo "Reminder: .env is deliberately not in this archive. Store it separately."
