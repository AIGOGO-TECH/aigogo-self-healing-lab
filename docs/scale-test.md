# What a scale test would have to prove

Running this on thirty routers instead of three proves almost nothing on
its own. The loop already works; doing it more times is not evidence about
the thing people are actually sceptical of, which is what happens when the
system is *wrong* about many devices at once.

So if a machine is rented for this, it should be rented to run four
specific experiments, each with a number attached, and each designed so
that the interesting result is a **refusal**, not a success.

## Sizing

An SR Linux 24.10 container needs roughly 1.5-2 GB. The rest of the stack
is about 6 GB with the limits in `docker-compose.yml`.

| Devices | RAM for devices | Total | Notes |
|---|---|---|---|
| 10 | ~18 GB | 32 GB | enough for experiments 1 and 2 |
| 20 | ~36 GB | 64 GB | enough for all four |
| 30 | ~54 GB | 96 GB | only if 20 proves too small to be convincing |

A few days on a 64 GB dedicated box costs less than lunch. x86 is also the
better-tested SR Linux build — the arm64 image is what forced the 24.10.1
pin in the first place (`docs/lessons.md` §1).

One thing has to change before any of it is meaningful: `pillar/topology.sls`
and `clab/topo.yml` are written for three named devices. Generating them is
half a day, and it is the actual prerequisite.

## Experiment 1 — the correlated fault storm

Shut a monitored interface on **every** device within one second.

* Expected: `max_devices_per_window: 2` stops it after two devices, and
  every other device records `change.blocked` with a reason naming the
  count. Eighteen refusals and two changes is a pass.
* Failure to look for: eighteen changes. That is the scenario the reviewer
  meant by "might break things at scale", and it is the whole reason the
  blast radius control exists.
* Also measure: how long the audit trail takes to make the *root* cause
  findable, versus how long it takes to notice twenty alerts.

## Experiment 2 — a wrong source of truth

Change one interface description for every device in NetBox to something
incorrect, and let the drift beacons find it.

* This is the dangerous case precisely because nothing is broken. Every
  remediation is correct, idempotent, and does exactly what it says.
* Expected: two devices converge to the wrong value and the rest are
  refused. The value of the test is measuring **how many devices get the
  wrong config before something stops it** — that number is the honest
  answer to "how much damage can this do".
* Note that outcome verification does *not* help here, deliberately: for
  drift, config convergence is the intent. Only the blast radius limit
  stands between one bad row and the whole fleet.

## Experiment 3 — throughput

Beacons at 15-20s intervals across every device, with traffic running.

* Measure: Salt event rate, whether the Elasticsearch returner keeps up,
  master CPU, mine refresh cost, and whether any event is silently dropped
  — the failure in `docs/lessons.md` §11 lost two hours of events with no
  error anywhere.
* Kill Elasticsearch mid-run. Expected: `change_allowed` fails closed and
  every remediation refuses, rather than proceeding unrecorded.

## Experiment 4 — the model as a bottleneck

Twenty simultaneous faults, one Ollama instance.

* Measure: queue depth and the distribution of time-to-decision. One
  instance serialises; the question is whether the tail is minutes.
* Also worth measuring: decision *quality* under a fault storm, where the
  prompt for one device arrives while twenty others are broken. The model
  is given one fault at a time and no fleet context, which is a design
  choice worth testing rather than assuming.

## What to bring back

Four numbers, and they are more interesting than a video of a working demo:

1. devices changed before the blast radius limit engaged
2. devices given a wrong-but-idempotent config before anything refused
3. events lost, if any, at full beacon rate
4. p50 and p99 time-to-decision under twenty concurrent faults

A talk that says "we measured how much damage this can do before it stops
itself, and the number is two" is a different talk from one that says it
healed an interface.
