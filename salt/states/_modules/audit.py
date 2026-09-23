"""The audit trail: who changed what, on which device, when, and why.

Every automated change to a router passes through here, from both
directions -- the Salt reactor path and the n8n/LLM path -- and every one
of them lands in the ``napalm-audit`` Elasticsearch data stream.

Two properties make it an audit trail rather than a log:

*   **Correlation.** A fault is assigned a ``trace_id`` by the beacon that
    first notices it, and that id travels through the event bus, the
    Grafana alert, the n8n workflow, the model's answer, the salt-api call,
    the state run, and the commit comment left on the device itself. One
    id answers "show me everything about the 04:03 outage" across six
    systems -- and ``info from state /system configuration checkpoint *`` on the router
    shows the same id, so the device agrees with the audit store.

*   **Append-only.** ``napalm-audit`` is a data stream, which rejects
    update-by-id and delete-by-id outright, and the ``salt_writer`` and
    ``n8n_agent`` roles hold ``create_doc`` without ``delete``. Nothing in
    this stack can edit or remove its own audit record, including the
    component that wrote it.

``change_allowed()`` is the other half. It is deliberately in the same
module as the record-keeping, because the two questions -- "what has this
device already had done to it" and "may I do another one" -- have the same
answer source. Putting the guard here means both remediation paths get it:
the reactor's drift loop, which had no rate limit at all, and n8n's, whose
circuit breaker only ever covered its own workflow.
"""

import base64
import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

log = logging.getLogger(__name__)

__virtualname__ = "audit"

INDEX = "napalm-audit"
_TIMEOUT = 10


def __virtual__():
    return __virtualname__


# --------------------------------------------------------------------------
# transport
# --------------------------------------------------------------------------
def _es():
    return os.environ.get("AUDIT_ES_URL", "http://elasticsearch:9200")


def _headers():
    h = {"Content-Type": "application/json"}
    user = os.environ.get("SALT_ES_USER")
    if user:
        token = base64.b64encode(
            f"{user}:{os.environ.get('SALT_ES_PASSWORD', '')}".encode()
        ).decode()
        h["Authorization"] = "Basic " + token
    return h


def _request(method, path, body=None):
    req = urllib.request.Request(
        _es() + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers=_headers(),
    )
    with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
        return json.loads(r.read() or b"{}")


# --------------------------------------------------------------------------
# correlation ids
# --------------------------------------------------------------------------
def new_trace(device=None, fault=None):
    """Mint a trace id for a newly observed fault.

    Deliberately human-readable rather than a bare UUID: it gets read off a
    projector, typed into a Kibana filter, and pasted into a change ticket.
    ``srl3-20260915T041311Z-4f2a1c`` says which device and when before you
    have looked anything up.
    """
    device = device or __grains__.get("id", "unknown")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{device}-{stamp}-{uuid.uuid4().hex[:6]}"


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------
def record(action, trace_id=None, outcome=None, device=None, fault=None,
           interface=None, state=None, reason=None, jid=None,
           duration_ms=None, config_diff=None, actor=None, actor_type=None,
           source=None, detail=None):
    """Append one record to the audit trail.

    Returns a dict rather than raising: an audit write that fails must be
    loud, but it must not be the reason a remediation does not happen. The
    failure is logged at ERROR and surfaces in the state output.
    """
    doc = {
        "@timestamp": datetime.now(timezone.utc).isoformat(),
        "action": action,
        "trace_id": trace_id or "",
        "actor": actor or f"salt:{__grains__.get('id', 'unknown')}",
        "actor_type": actor_type or "automation",
        "source": source or socket.gethostname(),
        "device": device or __grains__.get("id", ""),
    }
    for key, value in (
        ("fault", fault), ("interface", interface), ("state", state),
        ("outcome", outcome), ("reason", reason), ("jid", jid),
        ("duration_ms", duration_ms), ("config_diff", config_diff),
        ("detail", detail),
    ):
        if value not in (None, ""):
            doc[key] = value

    try:
        # op_type=create is mandatory on a data stream, and is also the
        # property being relied on: it cannot overwrite an existing record.
        _request("POST", f"/{INDEX}/_doc?op_type=create", doc)
        return {"result": True, "trace_id": doc["trace_id"], "action": action}
    except Exception as err:  # noqa: BLE001 - never block a remediation
        log.error("audit.record failed for %s/%s: %s", action, doc["device"], err)
        return {"result": False, "error": str(err), "action": action}


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------
def recent(device=None, action="change.applied", minutes=60,
           unattended_only=False):
    """How many matching records exist for this device in the window.

    Returns -1 if Elasticsearch cannot be reached. Callers must treat -1 as
    "unknown", not as zero: an unreachable audit store is not evidence that
    nothing has happened.

    ``unattended_only`` drops changes an actual person made. See the note
    on the rate limit in change_allowed() for why that matters.
    """
    device = device or __grains__.get("id", "")
    must_not = [{"term": {"actor_type": "human"}}] if unattended_only else []
    query = {
        "size": 0,
        "track_total_hits": True,
        "query": {"bool": {
            "filter": [
                {"term": {"device": device}},
                {"term": {"action": action}},
                {"range": {"@timestamp": {"gte": f"now-{int(minutes)}m"}}},
            ],
            "must_not": must_not,
        }},
    }
    try:
        res = _request("POST", f"/{INDEX}/_search", query)
        return int(res["hits"]["total"]["value"])
    except Exception as err:  # noqa: BLE001
        log.error("audit.recent failed for %s: %s", device, err)
        return -1


