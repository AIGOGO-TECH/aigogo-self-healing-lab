#!/usr/bin/env python3
"""Create Kibana's data views so a fresh clone can actually search.

Kibana stores data views as saved objects in its own index, not in the
repo, so they were the third thing a clone silently did not get -- after
the Grafana datasource and the alert rule. Discover would open onto
nothing, with no error to explain why.

Idempotent: a data view that already exists is left alone. Kibana assigns
its own ids, so existence is checked by title.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

KIBANA = os.environ.get("KIBANA_URL", "http://kibana:5601")
USER = os.environ.get("KIBANA_USER", "elastic")
PASSWORD = os.environ["ELASTIC_PASSWORD"]

# title -> time field. The time field matters more than it looks: the Salt
# event stream timestamps with data._stamp, the collectors and the
# workflow-written indices use stamp, and the two data streams use
# @timestamp. A data view on the wrong one shows an empty Discover for a
# perfectly healthy index.
VIEWS = [
    # napalm-2*, not napalm-*: the wildcard also matches the napalm-audit
    # data stream, whose time field is @timestamp, not data._stamp. One
    # data view cannot serve both, and the one that tries shows an empty
    # Discover for whichever half it was not configured for.
    ("napalm-2*", "data._stamp", "Salt event bus — every job, beacon and return"),
    ("napalm-audit", "@timestamp", "Audit trail — who changed what, when, why"),
    ("lab-logs", "@timestamp", "Container logs — every service, one time axis"),
    ("docker-stats", "stamp", "Container telemetry"),
    ("napalm-remediations", "stamp", "Remediations n8n asked Salt to apply"),
    ("napalm-rejected", "stamp", "Decisions the whitelist or the model refused"),
    ("napalm-tickets", "stamp", "Human-readable incident summaries"),
]


def call(method, path, body=None):
    import base64

    token = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
    req = urllib.request.Request(
        KIBANA + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Content-Type": "application/json",
            "kbn-xsrf": "true",
            "Authorization": "Basic " + token,
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"{}")


def wait_for_kibana():
    print("kibana-init: waiting for kibana", flush=True)
    for attempt in range(120):
        try:
            status = call("GET", "/api/status")
            if status["status"]["overall"]["level"] == "available":
                print("kibana-init: kibana is available", flush=True)
                return
        except Exception:  # noqa: BLE001 - not ready yet
            pass
        time.sleep(5)
    sys.exit("kibana-init: FATAL: kibana never became available")


def main():
    wait_for_kibana()

    existing = {
        v["title"] for v in call("GET", "/api/data_views").get("data_view", [])
    }

    for title, time_field, description in VIEWS:
        if title in existing:
            print(f"kibana-init: data view {title} already exists", flush=True)
            continue
        try:
            call("POST", "/api/data_views/data_view", {
                "data_view": {
                    "title": title,
                    "name": f"{title} — {description}",
                    "timeFieldName": time_field,
                },
                "override": False,
            })
            print(f"kibana-init: created data view {title} ({time_field})",
                  flush=True)
        except urllib.error.HTTPError as err:
            # A view over an index that has not been written to yet cannot
            # be created. That is not fatal at bring-up: the index appears
            # as soon as something writes to it, and re-running this makes
            # the view. Fail the whole init and the stack never starts.
            detail = err.read()[:200].decode(errors="replace")
            print(f"kibana-init: skipped {title}: HTTP {err.code} {detail}",
                  flush=True)

    print("kibana-init: done", flush=True)


if __name__ == "__main__":
    main()
