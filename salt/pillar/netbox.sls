# NetBox connection info for the sync_from_netbox state and the config_drift
# beacon.
#
# Pillar is Jinja-rendered on the master, so the token is read from the
# master's environment (set from .env by docker-compose) rather than
# committed here. Pillar is also the right place for it: it is delivered
# only to the minions that match in top.sls, and it never appears in a
# state file, a job argument, or an event payload.
netbox:
  url: {{ salt['environ.get']('NETBOX_URL', 'http://netbox:8080') }}
  token: {{ salt['environ.get']('NETBOX_API_TOKEN') }}
