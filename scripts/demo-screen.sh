#!/usr/bin/env sh
# Build the six-pane demo screen, in one command.
#
#   ./scripts/demo-screen.sh [device]        default: srl1
#
# Four panes. Six was tried first and the panes came out about 76 columns
# wide on a 3024-wide Retina display, which is legible on the machine and
# not on a projector. Four gives ~114 columns each.
#
#   ┌──────────────────────┬──────────────────────┐
#   │ 1  FAULT             │ 2  DETECT            │
#   │    you type here     │    the event bus     │
#   ├──────────────────────┼──────────────────────┤
#   │ 3  THE STORY         │ 4  VERIFY            │
#   │    audit trail       │    the device itself │
#   └──────────────────────┴──────────────────────┘
#
# Grafana and n8n had panes of their own and lost them, because the audit
# trail says what they were there to say and says it better. Grafana's pane
# showed one word -- FIRING -- and n8n's showed a log that never quite
# lines up with the decision. Pane 3 shows
#
#     decision.made  accepted  n8n/llama3.1  "interface was administratively shut"
#
# which is the alert, the model, and its reasoning in one line.
#
# Pane 1 is the only one you type in. The other three run themselves.
#
# Everything is a terminal on purpose. Browser windows for Grafana and n8n
# look impressive and read badly: they need logins, they reflow, and the
# thing worth watching is two lines of text in the middle of a large empty
# page. The same information as text stays legible when the recording is
# scaled down for a projector.
set -eu
cd "$(dirname "$0")/.."
MODE=heal
case "${1:-}" in
  --provision|provision) MODE=provision; shift ;;
esac
DEV=${1:-srl1}
ATTACH=${ATTACH:-1}
SESSION=selfheal-demo

command -v tmux >/dev/null || { echo "tmux is not installed: brew install tmux" >&2; exit 1; }
tmux kill-session -t "$SESSION" 2>/dev/null || true

# --- the five self-running panes ----------------------------------------
# The Salt event bus was here. It is the right feed for debugging and the
# wrong one for a pane: it is our side of the conversation, and the pane
# opposite it already shows our side better. The router's own log is the
# one account in the room that is not ours -- and because the commit
# message carries the trace id and the actor, its lines name the decision
# that caused them. The event bus moved to watch-events.sh, still there
# when you want it.
P2="./scripts/watch-device.sh"

# The story, not the rows.
#
# This pane used to run evidence.sh, which prints one line per audit record
# -- the right shape for reading afterwards and the wrong one for standing
# in front of a room. Watching timestamps accumulate, you cannot say what
# stage the system is at or whether it is working or stuck, and the person
# presenting has to interpret it live.
#
# watch-heal.sh groups by trace and renders the stages, so the pane can be
# read out loud:
#
#     srl1  ethernet-1/1 on srl1 is administratively down
#       [x] detected   12:55:30  salt-beacon:srl1
#       [x] decided    12:56:10  n8n/llama3.1 — Ethernet port is administratively shut
#       [x] verified   12:56:21  ethernet-1/1 is up
#
# It is unfiltered by device on purpose: one interface shut raises two
# faults, and the one that gets REFUSED is the harder thing to believe.
P3="./scripts/watch-heal.sh 10"

# One interface shut always produces TWO faults: the device that was shut,
# and the far end reporting its link down. The pane used to show only the
# device named on the command line, so during a take the narrator could
# not point at the other half of the story -- "cannot see what is
# happening on srl1 ethernet-1/1" was the exact complaint, while srl1 was
# the router being correctly refused.
#
# Three short rows instead of one long one. It is also robust: no need to
# work out which neighbour is on the far end of which link.
P4="while :; do clear; echo '── THE ROUTERS THEMSELVES ──'; echo;
 printf '%-6s %-14s %s\\n' 'router' 'ethernet-1/1' 'IS-IS adj';
 for d in srl1 srl2 srl3; do
   a=\$(docker exec clab-selfheal-\$d sr_cli -e 'info from state /interface ethernet-1/1 admin-state' 2>/dev/null | grep -o 'enable\\|disable' | head -1);
   j=\$(docker exec clab-selfheal-\$d sr_cli -e 'show network-instance default protocols isis adjacency' 2>/dev/null | grep -c '^| ethernet');
   printf '%-6s %-14s %s\\n' \"\$d\" \"\${a:-?}\" \"\${j:-?}\";
 done;
 echo; echo 'newest checkpoint on $DEV:';
 docker exec clab-selfheal-$DEV sr_cli 'info from state /system configuration checkpoint *' 2>/dev/null | grep -m1 -A1 'comment \"selfheal' | fold -w 88 | sed 's/^/   /';
 sleep 4; done"

