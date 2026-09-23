"""Notice when the monitoring itself has stopped working.

Everything else in this stack detects faults by observing devices. Nothing
observed whether that observation was still happening -- and on
2026-09-15 all three routers were stopped by a Docker restart at 05:45:52
and stayed down for an hour and forty-five minutes. Every service reported
healthy. Grafana's alert rule sat at `state: inactive`. Not one alert
fired, because the beacons could not reach the devices and therefore
emitted nothing, and "no events" is indistinguishable from "no faults" to
anything counting events.

This is the watchdog for that. It asks one question that the rest of the
system structurally cannot:

    when did each device last say anything at all?

It runs outside Salt on purpose. A beacon cannot report that its own
minion is dead, and a Salt master cannot report that its own event bus has
stopped reaching Elasticsearch. This process shares nothing with either
except the Elasticsearch it reads, so it survives the failure of both --
and when Elasticsearch is what broke, it says that instead.

It writes to napalm-audit like everything else, so a silent device appears
on the same trail, under the same trace id scheme, as a broken interface.
"""

import os
import time
import uuid
from datetime import datetime, timezone

import esclient

INDEX = "napalm-audit"
EVENTS = "napalm-*"

# Which minions should be heard from. Comma-separated so an operator can
# change the fleet without touching code.
EXPECTED = [d.strip() for d in
            os.environ.get("WATCHDOG_DEVICES", "srl1,srl2,srl3").split(",")
            if d.strip()]

# A beacon interval is 15-20s, and the Salt mine refreshes every minute, so
# a device that has said nothing for three minutes is not merely quiet.
SILENCE_S = int(os.environ.get("WATCHDOG_SILENCE_SECONDS", "180"))
INTERVAL = int(os.environ.get("WATCHDOG_INTERVAL", "60"))

# On a fresh install nothing has reported yet, because Salt has not synced
# the beacons to the minions. Alerting immediately would fire three times on
# every first run and teach whoever installed it to ignore this process,
# which is the one thing a watchdog cannot afford. Silence is still logged
# during the grace period, just not raised.
STARTUP_GRACE = int(os.environ.get("WATCHDOG_STARTUP_GRACE", "300"))
_started = time.time()

# Fault state, so a device that is still silent is not re-reported every
# minute. Same lifecycle the beacons use: one outage, one trace id.
_open = {}


def _now():
    return datetime.now(timezone.utc)


def last_seen():
    """Seconds since each expected device last produced any Salt event.

    Returns {device: seconds_or_None}. None means it has never been seen in
    the searchable window, which for a device that is supposed to be live
    is worse than a large number, not better.
    """
    query = {
        "size": 0,
        "query": {"range": {"data._stamp": {"gte": "now-1h"}}},
        "aggs": {"per_device": {
            "terms": {"field": "data.id.keyword", "size": 500},
            "aggs": {"latest": {"max": {"field": "data._stamp"}}},
        }},
    }
    res = esclient.search(EVENTS, query)
    if res is None:
        return None

    # A brand-new cluster has no napalm-* index yet, and Elasticsearch
    # answers 200 with no aggregations block at all rather than an empty
    # one. Treating that as an error crashed the watchdog on every fresh
    # install; treating it as "nobody has been heard from" is both true and
    # exactly what this process exists to report.
    buckets = (res.get("aggregations", {})
                  .get("per_device", {})
                  .get("buckets", []))

    seen = {}
    for bucket in buckets:
        latest = bucket["latest"]["value"]
        if latest:
            seen[bucket["key"]] = (time.time() * 1000 - latest) / 1000.0

    return {device: seen.get(device) for device in EXPECTED}


def audit(action, device, outcome, reason, trace_id, detail=None):
    doc = {
        "@timestamp": _now().isoformat(),
        "action": action,
        "outcome": outcome,
        "trace_id": trace_id,
        "actor": "watchdog",
        "actor_type": "watchdog",
        "source": "docker-watchdog",
        "device": device,
        "fault": "device_silent",
        "reason": reason[:1000],
    }
    if detail:
        doc["detail"] = detail
    esclient.bulk(INDEX, [doc], op="create")


def check():
    ages = last_seen()

    if ages is None:
        # Elasticsearch is what broke. Say so once, loudly, and do not
        # pretend to have an opinion about the devices.
        if "__es__" not in _open:
            _open["__es__"] = {"trace": f"watchdog-es-{uuid.uuid4().hex[:8]}"}
            esclient.log("WATCHDOG: elasticsearch is unreachable — "
                         "the fault pipeline is blind")
        return
    if "__es__" in _open:
        esclient.log("WATCHDOG: elasticsearch is back")
        _open.pop("__es__")

    for device in EXPECTED:
        age = ages.get(device)
        silent = age is None or age > SILENCE_S

        if silent and device not in _open and time.time() - _started < STARTUP_GRACE:
            esclient.log(f"watchdog: {device} not heard from yet "
                         f"({int(STARTUP_GRACE - (time.time() - _started))}s "
                         f"of startup grace left)")
            continue

        if silent and device not in _open:
            trace = (f"{device}-{_now().strftime('%Y%m%dT%H%M%SZ')}"
                     f"-{uuid.uuid4().hex[:6]}")
            _open[device] = {"trace": trace, "since": time.time()}
            reason = (f"{device} has produced no Salt event for "
                      f"{'over an hour' if age is None else f'{int(age)}s'} "
                      f"(threshold {SILENCE_S}s). Either the device is "
                      f"unreachable, its proxy-minion is down, or the event "
                      f"bus has stopped reaching Elasticsearch. Nothing else "
                      f"in this stack can tell you this, because everything "
                      f"else detects faults by counting events.")
            esclient.log(f"WATCHDOG: {reason}")
            audit("device.silent", device, "open", reason, trace,
                  {"age_s": age, "threshold_s": SILENCE_S})

        elif not silent and device in _open:
            state = _open.pop(device)
            down_for = int(time.time() - state["since"])
            reason = f"{device} is producing events again after {down_for}s"
            esclient.log(f"WATCHDOG: {reason}")
            audit("device.heard", device, "resolved", reason, state["trace"],
                  {"silent_for_s": down_for})


def main():
    esclient.wait_until_ready()
    esclient.log(f"watchdog: {', '.join(EXPECTED)} — alert after "
                 f"{SILENCE_S}s of silence, checked every {INTERVAL}s")
    while True:
        try:
            check()
        except Exception as err:  # noqa: BLE001 - never let the watchdog die
            esclient.log(f"watchdog: {type(err).__name__}: {err}")
        # Beat even after a failed pass. The heartbeat answers "is this
        # process still going round its loop", not "did the last check
        # succeed" -- and gating it on success meant one transient error
        # left the container reporting unhealthy for ever, which stalled
        # bootstrap.sh waiting for a health it would never reach.
        esclient.beat()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
