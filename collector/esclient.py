"""Bulk writer for Elasticsearch, with credentials and back-pressure.

Both collectors write through this. It exists mainly so a transient
Elasticsearch failure -- a restart, a full disk, a 429 -- never kills the
collector loop and never silently drops the batch without saying so.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

ES = os.environ.get("ES_URL", "http://elasticsearch:9200")
_USER = os.environ.get("ES_USER", "")
_PASS = os.environ.get("ES_PASSWORD", "")


def _headers(content_type):
    h = {"Content-Type": content_type}
    if _USER:
        token = base64.b64encode(f"{_USER}:{_PASS}".encode()).decode()
        h["Authorization"] = "Basic " + token
    return h


HEARTBEAT = "/tmp/heartbeat"


def log(*a):
    print(*a, flush=True)


def beat():
    """Touch the file the container healthcheck watches.

    Checked instead of the process, because the process being alive is not
    the question: both collectors are loops around a socket read, and a
    thread wedged on a half-open connection leaves a perfectly healthy PID
    behind. A stale heartbeat is the only symptom that distinguishes the
    two, and `pgrep` is not in python:3.12-slim anyway.
    """
    try:
        with open(HEARTBEAT, "w") as fh:
            fh.write(str(time.time()))
    except OSError:
        pass


def bulk(index, docs, op="index"):
    """Write docs. op='create' is required for data streams.

    Returns the number of documents Elasticsearch accepted rather than
    assuming they all landed. A rejected document is reported, because a
    bulk write reports success at the HTTP level while rejecting items
    inside the response body.
    """
    if not docs:
        return 0

    lines = []
    for d in docs:
        lines.append(json.dumps({op: {"_index": index}}))
        lines.append(json.dumps(d, default=str))
    payload = ("\n".join(lines) + "\n").encode()

    req = urllib.request.Request(
        f"{ES}/_bulk",
        data=payload,
        headers=_headers("application/x-ndjson"),
        method="POST",
    )

    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read())
            if body.get("errors"):
                failed = [
                    it[op]["error"]
                    for it in body["items"]
                    if it.get(op, {}).get("error")
                ]
                log(f"es: {len(failed)}/{len(docs)} rejected, first: {failed[0]}")
                return len(docs) - len(failed)
            return len(docs)
        except urllib.error.HTTPError as err:
            detail = err.read()[:300].decode(errors="replace")
            log(f"es: HTTP {err.code} {detail}")
            if err.code in (429, 502, 503, 504):
                time.sleep(2 ** attempt)
                continue
            return 0
        except Exception as err:  # noqa: BLE001 - keep the loop alive
            log(f"es: {type(err).__name__}: {err}")
            time.sleep(2 ** attempt)
    log(f"es: giving up on {len(docs)} docs")
    return 0


def search(index, body):
    """Run one query. Returns None if Elasticsearch could not be reached.

    None is not {} and callers must not treat it as "no results": for the
    watchdog the difference between "nothing is wrong" and "I cannot see"
    is the entire point.
    """
    req = urllib.request.Request(
        f"{ES}/{index}/_search",
        data=json.dumps(body).encode(),
        headers=_headers("application/json"),
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except Exception as err:  # noqa: BLE001
        log(f"es: search failed: {type(err).__name__}: {err}")
        return None


def wait_until_ready(timeout=300):
    """Block until Elasticsearch answers. Collectors start with the stack."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req = urllib.request.Request(
                f"{ES}/_cluster/health", headers=_headers("application/json"))
            urllib.request.urlopen(req, timeout=10).read()
            return
        except Exception:  # noqa: BLE001
            time.sleep(3)
    sys.exit("es: never became reachable")
