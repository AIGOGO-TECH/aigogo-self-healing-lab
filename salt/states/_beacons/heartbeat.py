"""Say "I am here" on a fixed interval, whether or not anything is wrong.

The watchdog decides a device is in trouble when it has produced no Salt
event for a while. That only works if a healthy device produces events, and
it turned out one barely does: the other beacons emit only when they find a
fault, so on a working network the event stream is nearly empty. Measured
over five minutes on a lab with two faults open, the two broken devices
produced 23 and 24 events and the healthy one produced 1 -- and the
watchdog duly reported the healthy device as silent.

Inferring liveness from incidental traffic is the bug. This makes it
explicit: one small event per interval per device, carrying the reachability
of the device itself, so silence means exactly one thing.

It is also the cheapest possible check on the whole management path. For
this event to arrive, the proxy-minion must be running, its connection to
the device must be open, the master must be reachable, the event bus must
be working, and the Elasticsearch returner must be writing. Any one of
those failing stops the heartbeat, which is the point.
"""


def __virtual__():
    return True


def validate(config):
    if not isinstance(config, list):
        return False, "heartbeat beacon needs a list of dicts"
    return True, "valid"


def beacon(config):
    device = __grains__["id"]

    # Cheap, and a real check: this goes over the same NAPALM connection
    # every remediation uses, so a device that answers here is a device the
    # automation could actually act on. A timestamp alone would prove only
    # that the minion process is alive.
    try:
        alive = bool(__salt__["napalm.alive"]().get("out", {}).get("is_alive"))
        detail = ""
    except Exception as err:  # noqa: BLE001 - the heartbeat must never stop
        # An unreachable device still gets a heartbeat, carrying the reason.
        # Stopping here would turn "the device is unreachable" back into
        # silence, which is the failure this beacon exists to remove.
        alive = False
        detail = f"{type(err).__name__}: {err}"[:200]

    return [{
        "tag": "heartbeat",
        "device": device,
        "device_reachable": alive,
        "detail": detail,
    }]
