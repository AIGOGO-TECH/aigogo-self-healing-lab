# Converge this device's protocol layer to the fabric plan.
#
# IS-IS, BFD and BGP, rendered from salt/pillar/fabric.sls -- the same plan
# that produced the bootstrap config, so the two cannot disagree. This is
# configuration management in the ISP sense: the device is brought to a
# declared state, the difference is shown before it is applied, and the run
# is recorded.
#
# It goes through audited.config like every remediation, which means the
# golden config gets the same treatment as an emergency fix: the change gate
# (freeze, rate limit, blast radius), a diff in the audit trail, a commit
# message on the device naming who asked for it, and the device's own revert
# timer if a verification is declared.
#
#   salt srl1 state.apply golden_config test=True     # show me the diff
#   salt '*'  state.apply golden_config               # converge the fabric
{#- trace_id and actor arrive as pillar overrides on the salt-api call, so a
    change made through the n8n/LLM path is attributed to the model that chose
    it. Applying it by hand falls back to naming the operator's path. -#}
{%- set trace_id = pillar.get('trace_id', '') %}
{%- set actor = pillar.get('actor', 'salt-operator') %}
{%- set actor_type = pillar.get('actor_type', 'automation') %}
{%- set override = pillar.get('override', '') %}
{%- set fabric = salt['pillar.get']('fabric', {}) %}
{%- set dev = fabric.get('devices', {}).get(grains['id'], {}) %}

{%- if dev %}
golden-config-{{ grains['id'] }}:
  audited.config:
    - template_name: salt://templates/golden_config.jinja
    - context:
        dev: {{ dev | tojson }}
        asn: {{ fabric.get('asn') }}
        transit_asn: {{ fabric.get('transit_asn') }}
        keychain: {{ fabric.get('isis_keychain') }}
        cluster_id: {{ fabric.get('rr_cluster_id') }}
        syslog_server: {{ fabric.get('syslog_server') }}
        syslog_port: {{ fabric.get('syslog_port') }}
        {#- Every syslog consumer, so the template does not have to know how
            many there are. The two singular keys above stay for a pillar
            written before the push path existed. #}
        syslog_destinations: {{ fabric.get('syslog_destinations', []) | tojson }}
    - state_name: golden_config
    - fault: config_drift
    {#- The outcome, not the configuration. This state pushes the whole
        protocol layer -- IS-IS, BFD, iBGP -- so the config converging
        proves nothing: the risk of pushing protocol config is precisely
        that it converges cleanly and the adjacencies drop. Checking that
        the fabric is still whole afterwards is the only evidence that
        means anything, and arming this is what arms the revert timer.
        Without it the state committed permanently and unchecked, while
        the README claimed every remediation declared an outcome check. #}
    {#- Not during initial provisioning. The check is "the fabric still has
        its adjacencies", and on a first install there is no fabric yet:
        srl1 is converged before srl2 has any IS-IS at all, so the
        adjacency it is waiting for cannot form, the verify times out, the
        commit is never confirmed and the router reverts the change. The
        bootstrap then cannot finish — which is exactly what happened when
        this check was added without thinking about ordering.

        `override` is only ever set by initial provisioning, and it is
        already the marker for "planned work, not self-healing". What
        proves the fabric afterwards is check-lab.sh, which asserts the
        adjacencies once every device has been converged. -#}
    {%- set want = salt['pillar.get']('isis_adjacencies:' ~ grains['id']) %}
    {%- if want and not override %}
    - verify:
        fun: verify.isis_adjacencies
        kwargs:
          expected: {{ want }}
    {%- endif %}
    - trace_id: {{ trace_id }}
    - actor: {{ actor }}
    - actor_type: {{ actor_type }}
    {%- if override %}
    - override: {{ override }}
    {%- endif %}
{%- else %}
# A device with no entry in the fabric plan is not managed by this state.
# srl4 is the case that matters: it is the upstream provider's router, it
# has no proxy-minion, and the automation is not allowed to reach it.
golden-config-not-in-plan:
  test.fail_without_changes:
    - name: "{{ grains['id'] }} has no entry in pillar fabric:devices — refusing to guess a protocol configuration for it"
{%- endif %}