# The provisioning screen is a different four panes from the healing one.
# Nothing has healed yet -- the routers are empty and the story is where
# the configuration comes from. Pane 1 runs bootstrap, pane 2 watches an
# adjacency count go from nothing to two, pane 3 narrates the converge,
# pane 4 watches the protocol layer appear on the border router.
if [ "$MODE" = provision ]; then
    # No `watch`: macOS does not ship it, and a pane that dies with
    # "command not found" during a take is not recoverable afterwards.
    # A shell loop is one line longer and always there.
    P2="while :; do clear; echo '── 2  IS-IS ADJACENCIES ON $DEV ──'; echo;
 docker exec clab-selfheal-$DEV sr_cli -e 'show network-instance default protocols isis adjacency' 2>/dev/null | tail -8 || echo '   (router not up yet)';
 sleep 2; done"
    P3="./scripts/watch-provision.sh"
    P4="while :; do clear; echo '── 4  BGP ON $DEV, FROM THE DEVICE ──'; echo;
 docker exec clab-selfheal-$DEV sr_cli -- info /network-instance default protocols bgp 2>/dev/null | head -16 || echo '   (router not up yet)';
 sleep 3; done"
fi

# --- build the grid: 2 x 2 ----------------------------------------------
# Build all four panes first, THEN send each command to an explicit index.
# Sending to "the active pane" as you split looks tidier and puts the
# content in the wrong boxes, because every split moves the focus and
# renumbers what follows it.
tmux new-session  -d -s "$SESSION" -n demo
tmux split-window -h -t "$SESSION:demo"
tmux select-pane  -t "$SESSION:demo.0"
tmux split-window -v -t "$SESSION:demo.0"
tmux select-pane  -t "$SESSION:demo.2"
tmux split-window -v -t "$SESSION:demo.2"
tmux select-layout -t "$SESSION:demo" tiled

# After `tiled`, the indices are in reading order:
#   0 top-left   1 top-right
#   2 bottom-left  3 bottom-right
if [ "$MODE" = provision ]; then
    tmux send-keys -t "$SESSION:demo.0" "clear; echo '── 1  YOU TYPE HERE ──'; echo; echo '   ./scripts/bootstrap.sh'; echo; echo '   wait for: == converging the devices to their source of truth'; echo" C-m
else
    tmux send-keys -t "$SESSION:demo.0" "clear; echo '── 1  YOU TYPE HERE ──'; echo; echo '   ./scripts/break.sh interface $DEV'; echo" C-m
fi
# clear first: without it the pane keeps the shell prompt and the typed
# command at the top for the whole recording. Panes 2 and 3 redraw
# themselves every cycle, so only this streaming one needs it.
tmux send-keys -t "$SESSION:demo.1" "clear; $P2" C-m
tmux send-keys -t "$SESSION:demo.2" "$P3" C-m
tmux send-keys -t "$SESSION:demo.3" "$P4" C-m

# A ruler, so the font can be set by measuring instead of guessing.
# The panes need about 92 columns for the audit trail not to wrap. On a
# 3024-wide Retina display that is Menlo 13pt; on anything else, change the
# font until this stops complaining.
W=$(tmux display-message -p -t "$SESSION:demo.0" '#{pane_width}')
H=$(tmux display-message -p -t "$SESSION:demo.0" '#{pane_height}')
echo "pane size: ${W}x${H} columns"
if [ "$W" -lt 92 ]; then
    echo "  ⚠  under 92 columns — the audit trail will wrap."
    echo "     Terminal → Settings → Profiles → Text → make the font smaller,"
    echo "     or put this window full-screen on the larger display."
else
    echo "  ✓  wide enough"
fi

tmux select-pane -t "$SESSION:demo.0"
tmux set -t "$SESSION" status off
tmux set -t "$SESSION" pane-border-style 'fg=colour238'
tmux set -t "$SESSION" pane-active-border-style 'fg=colour238'

if [ "$ATTACH" = "0" ]; then
    echo "session '$SESSION' built, not attached"
    exit 0
fi
echo "attaching. Ctrl-b then d to detach, or:  tmux kill-session -t $SESSION"
sleep 1
tmux attach -t "$SESSION"
