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
#   │ 1  WHY / WHAT BROKE  │ 2  THE ROUTERS' LOG  │
#   ├──────────────────────┼──────────────────────┤
#   │ 3  THE STORY         │ 4  THE DEVICES       │
#   │    audit trail       │    or the policy     │
#   └──────────────────────┴──────────────────────┘
#
# Nothing is typed into any of the four. The fault is injected from a fifth
# window outside the recording frame, which frees pane 1 for the question
# each fault class actually turns on:
#
#   heal       the blast-radius gate    — why the second fault is refused
#   provision  the source of truth      — nobody typed this on a router
#   leak       the provider's view      — the only account that settles it
#
# A pane holding a shell prompt is a pane spent on the presenter instead of
# the audience, and it is the least informative quarter of the screen.
#
# Grafana and n8n had panes of their own and lost them, because the audit
# trail says what they were there to say and says it better. Grafana's pane
# showed one word -- FIRING -- and n8n's showed a log that never quite
# lines up with the decision. Pane 3 shows
#
#     decision.made  accepted  n8n/qwen2.5:7b  "interface was administratively shut"
#
# which is the alert, the model, and its reasoning in one line.
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
  --leak|leak)           MODE=leak;      shift ;;
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
# Pane 1 by fault class. Each is a script rather than an inline loop, so
# it can be run on its own while rehearsing -- and so a mistake in it fails
# where it can be read instead of inside a tmux send-keys string.
if [ "$MODE" = provision ]; then
    # Intent, opposite the devices converging to it in pane 4.
    P1="while :; do out=\$(./scripts/show-intent.sh 2>/dev/null); clear; printf '%s\\n' \"\$out\"; sleep 6; done"
else
    # The counter that causes the refusal, visible before it trips.
    # Slower cycle than the rest: it is three Salt calls through proxies,
    # and the numbers it shows change on the scale of minutes, not seconds.
    P1="while :; do out=\$(./scripts/show-gate.sh 2>/dev/null); clear; printf '%s\\n' \"\$out\"; sleep 8; done"
fi

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
#       [x] decided    12:56:10  n8n/qwen2.5:7b — Ethernet port is administratively shut
#       [x] verified   12:56:21  ethernet-1/1 is up
#
# It is unfiltered by device on purpose: one interface shut raises two
# faults, and the one that gets REFUSED is the harder thing to believe.
P3="./scripts/watch-heal.sh 10"

# All three routers, not just the one named on the command line. One shut
# interface produces TWO faults -- the device that was shut and the far end
# reporting its link down -- and the narrator has to be able to point at
# both, because the one that gets REFUSED is the half worth believing.
# Three short rows also avoid having to work out which neighbour sits on
# the far end of which link.
#
# Built into a variable first, then cleared and printed in one go: filling
# it live means three docker execs at a second or two each, which leaves
# the pane blank for most of every cycle and reads as showing nothing.
P4="while :; do
 out=\$(printf '%-6s %-14s %s\\n' 'router' 'ethernet-1/1' 'IS-IS adj';
   for d in srl1 srl2 srl3; do
     a=\$(docker exec clab-selfheal-\$d sr_cli -e 'info from state /interface ethernet-1/1 admin-state' 2>/dev/null | grep -oE 'enable|disable' | head -1);
     j=\$(docker exec clab-selfheal-\$d sr_cli -e 'show network-instance default protocols isis adjacency' 2>/dev/null | grep -c '^| ethernet');
     printf '%-6s %-14s %s\\n' \"\$d\" \"\${a:-?}\" \"\${j:-?}\";
   done;
   echo;
   echo 'newest change on $DEV, as the router recorded it:';
   docker exec clab-selfheal-$DEV sr_cli 'info from state /system configuration checkpoint *' 2>/dev/null | grep -m1 'comment \"selfheal' | sed 's/.*comment \"selfheal //; s/\"\$//' | fold -w 40 -s | sed 's/^/   /');
 clear; echo '── 4  THE ROUTERS THEMSELVES ──'; echo; printf '%s\\n' \"\$out\";
 sleep 4; done"

