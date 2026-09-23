# Converge this device's BGP policy to what NetBox says it should be.
#
# This is the service layer: what we announce to transit, what we accept
# from it, and what we filter. It is separate from golden_config because it
# has a different lifecycle -- IS-IS is configured once and left alone,
# while prefix-lists are edited weekly, often quickly, and are where the
# expensive mistakes live.
#
# Intent comes from a NetBox config context attached to the device role, so
# there is no template to edit and no second copy to keep in step. A device
# whose role carries no bgp context is simply not in scope.
#
#   salt srl3 state.apply bgp_policy test=True    # what would change
#   salt srl3 state.apply bgp_policy              # converge it
{%- set trace_id = pillar.get('trace_id', '') %}
{%- set actor = pillar.get('actor', 'salt-operator') %}
{%- set actor_type = pillar.get('actor_type', 'automation') %}
{%- set override = pillar.get('override', '') %}
{%- set nb = salt['pillar.get']('netbox', {}) %}
{%- set response = salt['http.query'](
      nb.get('url', 'http://netbox:8080') ~ '/api/dcim/devices/?name=' ~ grains['id'],
      header_dict={'Authorization': 'Token ' ~ nb.get('token', '')},
      decode=True, decode_type='json', status=True) %}
{%- set results = response.get('dict', {}).get('results', []) %}
{%- set context = results[0].get('config_context', {}) if results else {} %}
{%- set bgp = context.get('bgp', {}) %}

{%- if response.get('status', 0) != 200 %}
# NetBox unreachable. Doing nothing is the only safe answer: a routing
# policy rendered from an empty source of truth is an empty policy, and an
# empty policy on a transit session means announcing nothing, accepting
# nothing, or both.
bgp-policy-no-source-of-truth:
  test.fail_without_changes:
    - name: "bgp_policy: NetBox returned status {{ response.get('status', 'none') }} for {{ grains['id'] }} — refusing to render policy from a source of truth that is not answering"

{%- elif not bgp %}
bgp-policy-not-in-scope:
  test.succeed_without_changes:
    - name: "{{ grains['id'] }} has no bgp config context in NetBox — not a border router, nothing to do"

{%- else %}
bgp-policy-{{ grains['id'] }}:
  audited.config:
    - template_name: salt://templates/bgp_policy.jinja
    - context:
        bgp: {{ bgp | tojson }}
    - state_name: bgp_policy
    - fault: policy_drift
    {#- The outcome, not the configuration. Re-rendering the export policy
        proves the policy converged; only the post-policy adj-rib-out proves
        the router stopped announcing what it should not. This is also what
        arms the device's revert timer: a policy push that does not stop the
        leak is rolled back by the router itself. #}
    {%- if bgp.get('transit', {}).get('peer_ip') %}
    - verify:
        fun: verify.advertises_only
        kwargs:
          peer: "{{ bgp['transit']['peer_ip'] }}"
          permitted: {{ (bgp['transit'].get('export', {}).get('prefixes') or []) | tojson }}
    {%- endif %}
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    - override: {{ override }}
    {%- endif %}
{%- endif %}
