"""Minimal Docker API client over the unix socket.

Not the docker SDK: this runs in a bare python:3.12-slim with no pip
install, so the image never has to be built or pulled beyond the base.

Everything here talks to the daemon directly because the usual answers do
not work on Docker Desktop for macOS. cAdvisor cannot resolve container
names there, and Filebeat's container input needs
/var/lib/docker/containers, which lives inside the LinuxKit VM and is not
bind-mountable from the Mac. The Docker API is the one interface that
behaves identically on macOS and Linux.
"""

import http.client
import json
import socket

DOCKER_SOCK = "/var/run/docker.sock"

# Only the lab's own containers. Throwaway `docker run --rm ...` helpers
# appear and vanish constantly, and each one became its own series on the
# dashboard -- noise that makes the real picture unreadable.
LAB_PREFIXES = (
    "clab-selfheal-", "salt-", "elasticsearch", "kibana", "grafana",
    "netbox", "n8n", "docker-stats", "docker-logs", "es-init",
)


def is_lab(name):
    return name.startswith(LAB_PREFIXES)


class _UnixHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(DOCKER_SOCK)
        self.sock = s


def connect(timeout=30):
    return _UnixHTTPConnection("localhost", timeout=timeout)


def get(path, timeout=30):
    """One-shot JSON GET."""
    c = connect(timeout)
    try:
        c.request("GET", path)
        return json.loads(c.getresponse().read())
    finally:
        c.close()


def stream(path):
    """Open a streaming GET and hand back (connection, response).

    The caller owns both and must close the connection. Used for the log
    follow endpoint, which never returns on its own.
    """
    c = connect(timeout=None)
    c.request("GET", path)
    return c, c.getresponse()


def lab_containers():
    """[(id, name, tty), ...] for the lab's running containers."""
    out = []
    for c in get("/containers/json"):
        name = c["Names"][0].lstrip("/")
        if is_lab(name):
            out.append((c["Id"], name, c.get("Image", "")))
    return out


def has_tty(cid):
    """Docker frames log output unless the container was started with a TTY."""
    try:
        return bool(get(f"/containers/{cid}/json")["Config"]["Tty"])
    except Exception:  # noqa: BLE001 - a racing container removal is normal
        return False
