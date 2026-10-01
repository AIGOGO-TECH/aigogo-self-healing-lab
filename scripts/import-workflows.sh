#!/usr/bin/env sh
# Push the workflow JSON in this repository into n8n's database.
#
#   ./scripts/import-workflows.sh
#
# n8n does not run the files in n8n/. It runs whatever was imported into its
# own database, and it keeps running that after the files change. So every
# edit to n8n/*.json is inert until this has run -- a prompt rewritten here,
# a threshold changed here, a new node added here all keep behaving exactly
# as they did before, with no error and nothing in any log to say why.
#
# That is worth stating plainly because the symptom is not a failure. A
# circuit-breaker limit was raised in the JSON and the workflow went on
# refusing at the old number, with a reason string that read correctly and
# was simply out of date.
#
# bootstrap.sh does this as part of a full build. This exists for the much
# more common case: one file edited, nothing else to rebuild.
set -eu
cd "$(dirname "$0")/.."

docker exec n8n n8n list:workflow >/dev/null 2>&1 || {
  echo "n8n is not answering. Start it first: docker compose up -d n8n" >&2
  exit 1
}

for f in fault-remediation heal-explainer; do
  [ -f "n8n/$f-workflow.json" ] || continue
  docker cp "n8n/$f-workflow.json" "n8n:/tmp/$f.json" >/dev/null
  # "deactivating" is n8n telling you an import deactivates the workflow. It
  # is expected and it is published again below.
  docker exec n8n n8n import:workflow --input="/tmp/$f.json" 2>&1 \
    | grep -vi deactivating || true
done

# An imported workflow lands inactive, so its webhook is not registered and a
# fault reaches nothing. Publishing is what puts it back on the air.
docker exec n8n n8n list:workflow 2>/dev/null | while IFS='|' read -r id _; do
  [ -n "$id" ] && docker exec n8n n8n publish:workflow --id="$id" >/dev/null 2>&1 || true
done
docker compose restart n8n >/dev/null 2>&1

# n8n answers its port several seconds before it has registered the webhook,
# so returning here on a listening port would hand back a workflow that is
# not yet reachable.
waited=0
while [ "$waited" -lt 120 ]; do
  sleep 5
  waited=$((waited + 5))
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -X POST "http://${BIND_ADDR:-127.0.0.1}:5678/webhook/fault" \
    -H 'Content-Type: application/json' -d '{"probe":true}' 2>/dev/null || echo 000)
  case "$CODE" in 200|201|500) break ;; esac
done

case "${CODE:-000}" in
  200|201|500) echo "workflows imported and published; webhook answering after ${waited}s" ;;
  *) echo "workflows imported, but the webhook is not answering (HTTP ${CODE:-timeout})" >&2
     echo "  docker logs n8n | tail -40" >&2
     exit 1 ;;
esac