def devices_changed(minutes=15):
    """How many DISTINCT devices have been changed in the window, and which.

    The per-device rate limit is the wrong instrument for the failure that
    actually hurts. One bad row in the source of truth, or one beacon with a
    wrong threshold, produces a fault on every device at once -- and every
    one of those remediations is, individually, within its per-device
    budget. Idempotent, correct by its own lights, and applied to the entire
    fleet in one minute.

    So there is a second ceiling: how much of the network may change at all
    in a quarter of an hour, regardless of which devices. It is the blast
    radius, and it is the control that turns a systemic mistake into two
    broken devices and a stopped pipeline instead of two hundred.

    Returns (-1, []) if Elasticsearch cannot be reached; callers must treat
    that as unknown, not as zero.
    """
    # Unattended changes only, for the same reason the per-device rate
    # limit counts them that way: a planned rollout touching every router
    # is not the failure this exists to catch. The failure is the fleet
    # changing itself.
    query = {
        "size": 0,
        "query": {"bool": {
            "filter": [
                {"term": {"action": "change.applied"}},
                {"range": {"@timestamp": {"gte": f"now-{int(minutes)}m"}}},
            ],
            "must_not": [{"term": {"actor_type": "human"}}],
        }},
        "aggs": {"devices": {"terms": {"field": "device", "size": 500}}},
    }
    try:
        res = _request("POST", f"/{INDEX}/_search", query)
        names = [b["key"] for b in res["aggregations"]["devices"]["buckets"]]
        return len(names), names
    except Exception as err:  # noqa: BLE001
        log.error("audit.devices_changed failed: %s", err)
        return -1, []


def history(device=None, trace_id=None, size=50):
    """The audit records for one device or one trace, newest last.

        salt srl3 audit.history trace_id=srl3-20260915T041311Z-4f2a1c
    """
    filters = []
    if trace_id:
        filters.append({"term": {"trace_id": trace_id}})
    elif device or __grains__.get("id"):
        filters.append({"term": {"device": device or __grains__["id"]}})
    query = {
        "size": int(size),
        "sort": [{"@timestamp": "asc"}],
        "query": {"bool": {"filter": filters}} if filters else {"match_all": {}},
    }
    try:
        res = _request("POST", f"/{INDEX}/_search", query)
        return [h["_source"] for h in res["hits"]["hits"]]
    except Exception as err:  # noqa: BLE001
        return {"result": False, "error": str(err)}


