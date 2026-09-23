# P3: pull this device's interface descriptions from NetBox and push them.
# NetBox is source-of-truth for *intent* (what an interface is for); the
# device is the source of truth for operational state. This state makes
# the device match NetBox, not the other way around.
#
# Reached by the drift reactor, which used to have no rate limit of any
# kind: a device that drifted and failed to converge was reconfigured
# every twenty seconds forever. audited.config applies the same hourly
# ceiling the n8n path has, from pillar/maintenance.sls.
{#- trace_id and actor arrive as pillar overrides on the salt-api call, so a
    change made through the n8n/LLM path is attributed to the model that chose
    it. The reactor's drift path passes neither and falls back to naming
    itself: an unattributed change must not be able to look like a human one.
    Inlined rather than included -- Jinja's include renders in its own scope
    and does not export set variables back to the caller. -#}
{%- set trace_id = pillar.get('trace_id', '') %}
{%- set actor = pillar.get('actor', 'salt-reactor') %}
{%- set actor_type = pillar.get('actor_type', 'automation') %}
{%- set override = pillar.get('override', '') %}
{%- set nb = salt['pillar.get']('netbox', {}) %}
{%- set response = salt['http.query'](
      nb.get('url', 'http://netbox:8080') ~ '/api/dcim/interfaces/?device=' ~ grains['id'],
      header_dict={'Authorization': 'Token ' ~ nb.get('token', '')},
      decode=True, decode_type='json', status=True
    ) %}
{%- set interfaces = response.get('dict', {}).get('results', []) %}

{%- if response.get('status', 0) == 200 and interfaces %}
sync-interfaces-from-netbox:
  audited.config:
    - template_name: salt://napalm_srlinux_from_netbox.jinja
    - context:
        interfaces:
          {%- for iface in interfaces %}
          {{ iface.name }}: "{{ iface.description }}"
          {%- endfor %}
    - state_name: sync_from_netbox
    - fault: config_drift
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    # Break glass: skips the rate limit and the blast radius, and
    # writes a change.override record saying who did it and why.
    - override: {{ override }}
    {%- endif %}
    # No outcome check, deliberately. For the other remediations the config
    # is a means and the network is the end, so the config converging is not
    # evidence the change worked. Here the config IS the end: the whole point
    # is that the device matches its source of truth. The thing to be
    # sceptical about is not whether the push worked, it is whether the
    # source of truth is right -- which is why the fleet-wide blast radius
    # limit in pillar/maintenance.sls matters more on this path than on any
    # other. One bad row in NetBox is a fault on every device at once.
{%- else %}
# NetBox unreachable or empty. Rendering an empty interface set here would
# push a config that blanks every description on the device -- the source
# of truth being down must never be read as "the truth is nothing".
sync-from-netbox-no-truth:
  test.fail_without_changes:
    - name: "sync_from_netbox: NetBox returned status {{ response.get('status', 'none') }} with {{ interfaces | length }} interfaces for {{ grains['id'] }} — refusing to converge against an empty source of truth"
{%- endif %}
