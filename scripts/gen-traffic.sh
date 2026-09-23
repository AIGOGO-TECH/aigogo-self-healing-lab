#!/bin/sh
# Generate a realistic spread of Salt activity so the Kibana and Grafana
# views have a curve worth screenshotting rather than three lonely points.
# Read-only calls plus a couple of real fault/heal cycles.
END=$(( $(date +%s) + ${1:-600} ))
while [ "$(date +%s)" -lt "$END" ]; do
  docker exec salt-master salt 'srl*' test.ping        >/dev/null 2>&1
  docker exec salt-master salt 'srl*' net.interfaces   >/dev/null 2>&1
  docker exec salt-master salt 'srl*' bgp.neighbors    >/dev/null 2>&1
  docker exec salt-master salt 'srl1' net.cli "show version" >/dev/null 2>&1
  docker exec salt-master salt 'srl2' net.arp          >/dev/null 2>&1
  docker exec salt-master salt 'srl*' grains.items     >/dev/null 2>&1
  docker exec salt-master salt 'srl3' net.lldp         >/dev/null 2>&1
  sleep 5
done