# --------------------------------------------------------------------------
# the gate
# --------------------------------------------------------------------------
def change_allowed(state=None, device=None, max_per_hour=None, trace_id=None,
                   override=None):
    """May an automated change be applied to this device right now?

    Called from the top of every remediation state, so that both paths --
    the reactor's drift loop and n8n's LLM decision -- pass the same gate.
    Three ways to answer no:

    1.  A maintenance freeze is in effect (pillar ``maintenance:enabled``).
        During planned work, "the config does not match the source of
        truth" is the expected state, and an automation that helpfully
        reverts an engineer's change mid-window is worse than no automation.

    2.  This device has already been changed ``max_per_hour`` times in the
        last hour. A device that keeps drifting back is not a device that
        needs another push; it is a device that needs a human. Without this
        the drift reactor would re-apply every 20 seconds, forever.

    3.  The audit store is unreachable, so neither of the above can be
        checked. Fail closed: an unattended change with no possibility of a
        record is exactly what this module exists to prevent.
    """
    device = device or __grains__.get("id", "")

    # Break glass. Initial provisioning is the case that forced this to
    # exist: on a first install every device legitimately needs converging,
    # and the blast radius limit correctly refuses the third one. That is a
    # planned operation, not self-healing, and the honest way to express it
    # is an override that is itself a record -- not a limit quietly set high
    # enough that nothing ever trips it.
    #
    # The override skips the two ceilings and nothing else: a maintenance
    # freeze still wins, and an unreachable audit store still fails closed,
    # because both of those mean the change cannot be accounted for.
    if override:
        # An override is only an override if the caller was entitled to one.
        #
        # Every remediation state reads `override` out of pillar, and a
        # pillar passed as `kwarg: {pillar: {...}}` on a salt-api call
        # merges on top of the master's. salt-api's eauth can restrict the
        # FUNCTION and the TARGET; it cannot restrict kwargs. So anything
        # holding SALT_API_SECRET could send
        #
        #   kwarg: {pillar: {override: "x", actor_type: "human"}}
        #
        # and skip both ceilings, with the resulting change recorded as a
        # human one and therefore invisible to every counter that enforces
        # them. The whole gate was one HTTP field away from being optional.
        #
        # The marker file is the fix because it is the one thing a caller
        # cannot supply: it is written on the host into file_roots (which
        # the master mounts read-only), so only something with write access
        # to that filesystem can create it. bootstrap.sh does, for the
        # seconds it is provisioning. A caller reaching salt-api cannot.
        #
        # An override asked for without it is not ignored -- it is refused
        # and recorded, so the attempt shows up in the same audit trail as
        # everything else.
        entitled = False
        try:
            marker = __salt__["cp.get_file_str"]("salt://provisioning.window")
            entitled = bool(marker and marker.strip())
        except Exception as exc:               # cp unavailable: fail closed
            log.error("change_allowed: cannot read the override marker (%s)", exc)
        if not entitled:
            reason = ("override requested without a provisioning window — "
                      "refused. An override is authorised on the master, "
                      "not asserted by the caller.")
            record("change.blocked", trace_id=trace_id, device=device,
                   state=state, outcome="blocked", reason=reason,
                   detail={"requested_override": str(override)[:200]})
            return {"allowed": False, "reason": reason, "recent": None}

        freeze = __salt__["pillar.get"]("maintenance:enabled", False, unmask=True)
        if freeze:
            reason = "maintenance freeze in effect — override refused"
            record("change.blocked", trace_id=trace_id, device=device,
                   state=state, outcome="blocked", reason=reason)
            return {"allowed": False, "reason": reason, "recent": None}
        written = record("change.override", trace_id=trace_id, device=device,
                         state=state, outcome="override", reason=str(override),
                         detail={"skipped": ["rate_limit", "blast_radius"]})
        if not written.get("result"):
            reason = ("audit store unreachable — an override that cannot be "
                      "recorded is not an override")
            log.error("change_allowed: %s", reason)
            return {"allowed": False, "reason": reason, "recent": None}
        return {"allowed": True, "reason": f"override: {override}",
                "recent": None, "override": True}

    limit = int(
        max_per_hour
        if max_per_hour is not None
        else __salt__["pillar.get"]("maintenance:max_changes_per_hour", 3, unmask=True)
    )

    freeze = __salt__["pillar.get"]("maintenance:enabled", False, unmask=True)
    if freeze:
        why = __salt__["pillar.get"]("maintenance:reason", "", unmask=True)
        reason = f"maintenance freeze in effect{': ' + why if why else ''}"
        _record_block_once(device, state, trace_id, reason)
        return {"allowed": False, "reason": reason, "recent": None}

    # Unattended changes only. The rate limit exists to stop the automation
    # pushing forever at a device that keeps drifting back -- "it does not
    # need a fourth push, it needs a human". A human's own deliberate change
    # is not the automation looping, and counting it inverts the control:
    # provisioning three routers is three changes, the ceiling is three, so
    # for the next hour the device most likely to need healing is the one
    # least able to receive it. That is not a hypothetical. It blocked two
    # test runs and would have blocked a live demo.
    #
    # A person changing a device ten times in an hour is not this module's
    # business. Unattended change is.
    count = recent(device=device, action="change.applied", minutes=60,
                   unattended_only=True)

    if count < 0:
        reason = ("audit store unreachable -- refusing to change a device "
                  "whose change history cannot be read")
        log.error("change_allowed: %s on %s", reason, device)
        return {"allowed": False, "reason": reason, "recent": None}

    if count >= limit:
        reason = (f"rate limit: {count} changes to {device} in the last hour "
                  f"(limit {limit}) -- escalating to a human")
        _record_block_once(device, state, trace_id, reason, {"recent": count})
        return {"allowed": False, "reason": reason, "recent": count}

    # --- blast radius -----------------------------------------------------
    window = int(__salt__["pillar.get"](
        "maintenance:fleet_window_minutes", 15, unmask=True))
    fleet_limit = int(__salt__["pillar.get"](
        "maintenance:max_devices_per_window", 2, unmask=True))
    changed, names = devices_changed(minutes=window)

    if changed < 0:
        reason = ("audit store unreachable -- cannot measure how much of the "
                  "fleet has already changed")
        log.error("change_allowed: %s", reason)
        return {"allowed": False, "reason": reason, "recent": count}

    # A device already inside the window does not widen the blast radius, so
    # finishing what was started on it is still allowed. Adding a new one is
    # what gets stopped.
    if device not in names and changed >= fleet_limit:
        reason = (f"blast radius: {changed} devices already changed in the "
                  f"last {window}m ({', '.join(sorted(names))}) -- "
                  f"{device} would be number {changed + 1}, limit is "
                  f"{fleet_limit}. A fault this widespread is a systemic "
                  f"problem, not {changed + 1} independent ones.")
        _record_block_once(device, state, trace_id, reason,
                           {"fleet_changed": changed, "devices": names})
        return {"allowed": False, "reason": reason, "recent": count,
                "fleet_changed": changed}

    return {"allowed": True, "reason": "", "recent": count,
            "fleet_changed": changed}


