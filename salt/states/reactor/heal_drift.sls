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
{#- Validate before acting on anything the event carried.

    A reactor SLS runs with master privileges and no eauth, and both of
    the values below come straight off the event bus. `state` becomes the
    state file that gets applied and `id` becomes the target. With
    auto_accept on -- which this lab has, deliberately, so a rebuilt
    proxy does not need a key accepted by hand -- anything that can reach
    the master's 4505/4506 can publish an event, and the clab bridge the
    routers sit on can reach them.

    So: the state must be one of the two this reactor exists for, and the
    target must be the minion the event tag says it came from. Neither
    check costs anything, and without them a compromised device could ask
    the master to apply any state file in file_roots to any minion.

    A rejected event is dropped silently here because a reactor has no
    other channel; the beacon that fired it will fire again, and
    check-lab.sh notices a fabric that stops converging. -#}
{%- set ALLOWED_STATES = ['sync_from_netbox', 'sync_from_pillar'] %}
{%- set ev_state = data.get('state', '') %}
{%- set ev_id = data.get('id', '') %}
{#- tag looks like salt/beacon/<minion>/<beacon>/<sub> -#}
{%- set tag_minion = tag.split('/')[2] if tag.split('/') | length > 2 else '' %}
{%- if ev_state in ALLOWED_STATES and ev_id and ev_id == tag_minion %}
heal-{{ ev_id }}-{{ ev_state }}:
  local.state.apply:
    - tgt: {{ ev_id }}
    - arg:
      - {{ ev_state }}
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
{%- endif %}
