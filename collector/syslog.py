"""Receive syslog from the routers and put it where everything else is.

The devices were the one part of this lab that logged nowhere. Container
stdout has been going to Elasticsearch for a while; the routers' own view
of events -- an adjacency dropping, a session resetting, a commit being
applied -- stayed on the box, visible only to whoever thought to go and
look.

That is the wrong half to lose. When a remediation does not work, the
useful evidence is usually what the device thought was happening at the
time, and correlating it with the audit trail means having both on one
time axis.

Lands in the same lab-logs data stream as the container logs, with
container.name set to the device, so every existing query and dashboard
covers it without change. source distinguishes the two.

RFC 3164 and RFC 5424 are both handled: SR Linux emits 5424, but anything
that ends up pointed at this port should not be dropped for being older.
"""

import os
import re
import socket
import threading
import time
from datetime import datetime, timezone

import esclient

INDEX = "lab-logs"
PORT = int(os.environ.get("SYSLOG_PORT", "5514"))
FLUSH = float(os.environ.get("FLUSH", "5"))
MAX_BATCH = int(os.environ.get("MAX_BATCH", "500"))
# How many parsed messages to hold when Elasticsearch is not answering.
# Bounded on purpose: a collector that grows without limit turns a storage
# outage into a memory outage on the host that is supposed to be watching.
MAX_HELD = int(os.environ.get("MAX_HELD", "5000"))

# <PRI> is facility*8 + severity. Severity is the half worth keeping.
SEVERITY = {
    0: "CRITICAL", 1: "CRITICAL", 2: "CRITICAL", 3: "ERROR",
    4: "WARN", 5: "NOTICE", 6: "INFO", 7: "DEBUG",
}

# <134>1 2026-09-16T00:41:02.123Z srl1 sr_bgp_mgr 1234 - - message
_RFC5424 = re.compile(
    r"^<(?P<pri>\d{1,3})>1 (?P<ts>\S+) (?P<host>\S+) (?P<app>\S+) "
    r"(?P<pid>\S+) (?P<msgid>\S+) (?P<sd>-|\[.*?\]) ?(?P<msg>.*)$", re.S)
# <134>Sep 16 00:41:02 srl1 sr_bgp_mgr: message
_RFC3164 = re.compile(
    r"^<(?P<pri>\d{1,3})>(?P<ts>\w{3} +\d+ [\d:]+) (?P<host>\S+) "
    r"(?P<app>[^:\[]+)[:\[]? ?(?P<msg>.*)$", re.S)

_buf = []
_lock = threading.Lock()


def _parse(raw, addr):
    text = raw.decode("utf-8", errors="replace").strip()
    now = datetime.now(timezone.utc).isoformat()

    m = _RFC5424.match(text) or _RFC3164.match(text)
    if not m:
        # Never drop a line for being unparseable. A malformed message from
        # a device under stress is exactly the one worth having.
        return {"@timestamp": now, "message": text[:8192],
                "container.name": addr[0], "source": "device-syslog",
                "syslog.parsed": False}

    g = m.groupdict()
    pri = int(g["pri"])
    stamp = now
    ts = g.get("ts", "")
    if ts and ts != "-":
        try:
            clean = re.sub(r"\.(\d{6})\d+", r"\1", ts.replace("Z", "+00:00"))
            stamp = datetime.fromisoformat(clean).astimezone(timezone.utc).isoformat()
        except (ValueError, TypeError):
            pass  # keep receive time; a bad clock is not a reason to drop

    return {
        "@timestamp": stamp,
        "message": (g.get("msg") or "").strip()[:8192],
        "container.name": g.get("host") or addr[0],
        "log.level": SEVERITY.get(pri % 8, "INFO"),
        "source": "device-syslog",
        "syslog.facility": pri // 8,
        "syslog.app": (g.get("app") or "").strip(" :["),
        "syslog.parsed": True,
    }


def _flusher():
    """Ship the buffer, and put it back if Elasticsearch would not take it.

    This used to call bulk() and ignore what came back. esclient.bulk()
    retries three times over about seven seconds and then returns 0 --
    which is the honest thing for it to do -- and the batch was dropped on
    the floor. Observed, during a short Elasticsearch restart:

        es: URLError: <urlopen error [Errno 111] Connection refused>
        es: giving up on 61 docs

    Sixty-one device syslog messages, gone. Not the audit trail, but the
    forensics: what the router thought was happening while a remediation
    ran, which is the evidence you want precisely when something went
    wrong.

    A returned 0 means the transport failed and nothing landed, so the
    batch goes back. A partial count means Elasticsearch rejected specific
    documents -- a mapping conflict, usually -- and re-queueing those would
    loop on them forever, so that case is reported and dropped.
    """
    while True:
        time.sleep(FLUSH)
        with _lock:
            batch, _buf[:] = _buf[:MAX_BATCH], _buf[MAX_BATCH:]
        if batch:
            sent = esclient.bulk(INDEX, batch, op="create")
            if sent == 0:
                with _lock:
                    _buf[:0] = batch
                    over = len(_buf) - MAX_HELD
                    if over > 0:
                        # Drop the OLDEST, and say how many. Keeping the
                        # newest is the right way round: during an outage
                        # the recent messages are the ones that explain it.
                        del _buf[:over]
                        esclient.log(
                            f"device-syslog: holding {MAX_HELD} messages "
                            f"for a store that is not answering; dropped "
                            f"{over} older ones")
        esclient.beat()


def main():
    esclient.wait_until_ready()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    esclient.log(f"device-syslog: listening on udp/{PORT} -> {esclient.ES}/{INDEX}")
    threading.Thread(target=_flusher, daemon=True).start()

    while True:
        try:
            raw, addr = sock.recvfrom(65535)
            with _lock:
                _buf.append(_parse(raw, addr))
        except Exception as err:  # noqa: BLE001 - never stop listening
            esclient.log(f"device-syslog: {type(err).__name__}: {err}")


if __name__ == "__main__":
    main()
