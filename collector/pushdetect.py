"""Consume napalm-logs' ZeroMQ publisher and record what the PUSH path saw.

This exists to answer one question with data instead of opinion: if detection
came from syslog the instant a device emitted it, rather than from a beacon on
its next interval, would this lab be better?

It deliberately does NOT remediate. Every record it writes is an observation:

    action: fault.observed      actor: napalm-logs

The poll path keeps writing `fault.detected` and keeps being the only thing
allowed to act. Two detectors both firing state.apply on one fault collide on
the device's single candidate configuration, and the measurement does not need
them to. Once the comparison says the push path is trustworthy, promoting it
is a separate, deliberate change.

What makes the comparison honest is that both paths write to the same index on
the same clock, so `scripts/compare-paths.sh` can join them on device and time
and say which saw a fault first -- and, more usefully, which saw one the other
missed entirely.
"""

import datetime
import json
import logging
import os
import time

import zmq

import esclient
from napalm_logs.utils import unserialize

INDEX = "napalm-audit"
ADDRESS = os.environ.get("NAPALM_LOGS_ADDRESS", "napalm-logs")
PORT = int(os.environ.get("NAPALM_LOGS_PUBLISH_PORT", "49017"))
# How long the feed may be silent before the heartbeat stops and the container
# goes unhealthy. The routers emit BFD and heartbeat messages continuously, so
# silence past this means the path is broken, not that the network is calm.
SILENT_AFTER = float(os.environ.get("SILENT_AFTER", "600"))

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("pushdetect")

# napalm-logs error name -> (our fault name, is this a fault or a recovery)
#
# The mapping is not one-to-one, and the places where it is not are the
# interesting part of the measurement.
#
# INTERFACE_DOWN is the clearest example. The poll path raises two DIFFERENT
# faults for one shut interface -- `interface_admin_down` on the device that
# was shut, and `interface_link_down` on the far end, which is enabled and
# simply has no light. It fixes the first and DECLINES the second, because
# bringing up a far end whose peer is down achieves nothing.
#
# The syslog message cannot tell them apart. netinst reports oper_status DOWN
# on both ends, identically. So the push path can say "an interface went down
# somewhere" faster than the poll path can, and cannot say which of the two
# faults it is looking at -- which is precisely the distinction that decides
# whether to act. That is recorded here rather than papered over: the fault
# name is `interface_down`, deliberately matching neither poll fault, so the
# comparison cannot silently credit push with a detection it did not make.
FAULTS = {
    "INTERFACE_DOWN": ("interface_down", "detected"),
    "INTERFACE_UP": ("interface_down", "resolved"),
    "BGP_NEIGHBOR_STATE_CHANGED": ("bgp_session_down", None),
    "ISIS_ADJACENCY_STATE_CHANGED": ("isis_adjacency_down", None),
    # LLDP tells us a neighbour appeared or went away. Neither is a fault this
    # lab remediates, and recording them as faults would inflate the push
    # path's score with events the poll path never claimed to watch.
    "LLDP_NEIGHBOR_UP": (None, None),
    "LLDP_NEIGHBOR_DOWN": (None, None),
}

# For the two errors whose direction depends on the state in the message
# rather than on the error name.
# Three classes, because two is not enough.
#
# UP_STATES mean the fault is over. TRANSITIONAL states appear only while a
# session or adjacency is coming back, and are recorded as neither: an IS-IS
# adjacency goes DOWN -> INIT -> UP, so counting INIT as a detection counts
# every recovery as a new fault. That is not cosmetic here. It doubles the
# push path's apparent detections, and this bridge exists to measure the push
# path against the poll path -- so its own favour is the one direction it
# must not be wrong in.
#
# Anything in neither set is a fault, which keeps an unfamiliar state on the
# safe side without a guessed list of down-values deciding anything.
UP_STATES = {"ESTABLISHED", "UP"}
TRANSITIONAL = {"INIT", "INITIALIZING", "CONNECT", "OPENSENT", "OPENCONFIRM"}


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _state_from(msg):
    """The state the message reports, whatever it is called.

    napalm-logs puts the interesting value at the leaf of a dict shaped like
    the OpenConfig path, so walk to the leaves and take the first string.

    It deliberately does not carry a list of values that mean "down". IS-IS
    adjacency states include INITIALIZING as well as DOWN and UP, BGP has
    IDLE, ACTIVE, CONNECT and OPENCONFIRM, and a list written from memory
    turns every state missing from it into a warning about unreadable data
    when the data was perfectly readable. Only the values that mean "this is
    fine again" are enumerated; everything else is a fault. That is the safe
    direction to be wrong in.
    """
    found = []

    def walk(node):
        if isinstance(node, dict):
            for v in node.values():
                walk(v)
        elif isinstance(node, str) and node.strip():
            found.append(node.strip().upper())

    walk(msg.get("yang_message") or msg.get("open_config") or {})
    return found[0] if found else ""


