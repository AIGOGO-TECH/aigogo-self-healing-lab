# The change-control gate. Read by audit.change_allowed(), which every
# remediation state calls before it touches a device.
maintenance:
  # A freeze. While this is true, no automated remediation is applied to
  # any device -- the run still happens, still records to the audit trail,
  # and reports why it did nothing.
  #
  # This is the control that was missing entirely. During planned work,
  # "the running config does not match the source of truth" is the expected
  # state, and an automation that reverts an engineer's change halfway
  # through a maintenance window is worse than having no automation.
  #
  #   salt '*' pillar.items                 # confirm what the minions see
  #   # flip to true, then:
  #   salt '*' saltutil.refresh_pillar
  enabled: false
  reason: ""

  # Per-device ceiling over a rolling hour, counted from the audit trail.
  # A device that drifts back three times in an hour does not need a fourth
  # push; it needs a human. Without this the drift reactor re-applies every
  # 20 seconds indefinitely.
  # This is Salt's ceiling and it is the authoritative one: it refuses the
  # change itself. n8n enforces a second, independent ceiling before it
  # asks the model anything, and that one reads MAX_CHANGES_PER_HOUR from
  # .env. Raising only this number changes half the system -- the other
  # half goes on refusing, with a reason that reads exactly like this one.
  max_changes_per_hour: 3

  # Blast radius. The per-device ceiling above is the wrong instrument for
  # the failure that actually hurts at scale: one bad row in the source of
  # truth, or one beacon with a wrong threshold, produces a fault on every
  # device at once -- and each of those remediations is individually within
  # its per-device budget. Idempotent, correct by its own lights, applied to
  # the whole network in a minute.
  #
  # So there is a second ceiling on how many DISTINCT devices may be changed
  # at all in the window, regardless of which. Two is deliberately small:
  # the third device is where a systemic mistake stops and a human starts.
  # Raise it when the fleet is large enough that two is noise, not before.
  fleet_window_minutes: 15
  max_devices_per_window: 2

  # How long after a link comes back before a BGP session on that device is
  # treated as an independent fault. IS-IS has to re-form the adjacency and
  # BGP has to leave Connect; remediating during that window pushes a change
  # for a fault that is already fixing itself.
  bgp_settle_seconds: 120
