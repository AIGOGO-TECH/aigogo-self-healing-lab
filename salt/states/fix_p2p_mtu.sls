# Remediation #2 — put a P2P link's MTU back to the value both ends
# agreed on. The agreed value is NOT taken from the caller: it is looked
# up in pillar's p2p_links for this device, so an LLM (or anyone else)
# calling this state cannot smuggle in an arbitrary MTU.
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
{%- set links = salt['pillar.get']('p2p_links:' ~ grains['id'], {}) %}
{%- set agreed = links.get(iface, {}).get('mtu') %}

{%- if iface and agreed %}
fix-mtu-{{ iface }}:
  audited.config:
    - template_name: salt://templates/fix_p2p_mtu.jinja
    - context:
        interface: {{ iface }}
        mtu: {{ agreed }}
    - state_name: fix_p2p_mtu
    - fault: p2p_mtu_mismatch
    - interface: {{ iface }}
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    # Break glass: skips the rate limit and the blast radius, and
    # writes a change.override record saying who did it and why.
    - override: {{ override }}
    {%- endif %}
    # Matching MTUs were never the goal — an adjacency that forms was. With
    # hello padding on, both ends can agree on the MTU and the adjacency can
    # still stay down for a reason this template knows nothing about, and a
    # config-only check would call that a success.
    - verify:
        fun: verify.isis_adjacency_up
        kwargs:
          interface: {{ iface }}
{%- else %}
fix-p2p-mtu-unknown-link:
  test.fail_without_changes:
    - name: "fix_p2p_mtu: '{{ iface }}' is not a declared P2P link on {{ grains['id'] }}"
{%- endif %}