# The route-leak screen. Same four boxes, four different questions, and
# none of them need a second window:
#
#   what broke -> what the model was shown and said -> what the system
#   did -> what the provider actually received
#
# The last one is the argument. The other three explain how it got there.
# Built as its own mode because switching a pane mid-take means stopping
# a loop, typing, and getting back — three chances to fumble on camera.
if [ "$MODE" = leak ]; then
    # No input pane. `break.sh leak` is typed in a separate window, which
    # frees the fourth box for the one thing the other three cannot show.
    #
    #   1  what the provider received          the damage
    #   2  what the model was shown and said   the decision
    #   3  what the system did about it        the process
    #   4  the policy line that caused it      the cause
    #
    # The fourth is the point of this fault class: the configuration is
    # syntactically fine, internally consistent, passes a diff against the
    # golden config, and the session stays up. One word changes -- reject
    # to accept -- and the damage is entirely in the adj-rib-out. Showing
    # that word flip back is showing the fix land on the device.
    P1="while :; do out=\$(./scripts/show-leak.sh 2>/dev/null); clear; printf '%s\\n' \"\$out\"; sleep 3; done"
    P2="while :; do out=\$(./scripts/show-decision.sh $DEV 2>/dev/null); clear; printf '%s\\n' \"\$out\"; sleep 3; done"
    P3="./scripts/watch-heal.sh 10"
    # Two lines out of fourteen. The whole policy does not fit a quarter
    # screen, and thirteen of its lines never change -- the one that does
    # is the default action, and it changes by one word.
    P4="while :; do
 pol=\$(docker exec clab-selfheal-$DEV sr_cli -- info /routing-policy policy transit-out 2>/dev/null);
 da=\$(printf '%s' \"\$pol\" | awk '/default-action/{d=1} d&&/policy-result/{print \$2; exit}');
 clear;
 echo '── 4  THE POLICY ON $DEV — ONE WORD ──'; echo;
 echo '  policy transit-out'; echo;
 echo '      statement 10    our-aggregates  ->  accept';
 if [ \"\$da\" = accept ]; then
   printf '      default-action  \033[31m%-14s\033[0m  <= EVERYTHING ELSE TOO\n' \"\$da\";
   echo; echo '  Every route srl3 knows is offered to the provider.';
 else
   printf '      default-action  \033[32m%-14s\033[0m  <= and nothing else\n' \"\$da\";
   echo; echo '  Only the aggregate leaves this AS.';
 fi;
 echo; echo '  The config is valid either way. The diff against the';
 echo '  golden protocol config passes. The session stays up.';
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
tmux send-keys -t "$SESSION:demo.0" "$P1" C-m
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
# Click a pane to focus it, scroll it with the wheel.
#
# The prefix chord is Ctrl-b, and on a Mac that is also readline's
# backward-char — so in a window that is not actually attached to tmux it
# silently moves the cursor instead, which looks like tmux ignoring you.
# Nothing here needs a chord now: click the pane, type in it.
tmux set -t "$SESSION" mouse on

# And a visible border, so it is obvious which pane has focus — with the
# status bar off there is otherwise no clue at all.
tmux set -t "$SESSION" status off
tmux set -t "$SESSION" pane-border-style 'fg=colour238'
tmux set -t "$SESSION" pane-active-border-style 'fg=colour35'

if [ "$ATTACH" = "0" ]; then
    echo "session '$SESSION' built, not attached"
    exit 0
fi
case "$MODE" in
  provision) INJECT="./scripts/bootstrap.sh" ;;
  leak)      INJECT="./scripts/break.sh leak $DEV" ;;
  *)         INJECT="./scripts/break.sh interface $DEV" ;;
esac
echo
echo "all four panes run themselves. Open a SECOND terminal window, keep it"
echo "outside the recording frame, and inject the fault from there:"
echo
echo "    cd $(pwd)"
echo "    $INJECT"
echo
echo "or, without leaving this window, from anywhere:"
echo
echo "    tmux send-keys -t $SESSION:demo.0 C-c"
echo "    tmux send-keys -t $SESSION:demo.0 '$INJECT' C-m"
echo
echo "  the focused pane has a green border    Ctrl-c stops a pane's loop"
echo "  Ctrl-b then d detaches                tmux kill-session -t $SESSION"
sleep 1
tmux attach -t "$SESSION"
