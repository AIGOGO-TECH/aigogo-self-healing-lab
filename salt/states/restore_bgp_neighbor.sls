# Remediation #3 — bring back a BGP session that was administratively
# shut. As with the other remediations, the caller chooses WHICH peer,
# and the peer must already be declared in pillar — an LLM cannot invent
# a neighbour address and have Salt configure it.
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
{%- set peer = pillar.get('peer') or pillar.get('interface') %}
{%- set declared = salt['pillar.get']('bgp_neighbors:' ~ grains['id'], {}) %}

{%- if peer and peer in declared %}
restore-bgp-{{ peer }}:
  audited.config:
    - template_name: salt://templates/restore_bgp_neighbor.jinja
    - context:
        peer: {{ peer }}
    - state_name: restore_bgp_neighbor
    - fault: bgp_session_down
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    # Break glass: skips the rate limit and the blast radius, and
    # writes a change.override record saying who did it and why.
    - override: {{ override }}
    {%- endif %}
    # Un-shutting a neighbour is not the same as a session that comes up.
    # BGP is given longer than the others because leaving Connect legitimately
    # takes tens of seconds.
    - verify:
        fun: verify.bgp_established
        kwargs:
          peer: {{ peer }}
{%- else %}
restore-bgp-unknown-peer:
  test.fail_without_changes:
    - name: "restore_bgp_neighbor: '{{ peer }}' is not a declared neighbour on {{ grains['id'] }}"
{%- endif %}
