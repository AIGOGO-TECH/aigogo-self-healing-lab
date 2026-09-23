# Source of truth #2: plain pillar/YAML, not an HTTP API. This is what a
# team without a NetBox instance would actually run — and it's the same
# amount of Salt code, because pillar itself IS a pluggable
# source-of-truth layer (it can be backed by git_pillar, SQL, Vault, etc.
# with zero change to the states/beacons that consume it).
device_truth:
  interfaces:
    ethernet-1/1: "uplink to srl2 hub (P2P transit) — pillar-YAML SoT v2"
