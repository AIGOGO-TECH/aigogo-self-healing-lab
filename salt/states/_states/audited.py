"""One state that cannot apply a change without recording it.

Every remediation in salt/states/ goes through ``audited.config`` instead
of ``netconfig.managed``. The difference is not cosmetic: three things that
used to be optional, absent, or someone else's job are now inseparable from
the act of changing a device.

**The gate runs first.** ``audit.change_allowed()`` checks the maintenance
freeze and the per-device hourly rate limit before anything is rendered.
The n8n workflow has always had a circuit breaker, but the Salt reactor's
drift loop had none at all -- a device that drifted and failed to converge
was reconfigured every twenty seconds, indefinitely. Both paths end up
here, so both are now covered by the same rule, and the rule lives in
pillar where an operator can change it without editing a workflow.

**The change is recorded whatever happens.** Applied, blocked, failed, or
already-correct: an audit record is written before this state returns, with
the config diff attached. Not with ``module.run`` and a ``require``, which
records successes and quietly loses failures.

**The device is marked.** The commit carries the trace id and the actor, so
``info from state /system configuration checkpoint *`` on the router names the decision
that changed it.

Usage::

    restore-ethernet-1/3:
      audited.config:
        - template_name: salt://templates/restore_interface.jinja
        - context:
            interface: ethernet-1/3
        - state_name: restore_interface
        - trace_id: {{ trace_id }}
        - actor: {{ actor }}
"""

import logging
import time

log = logging.getLogger(__name__)

__virtualname__ = "audited"


def __virtual__():
    if "netsafe.push_template" not in __salt__:
        return False, "netsafe module is unavailable"
    if "audit.record" not in __salt__:
        return False, "audit module is unavailable"
    return __virtualname__


def config(name, template_name, context=None, state_name=None, trace_id=None,
           actor=None, actor_type=None, fault=None, interface=None,
           verify=None, revert_in=120, max_per_hour=None, override=None):
    """Apply a remediation template: gated, recorded, and verified.

    ``verify`` names a check on the OUTCOME, not on the configuration --
    ``{"fun": "verify.interface_up", "kwargs": {"name": "ethernet-1/1"}}``.
    When it is given, the change is committed with the device's own revert
    timer armed and confirmed only if the check passes. A change that does
    not produce the outcome it was for is not kept: the router rolls it back
    on its own clock.

    This is the answer to the obvious objection to idempotent remediation --
    that converging reliably to a state says nothing about whether the state
    is correct. Convergence is checked by the template. Correctness is
    checked here, against the network.
    """
    ret = {"name": name, "result": False, "changes": {}, "comment": ""}
    state_name = state_name or name
    actor = actor or "salt-reactor"
    started = time.time()

    common = {
        "trace_id": trace_id,
        "state": state_name,
        "fault": fault,
        "interface": interface,
        "actor": actor,
        # Stated, never inferred. Guessing it from the shape of the actor
        # string labelled "human/noc" as a model decision.
        "actor_type": actor_type or "automation",
    }

    # --- 1. may this change happen at all? --------------------------------
    gate = __salt__["audit.change_allowed"](
        state=state_name, max_per_hour=max_per_hour, trace_id=trace_id,
        override=override,
    )

    # --- 2. test mode: always show the diff -------------------------------
    # The gate is reported, not enforced, on a dry run. Refusing to show an
    # operator what a change WOULD do, because applying it right now would
    # be rate-limited, is unhelpful and teaches people to work around the
    # tool: `test=True` is how you find out whether a device has drifted,
    # and that question is worth answering even during a freeze.
    if __opts__["test"]:
        preview = __salt__["netsafe.push_template"](
            template_name=template_name, context=context or {},
            trace_id=trace_id, actor=actor, state_name=state_name, test=True,
        )
        ret["result"] = None if preview.get("diff") else True
        ret["comment"] = preview.get("comment", "")
        if not gate["allowed"]:
            ret["comment"] += f"  [applying this now would be refused: {gate['reason']}]"
        if preview.get("diff"):
            ret["changes"] = {"diff": preview["diff"]}
        return ret

    if not gate["allowed"]:
        # change_allowed has already written the change.blocked record --
        # including when the audit store itself is unreachable, in which
        # case it fails closed and there is nothing to write it to.
        ret["comment"] = f"blocked: {gate['reason']}"
        return ret

    # --- 3. apply, with the device's own revert timer armed ---------------
    # revert_in is passed only when there is a check to confirm against.
    # An unconditional timer on an unverifiable change would just roll back
    # good work after two minutes.
    arm = int(revert_in) if (verify and revert_in) else None
    out = __salt__["netsafe.push_template"](
        template_name=template_name, context=context or {}, trace_id=trace_id,
        actor=actor, state_name=state_name, revert_in=arm,
    )
    elapsed = int((time.time() - started) * 1000)

    if out.get("result") is False:
        ret["comment"] = out.get("comment", "push failed")
        __salt__["audit.record"](
            "change.failed", outcome="failure", reason=ret["comment"],
            duration_ms=elapsed, **common
        )
        return ret

    if not out.get("changed"):
        # Idempotent re-run. Deliberately not recorded as a change: an audit
        # trail where most entries are "did nothing" is one nobody reads.
        ret["result"] = True
        ret["comment"] = out.get("comment", "Already in the desired state.")
        return ret

    ret["changes"] = {"diff": out["diff"]}
    __salt__["audit.record"](
        "change.applied", outcome="success", config_diff=out["diff"],
        duration_ms=elapsed,
        detail={"commit_message": out.get("commit_message"),
                "revert_in": out.get("revert_in"),
                "verify": (verify or {}).get("fun")},
        **common
    )

    # --- 4. did it achieve what it was for? -------------------------------
    if not verify:
        ret["result"] = True
        ret["comment"] = out.get("comment", "Applied.")
        return ret

    fun = verify.get("fun")
    if fun not in __salt__:
        # Refuse to silently treat an unrunnable check as a pass. The timer
        # is armed, so doing nothing here means the device reverts itself.
        ret["comment"] = (f"applied, but the verification function {fun} does "
                          f"not exist — leaving the revert timer to fire")
        __salt__["audit.record"](
            "change.unverified", outcome="failure", reason=ret["comment"],
            detail={"revert_in": arm}, **common)
        return ret

    check = __salt__[fun](**(verify.get("kwargs") or {}))

    if not check.get("verified"):
        # Do NOT confirm. The router rolls the change back on its own clock,
        # with no help from Salt, the master, or the network path between
        # them -- so this still works when what failed is Salt itself.
        ret["comment"] = (f"applied but NOT verified: {check.get('detail')} — "
                          f"the device will revert in {arm}s")
        __salt__["audit.record"](
            "change.unverified", outcome="failure",
            reason=str(check.get("detail"))[:1000],
            duration_ms=int((time.time() - started) * 1000),
            detail={"revert_in": arm, "verify": fun, "check": check},
            **common)
        return ret

    confirmed = __salt__["netsafe.confirm"]()
    ret["result"] = True
    ret["comment"] = (f"applied and verified: {check.get('detail')} "
                      f"({confirmed.get('comment', '')})")
    __salt__["audit.record"](
        "change.verified", outcome="success",
        reason=str(check.get("detail"))[:1000],
        duration_ms=int((time.time() - started) * 1000),
        detail={"verify": fun, "check": check, "confirm": confirmed},
        **common)
    return ret
