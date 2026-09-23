# Source of truth #2 for srl3: pillar/YAML instead of NetBox's HTTP API
# (see sync_from_netbox.sls for the NetBox-backed version on srl1/srl2).
# Same napalm_srlinux_from_netbox.jinja template either way — only where
# the "interfaces" dict comes from changes.
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
{%- set interfaces = pillar.get('device_truth', {}).get('interfaces', {}) %}

{%- if interfaces %}
sync-interfaces-from-pillar:
  audited.config:
    - template_name: salt://napalm_srlinux_from_netbox.jinja
    - context:
        interfaces: {{ interfaces | tojson }}
    - state_name: sync_from_pillar
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
# Same reasoning as sync_from_netbox: an empty truth is not a truth.
sync-from-pillar-no-truth:
  test.fail_without_changes:
    - name: "sync_from_pillar: device_truth:interfaces is empty for {{ grains['id'] }} — refusing to converge against an empty source of truth"
{%- endif %}
