#!/usr/bin/env python3
"""Bring Elasticsearch to a known state before anything writes to it.

Runs once at stack start; salt-master waits for it to exit successfully.
Every operation is a PUT, so re-running is a no-op.

Three jobs:
  1. index templates  -- so Elasticsearch never has to guess a mapping
  2. ILM policies     -- so the disk does not fill silently
  3. roles and users  -- one per component, least privilege

Job 1 matters most. Without a template, Elasticsearch infers the mapping
from the first document it receives; a later document whose field is a list
where the first had an object is then rejected for conflicting with a
mapping nobody chose, and the rejection appears only in a bulk response
body that callers routinely discard.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

ES = os.environ.get("ES_URL", "http://elasticsearch:9200")
AUTH = base64.b64encode(
    f"elastic:{os.environ['ELASTIC_PASSWORD']}".encode()
).decode()


def say(msg):
    print(f"es-init: {msg}", flush=True)


def call(method, path, body=None, ok_status=(200, 201)):
    req = urllib.request.Request(
        ES + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Basic " + AUTH,
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in ok_status:
            raise RuntimeError(f"{method} {path} -> {r.status}")
        return json.loads(r.read() or b"{}")


def wait_for_cluster():
    say("waiting for elasticsearch")
    for attempt in range(90):
        try:
            h = call("GET", "/_cluster/health?wait_for_status=yellow&timeout=5s")
            say(f"elasticsearch is up (status {h['status']})")
            return
        except Exception as err:  # noqa: BLE001 - any failure means not ready
            if attempt % 10 == 0 and attempt:
                say(f"still waiting ({type(err).__name__})")
            time.sleep(2)
    sys.exit("es-init: FATAL: elasticsearch did not become ready")


def prepare_snapshot_dir():
    """Hand /snapshots to Elasticsearch's uid.

    Docker creates a named volume owned by root. Elasticsearch runs as uid
    1000 and cannot write there, so repository registration fails with
    access_denied even though path.repo is set and the volume is mounted --
    and the error names a temp file, not a permission, so it reads like a
    configuration problem rather than an ownership one.
    """
    path = "/snapshots"
    if not os.path.isdir(path):
        say(f"WARNING: {path} is not mounted; backups will be unavailable")
        return
    try:
        os.chown(path, 1000, 0)
        os.chmod(path, 0o770)
        say(f"{path} handed to uid 1000")
    except PermissionError:
        say(f"WARNING: could not chown {path}; backups may be unavailable")


def main():
    wait_for_cluster()
    prepare_snapshot_dir()

    # --- 2. ILM, before the templates that reference the policies ----------
    for name, policy in json.load(open("/es/ilm-policies.json")).items():
        call("PUT", f"/_ilm/policy/{name}", policy)
        say(f"ILM policy {name}")

    # --- 1. index templates ------------------------------------------------
    for name, path in [
        ("napalm-events", "/es/napalm-events-template.json"),
        ("napalm-audit", "/es/audit-template.json"),
        ("lab-logs", "/es/logs-template.json"),
        ("napalm-escalations", "/es/escalations-template.json"),
    ]:
        call("PUT", f"/_index_template/{name}", json.load(open(path)))
        say(f"index template {name}")

    # Create the two data streams up front. Writers hold create_doc only,
    # which is not enough to create a stream -- and that is deliberate.
    # napalm-audit is append-only by construction: a data stream rejects
    # update-by-id and delete-by-id outright, and no role in es/roles.json
    # carries a delete privilege. Nothing in this stack can rewrite its own
    # audit trail, including the component that wrote it.
    for ds in ("napalm-audit", "lab-logs"):
        try:
            call("GET", f"/_data_stream/{ds}")
            say(f"data stream {ds} already exists")
        except urllib.error.HTTPError as err:
            if err.code != 404:
                raise
            call("PUT", f"/_data_stream/{ds}")
            say(f"created data stream {ds}")

    # --- 2b. snapshot repository -------------------------------------------
    # An append-only audit trail that cannot be backed up is not an audit
    # trail, it is a single disk waiting to fail.
    #
    # Not fatal if it fails. Registering an fs repository needs path.repo,
    # which only takes effect when Elasticsearch itself is recreated -- so
    # on an upgrade of an already-running cluster this returns 500 until
    # that happens. Letting it abort would be worse than the missing
    # feature: es-init is a one-shot that everything else waits on, so a
    # failure here stops the entire stack from starting, backups and
    # remediation alike.
    try:
        call("PUT", "/_snapshot/selfheal", {
            "type": "fs",
            "settings": {"location": "/snapshots", "compress": True},
        })
        say("snapshot repository selfheal -> /snapshots")
    except Exception as err:  # noqa: BLE001
        say(f"WARNING: could not register the snapshot repository: {err}")
        say("WARNING: backups are unavailable until elasticsearch is "
            "recreated with path.repo=/snapshots")

    # --- 3. roles and users ------------------------------------------------
    for name, body in json.load(open("/es/roles.json")).items():
        call("PUT", f"/_security/role/{name}", body)
        say(f"role {name}")

    users = {
        "salt_writer": "SALT_ES_PASSWORD",
        "grafana_reader": "GRAFANA_ES_PASSWORD",
        "n8n_agent": "N8N_ES_PASSWORD",
        "stats_writer": "STATS_ES_PASSWORD",
        "log_writer": "LOGS_ES_PASSWORD",
        "watchdog": "WATCHDOG_ES_PASSWORD",
        "push_detect": "PUSH_DETECT_ES_PASSWORD",
    }
    # Checked up front rather than one at a time: a half-created user set
    # is worse than none, because the missing user's component then fails
    # with a 401 somewhere far away from the cause.
    missing = [v for v in users.values() if not os.environ.get(v)]
    if missing:
        sys.exit(
            "es-init: FATAL: these passwords are not set: "
            + ", ".join(sorted(missing))
            + "\n  Add them to .env (scripts/gen-secrets.sh generates them) "
            "and to the es-init service's environment in docker-compose.yml."
        )

    for user, envvar in users.items():
        call(
            "PUT",
            f"/_security/user/{user}",
            {
                "password": os.environ[envvar],
                "roles": [user],
                "full_name": f"selfheal {user}",
            },
        )
        say(f"user {user}")

    # kibana_system is a built-in user; only its password needs setting.
    call(
        "POST",
        "/_security/user/kibana_system/_password",
        {"password": os.environ["KIBANA_SYSTEM_PASSWORD"]},
    )
    say("user kibana_system password set")

    say("done")


if __name__ == "__main__":
    main()
