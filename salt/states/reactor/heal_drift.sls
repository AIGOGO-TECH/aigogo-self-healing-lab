# Fired by config_drift.py or config_drift_pillar.py (states/_beacons/)
# whenever a device's running config no longer matches its source of
# truth. data['id'] is the minion, data['state'] is which state to apply —
# sync_from_netbox or sync_from_pillar — both idempotent.
#
# The trace id comes from the beacon that noticed the drift, so the reactor
# path and the n8n path write into the same correlated audit trail rather
# than two unrelated ones. actor is set explicitly: a change nobody chose
# must not be able to look like one somebody did.
#
# Rate limiting is deliberately NOT here. A reactor SLS is stateless and
# re-rendered per event, so any counter written here would be wrong. The
# ceiling lives in audit.change_allowed(), which the state itself calls —
# which also means it covers the n8n path with the same rule and the same
# pillar setting.
heal-{{ data['id'] }}-{{ data['state'] }}:
  local.state.apply:
    - tgt: {{ data['id'] }}
    - arg:
      - {{ data['state'] }}
    - kwarg:
        # Queue instead of refusing. There are now three sources of truth
        # watching one device -- interface descriptions from NetBox, the
        # protocol layer from the fabric plan, and BGP policy from a NetBox
        # config context -- and when two drift at once their beacons fire
        # within a second of each other. Salt will not run two state.apply
        # jobs on one minion, so without this the second is simply dropped:
        # the protocol layer converged and the BGP policy silently did not,
        # which is a worse outcome than either failing loudly.
        queue: True
        pillar:
          trace_id: {{ data.get('trace_id', '') }}
          actor: salt-reactor/config_drift