# --------------------------------------------------------------------------
# fault lifecycle, for the beacons
# --------------------------------------------------------------------------
# Falls back to a module global if the loader did not pack __context__.
_OPEN_FAULTS = {}
_LAST_BLOCK = {}

# How long to stay quiet after recording a block for the same device and
# state. The drift beacon re-fires every 20 seconds, so without this a
# single blocked device writes about 150 identical change.blocked records
# an hour -- and an audit trail whose bulk is one repeated line is one
# nobody reads, which defeats the purpose of having written it down.
BLOCK_QUIET_S = 600


def _record_block_once(device, state, trace_id, reason, detail=None):
    """Record a refusal, but only once per device+state per quiet period."""
    try:
        seen = __context__.setdefault("audit.blocks", {})  # noqa: F821
    except NameError:
        seen = _LAST_BLOCK
    key = f"{device}/{state}"
    now = time.time()
    last = seen.get(key)
    if last and now - last < BLOCK_QUIET_S:
        log.debug("audit: suppressing repeat block for %s", key)
        return False
    seen[key] = now
    record("change.blocked", trace_id=trace_id, device=device, state=state,
           outcome="blocked", reason=reason, detail=detail)
    return True


def _open_faults():
    try:
        return __context__.setdefault("audit.open_faults", {})  # noqa: F821
    except NameError:
        return _OPEN_FAULTS


def track(key, faulty, fault=None, device=None, interface=None, detail=None):
    """Turn a repeated observation into a fault lifecycle.

    Beacons run every 15-20 seconds and see the same broken interface every
    time. Left alone that produces one audit record per interval -- forty
    records for one outage, each with its own id, and no way to ask how long
    anything took.

    So the *event* still fires every interval, because Grafana's alert rule
    counts events in a 120-second window and would resolve the alert if they
    stopped. The *audit record* is written only on a transition:

        healthy -> faulty   mint a trace id, write fault.detected
        faulty  -> faulty   reuse the same trace id, write nothing
        faulty  -> healthy  write fault.resolved with the duration

    One outage is therefore one trace id, from detection through the model's
    decision and the config push to the moment the beacon stops seeing it.

    ``key`` identifies the specific thing being watched -- "srl3/ethernet-1/3",
    not just "srl3" -- so two simultaneous faults on one device stay distinct.
    """
    device = device or __grains__.get("id", "")
    open_faults = _open_faults()

    if faulty:
        existing = open_faults.get(key)
        if existing:
            return {"trace_id": existing["trace_id"], "transition": "ongoing"}
        trace_id = new_trace(device, fault)
        open_faults[key] = {"trace_id": trace_id, "opened_at": time.time(),
                            "fault": fault, "interface": interface}
        record("fault.detected", trace_id=trace_id, device=device, fault=fault,
               interface=interface, outcome="open", reason=detail,
               actor=f"salt-beacon:{device}", actor_type="beacon")
        return {"trace_id": trace_id, "transition": "opened"}

    existing = open_faults.pop(key, None)
    if not existing:
        return {"trace_id": None, "transition": None}

    record("fault.resolved", trace_id=existing["trace_id"], device=device,
           fault=existing["fault"], interface=existing["interface"],
           outcome="resolved",
           duration_ms=int((time.time() - existing["opened_at"]) * 1000),
           actor=f"salt-beacon:{device}", actor_type="beacon")
    return {"trace_id": existing["trace_id"], "transition": "resolved"}


def open_faults():
    """What this minion currently believes is broken.

        salt srl3 audit.open_faults
    """
    return {k: dict(v) for k, v in _open_faults().items()}