def _stamp_from(msg):
    """The device's own time, at the resolution the device actually sent.

    napalm-logs' own `timestamp` field is whole seconds: _format_time() runs
    the captured date and time through calendar.timegm() and casts to int,
    and the fractional part is never folded in. Using it would cap this
    measurement's resolution at one second -- which is useless, because the
    gap being measured between push and poll detection is often smaller than
    that.

    The microseconds are not lost, only unused: the prefix captures them as
    timeSecfrac in message_details. Reassembling the timestamp from there
    keeps the device's clock AND the precision, which is better than stamping
    on arrival -- an arrival stamp measures our own queue as well as the
    network.
    """
    d = msg.get("message_details") or {}
    date, time_, frac = d.get("date"), d.get("time"), d.get("timeSecfrac")
    offset = d.get("timeOffset") or "+00:00"
    if date and time_:
        frac = (str(frac or "0") + "000000")[:6]
        return f"{date}T{time_}.{frac}{offset}"

    # No prefix match means no device clock to trust. Fall back to napalm-logs'
    # second-resolution value, then to now. Both fallbacks produce a whole
    # second, which is the tell: a stamp ending .000000 did not come from the
    # device and must not be read to sub-second precision.
    stamp = msg.get("timestamp")
    if isinstance(stamp, (int, float)):
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(stamp)) + "+00:00"
    return _now()


def _record(msg):
    """Turn one napalm-logs object into one audit observation, or drop it."""
    error = msg.get("error") or ""
    device = msg.get("host") or ""
    if not error or not device:
        log.warning("dropped a message with no error/host: %s",
                    json.dumps(msg, default=str)[:300])
        return None

    # Messages this profile does NOT match never arrive here at all: napalm-logs
    # blacklists RAW in its publisher by default, so it drops them internally
    # and logs one line per message. That means the gaps in the profile are
    # visible only in the daemon's own log, never in this bridge's:
    #
    #   docker logs napalm-logs | grep 'not configured'
    #
    # Worth reading before drawing any conclusion from what the push path
    # recorded, because what it never saw does not appear anywhere else.

    if error not in FAULTS:
        log.info("%s on %s is not mapped to a fault", error, device)
        return None

    fault, outcome = FAULTS[error]
    if fault is None:
        return None

    state = _state_from(msg)
    if outcome is None:
        if state in TRANSITIONAL:
            log.debug("%s on %s is %s -- coming back up, not a new fault",
                      error, device, state)
            return None
        if not state:
            log.warning("%s on %s carried no state at all; recording as "
                        "detected", error, device)
        outcome = "resolved" if state in UP_STATES else "detected"

    return {
        "@timestamp": _stamp_from(msg),
        "action": "fault.observed",
        "outcome": outcome,
        "device": device,
        "fault": fault,
        "actor": "napalm-logs",
        "actor_type": "detector",
        "source": "push-detect",
        "reason": f"syslog: {error}",
        "detail": {
            "napalm_logs_error": error,
            "reported_state": state or None,
            "os": msg.get("os"),
            "yang_model": msg.get("yang_model"),
            "message_details": msg.get("message_details"),
        },
    }


def main():
    ctx = zmq.Context()
    sock = ctx.socket(zmq.SUB)
    sock.setsockopt(zmq.SUBSCRIBE, b"")
    # RCVTIMEO so the heartbeat file keeps being written while the network is
    # quiet. A blocking recv() would make a healthy-but-idle bridge look hung
    # to the healthcheck -- the same mistake as a service that reports
    # unhealthy because nothing has happened yet.
    sock.setsockopt(zmq.RCVTIMEO, 5000)
    url = f"tcp://{ADDRESS}:{PORT}"
    sock.connect(url)
    log.info("subscribed to napalm-logs at %s", url)

    seen = 0
    written = 0
    last_beat = 0.0
    last_msg = time.time()
    while True:
        try:
            raw = sock.recv()
        except zmq.Again:
            raw = None
        except Exception as exc:
            log.error("recv failed (%s); reconnecting in 5s", exc)
            time.sleep(5)
            continue

        now = time.time()
        if raw is not None:
            last_msg = now
        # Only beat while the feed is actually delivering. Beating on every
        # RCVTIMEO expiry keeps the container healthy with napalm-logs stopped,
        # unreachable, or publishing nothing -- which is the one failure this
        # healthcheck exists to catch. The grace period is generous because a
        # quiet network is normal; what is not normal is a quiet network for
        # longer than the routers' own heartbeat interval.
        if now - last_beat > 30 and now - last_msg < SILENT_AFTER:
            esclient.beat()
            last_beat = now

        if raw is None:
            continue

        seen += 1
        try:
            msg = unserialize(raw)
        except Exception as exc:
            log.error("could not decode a published message (%s): %r",
                      exc, raw[:120])
            continue

        doc = _record(msg)
        if doc is None:
            continue
        try:
            if esclient.bulk(INDEX, [doc], op="create") != 1:
                raise RuntimeError("Elasticsearch did not accept the document")
            written += 1
            log.info("%s %s on %s  (seen=%d written=%d)",
                     doc["outcome"], doc["fault"], doc["device"], seen, written)
        except Exception as exc:
            # An observation that cannot be stored is a measurement that will
            # quietly come out in the poll path's favour. Say so loudly.
            log.error("FAILED to record %s on %s: %s",
                      doc["fault"], doc["device"], exc)


if __name__ == "__main__":
    main()
