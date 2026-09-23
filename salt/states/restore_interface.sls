# Remediation #1 — re-enable an interface that was administratively
# disabled. Parameters arrive as pillar overrides from salt-api
# (interface), so the LLM chooses WHICH interface but never what the
# config text says: that lives in templates/restore_interface.jinja and
# is reviewed by a human like any other file in this repo.
#
# audited.config, not netconfig.managed: the change is gated by the
# maintenance freeze and the per-device rate limit, recorded to the audit
# trail with its diff, and committed on the device under a message naming
# the trace id and the actor. See _states/audited.py.
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
{%- set iface = pillar.get('interface') %}
{%- set monitored = salt['pillar.get']('monitored_interfaces:' ~ grains['id'], []) %}

{%- if iface and iface in monitored %}
restore-{{ iface }}:
  audited.config:
    - template_name: salt://templates/restore_interface.jinja
    - context:
        interface: {{ iface }}
    - state_name: restore_interface
    - fault: interface_admin_down
    - interface: {{ iface }}
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    # Break glass: skips the rate limit and the blast radius, and
    # writes a change.override record saying who did it and why.
    - override: {{ override }}
    {%- endif %}
    # The template's job is to write admin-state enable. That is not the
    # point of the change: the point is an interface that carries traffic,
    # and an interface can be admin-enabled and still operationally down.
    # The commit is made with the device's own 120s revert timer armed and
    # is confirmed only if this passes.
    - verify:
        fun: verify.interface_up
        kwargs:
          name: {{ iface }}
{%- else %}
# Not just "is it set" any more: the interface must be one this device
# actually monitors. Otherwise a caller could name any interface on the
# box -- including an uplink nobody asked about -- and have it enabled.
restore-interface-not-monitored:
  test.fail_without_changes:
    - name: "restore_interface: '{{ iface }}' is not a monitored interface on {{ grains['id'] }}"
{%- endif %}
