#!/usr/bin/env sh
# Generate a .env with random secrets. Refuses to overwrite an existing one,
# because rotating N8N_ENCRYPTION_KEY orphans every credential n8n has stored.
set -eu
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists -- refusing to overwrite." >&2
  echo "Delete it deliberately if you really mean to rotate every secret." >&2
  exit 1
fi

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-32}"; }
# NetBox validates its API token as 40 hex characters.
hex()  { LC_ALL=C tr -dc 'a-f0-9'   < /dev/urandom | head -c "${1:-40}"; }

sed \
  -e "s|^ELASTIC_PASSWORD=.*|ELASTIC_PASSWORD=$(rand 32)|" \
  -e "s|^KIBANA_SYSTEM_PASSWORD=.*|KIBANA_SYSTEM_PASSWORD=$(rand 32)|" \
  -e "s|^KIBANA_ENCRYPTION_KEY=.*|KIBANA_ENCRYPTION_KEY=$(rand 48)|" \
  -e "s|^SALT_ES_PASSWORD=.*|SALT_ES_PASSWORD=$(rand 32)|" \
  -e "s|^GRAFANA_ES_PASSWORD=.*|GRAFANA_ES_PASSWORD=$(rand 32)|" \
  -e "s|^N8N_ES_PASSWORD=.*|N8N_ES_PASSWORD=$(rand 32)|" \
  -e "s|^STATS_ES_PASSWORD=.*|STATS_ES_PASSWORD=$(rand 32)|" \
  -e "s|^LOGS_ES_PASSWORD=.*|LOGS_ES_PASSWORD=$(rand 32)|" \
  -e "s|^WATCHDOG_ES_PASSWORD=.*|WATCHDOG_ES_PASSWORD=$(rand 32)|" \
  -e "s|^PUSH_DETECT_ES_PASSWORD=.*|PUSH_DETECT_ES_PASSWORD=$(rand 32)|" \
  -e "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$(rand 24)|" \
  -e "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=$(rand 48)|" \
  -e "s|^NETBOX_DB_PASSWORD=.*|NETBOX_DB_PASSWORD=$(rand 32)|" \
  -e "s|^NETBOX_SECRET_KEY=.*|NETBOX_SECRET_KEY=$(rand 50)|" \
  -e "s|^NETBOX_SUPERUSER_PASSWORD=.*|NETBOX_SUPERUSER_PASSWORD=$(rand 24)|" \
  -e "s|^NETBOX_API_TOKEN=.*|NETBOX_API_TOKEN=$(hex 40)|" \
  -e "s|^SALT_API_SECRET=.*|SALT_API_SECRET=$(rand 48)|" \
  -e "s|^SRL_PASSWORD=.*|SRL_PASSWORD=NokiaSrl1!|" \
  -e "s|^ISIS_AUTH_KEY=.*|ISIS_AUTH_KEY=$(rand 24)|" \
  .env.example > .env

# n8n reads its Elasticsearch credential as a pre-built header, so that no
# secret has to live inside an exported workflow JSON.
N8N_ES_PASSWORD=$(grep '^N8N_ES_PASSWORD=' .env | cut -d= -f2-)
HEADER="Basic $(printf 'n8n_agent:%s' "$N8N_ES_PASSWORD" | base64 | tr -d '\n')"
# Quoted: the value contains a space, and scripts/seed-netbox.sh sources
# .env with the shell. docker compose strips the quotes itself.
sed -i.bak "s|^N8N_ES_AUTH_HEADER=.*|N8N_ES_AUTH_HEADER=\"$HEADER\"|" .env && rm -f .env.bak

chmod 600 .env
echo "Wrote .env (mode 600)."
echo
echo "SRL_PASSWORD is left at Nokia's documented default, because the"
echo "containerlab nodes are built with it. Change it on the devices first"
echo "if you change it here."
