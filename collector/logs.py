"""Ship every lab container's log into Elasticsearch.

`docker logs` is fine until you need to answer "what did the whole system
do between 04:03:11 and 04:04:03" -- then you are tailing nine terminals
and correlating by eye. This puts salt-master, the three proxies, n8n,
Grafana, Elasticsearch, NetBox and the three routers into one searchable
stream, on the same time axis as the Salt events and the audit trail.

Two things make it useful rather than just voluminous:

  * log.level is parsed out, so Kibana can filter to what actually broke
  * trace_id is extracted when a line carries one, so a container log line
    joins the audit record for the same remediation

One thread per container, streaming the follow endpoint. New containers
are picked up within RESCAN seconds; dead ones drop their thread.
"""

import json
import os
import re
import threading
import time
from datetime import datetime, timezone

import dockerapi
import esclient

INDEX = "lab-logs"          # a data stream: writes must use op_type=create
RESCAN = int(os.environ.get("RESCAN", "15"))
FLUSH = float(os.environ.get("FLUSH", "5"))
MAX_BATCH = int(os.environ.get("MAX_BATCH", "500"))
MAX_LINE = 8192

# Salt writes "[ERROR   ]", n8n and Grafana write level=error, Elasticsearch
# writes [WARN ]. One pattern covers all three shapes.
_LEVEL = re.compile(
    r"(?:^|[\[\s])(?:level=)?(TRACE|DEBUG|INFO|NOTICE|WARN(?:ING)?|ERROR|CRITICAL|FATAL)\b",
    re.IGNORECASE,
)
# Anything this stack emits as a correlation id: trace_id=..., [trace:...],
# or the bare field inside a JSON log line.
_TRACE = re.compile(r"trace[_-]?id[\"'=:\s]+([0-9a-zA-Z-]{6,64})", re.IGNORECASE)

_buf = []
_buf_lock = threading.Lock()
_threads = {}


def _emit(doc):
    with _buf_lock:
        _buf.append(doc)


def _parse(line, name, image):
    """One log line -> one document. Never raises: a bad line is still a line."""
    ts, _, msg = line.partition(" ")
    try:
        # Docker's --timestamps prefix is RFC3339 with nanoseconds, which
        # fromisoformat rejects before 3.11 and tolerates after. Trim to
        # microseconds so this does not depend on the interpreter version.
        clean = re.sub(r"\.(\d{6})\d+", r".\1", ts.replace("Z", "+00:00"))
        stamp = datetime.fromisoformat(clean).astimezone(timezone.utc).isoformat()
    except (ValueError, TypeError):
        stamp = datetime.now(timezone.utc).isoformat()
        msg = line

    msg = msg.rstrip()[:MAX_LINE]

    level = None
    m = _LEVEL.search(msg[:200])
    if m:
        level = m.group(1).upper()
        if level == "WARNING":
            level = "WARN"

    doc = {
        "@timestamp": stamp,
        "message": msg,
        "container.name": name,
        "container.image.name": image,
    }
    if level:
        doc["log.level"] = level
    t = _TRACE.search(msg)
    if t:
        doc["trace_id"] = t.group(1)
    return doc


def _demux(resp, framed):
    """Yield decoded lines from a Docker log stream.

    Without a TTY, Docker prefixes every chunk with an 8-byte header
    (stream id, three zero bytes, then a 4-byte big-endian length). With a
    TTY the bytes are raw. Getting this wrong shows up as control
    characters wedged into the front of every message.
    """
    pending = b""
    while True:
        if framed:
            header = resp.read(8)
            if len(header) < 8:
                return
            size = int.from_bytes(header[4:8], "big")
            chunk = resp.read(size)
            if not chunk:
                return
        else:
            chunk = resp.read(4096)
            if not chunk:
                return
        pending += chunk
        while b"\n" in pending:
            raw, _, pending = pending.partition(b"\n")
            text = raw.decode("utf-8", errors="replace").strip()
            if text:
                yield text


def _follow(cid, name, image):
    """Stream one container until it stops or the connection breaks."""
    framed = not dockerapi.has_tty(cid)
    since = int(time.time())
    while True:
        conn = None
        try:
            path = (f"/containers/{cid}/logs?follow=1&stdout=1&stderr=1"
                    f"&timestamps=1&since={since}")
            conn, resp = dockerapi.stream(path)
            if resp.status != 200:
                return
            for line in _demux(resp, framed):
                _emit(_parse(line, name, image))
        except Exception as err:  # noqa: BLE001 - restart on any stream error
            esclient.log(f"logs: {name}: {type(err).__name__}: {err}")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:  # noqa: BLE001
                    pass
        # Resume from now rather than replaying: duplicate log lines in an
        # audit store are worse than a one-second gap during a restart.
        since = int(time.time())
        if not _still_running(cid):
            esclient.log(f"logs: {name} gone, stopping follower")
            return
        time.sleep(2)


def _still_running(cid):
    try:
        return dockerapi.get(f"/containers/{cid}/json")["State"]["Running"]
    except Exception:  # noqa: BLE001
        return False


def _flusher():
    while True:
        time.sleep(FLUSH)
        with _buf_lock:
            batch, _buf[:] = _buf[:MAX_BATCH], _buf[MAX_BATCH:]
        if batch:
            esclient.bulk(INDEX, batch, op="create")
        # Beat on every pass, not only when there was something to send:
        # a quiet stack is not a broken collector.
        esclient.beat()


def main():
    esclient.wait_until_ready()
    esclient.log(f"docker-logs -> {esclient.ES}/{INDEX}, rescan every {RESCAN}s")
    threading.Thread(target=_flusher, daemon=True).start()

    while True:
        try:
            for cid, name, image in dockerapi.lab_containers():
                if cid in _threads and _threads[cid].is_alive():
                    continue
                t = threading.Thread(
                    target=_follow, args=(cid, name, image), daemon=True)
                _threads[cid] = t
                t.start()
                esclient.log(f"logs: following {name}")
            for cid in [c for c, t in _threads.items() if not t.is_alive()]:
                _threads.pop(cid, None)
        except Exception as err:  # noqa: BLE001
            esclient.log(f"logs: rescan failed: {type(err).__name__}: {err}")
        time.sleep(RESCAN)


if __name__ == "__main__":
    main()
