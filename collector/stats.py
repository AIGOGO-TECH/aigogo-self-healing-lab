"""Container telemetry for the Grafana dashboard, straight from the Docker
API into Elasticsearch.

cAdvisor is the usual answer here, but on Docker Desktop for macOS it
cannot reach the daemon's metadata, so every metric comes back labelled
only with a container ID hash -- useless on a dashboard. This reads the
Docker API directly, so every sample carries the real container name, and
it lands in the Elasticsearch that Grafana is already pointed at. No second
datasource, no Prometheus, ~400MB of RAM saved.
"""

import os
import time
from datetime import datetime, timezone

import dockerapi
import esclient

INDEX = "docker-stats"
INTERVAL = int(os.environ.get("INTERVAL", "15"))


def cpu_percent(stats):
    try:
        c, p = stats["cpu_stats"], stats["precpu_stats"]
        delta = c["cpu_usage"]["total_usage"] - p["cpu_usage"]["total_usage"]
        sys_delta = c["system_cpu_usage"] - p["system_cpu_usage"]
        ncpu = c.get("online_cpus") or len(c["cpu_usage"].get("percpu_usage") or [1])
        if sys_delta > 0 and delta > 0:
            return round((delta / sys_delta) * ncpu * 100.0, 2)
    except (KeyError, TypeError, ZeroDivisionError):
        pass
    return 0.0


def sample():
    docs = []
    now = datetime.now(timezone.utc).isoformat()
    for cid, name, image in dockerapi.lab_containers():
        try:
            st = dockerapi.get(f"/containers/{cid}/stats?stream=false")
        except Exception:  # noqa: BLE001 - container may have just exited
            continue
        mem = st.get("memory_stats", {})
        usage = mem.get("usage", 0) - (mem.get("stats", {}) or {}).get("inactive_file", 0)
        nets = st.get("networks") or {}
        docs.append({
            "stamp": now,
            "container": name,
            "image": image,
            "cpu_percent": cpu_percent(st),
            "mem_bytes": usage,
            "mem_mb": round(usage / 1048576, 1),
            "mem_limit_mb": round(mem.get("limit", 0) / 1048576, 1),
            "net_rx_bytes": sum(n.get("rx_bytes", 0) for n in nets.values()),
            "net_tx_bytes": sum(n.get("tx_bytes", 0) for n in nets.values()),
        })
    return docs


def main():
    esclient.wait_until_ready()
    esclient.log(f"docker-stats -> {esclient.ES}/{INDEX} every {INTERVAL}s")
    while True:
        try:
            n = esclient.bulk(INDEX, sample())
            esclient.beat()
            esclient.log(f"indexed {n} containers")
        except Exception as err:  # noqa: BLE001
            esclient.log(f"stats: {type(err).__name__}: {err}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
