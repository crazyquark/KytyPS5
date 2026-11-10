#!/bin/bash
# deck-job.sh <window> <log> <command> [args...]: a long job on the Steam Deck in a window of the tmux session "kyty"
# (socket -L kyty), its output also appended to <log>; prints the pane's process id (gone when the job ends: wait on it
# with tail --pid). The tmux server runs as the user unit kyty-tmux (tmux -D under systemd-run --user): SteamOS ends
# every process of an SSH session when it closes (KillUserProcesses=True), a tmux server started from SSH with them.
# Watch from the Deck or over SSH: tmux -L kyty attach (Ctrl-b d leaves it running). A finished window stays, with the
# job's exit status, until the next job of that name.
set -euo pipefail
[ $# -ge 3 ] || { echo "deck-job.sh <window> <log> <command> [args...]" >&2; exit 2; }
window="$1" log="$2"
shift 2
# Homebrew's tmux (3.8): SteamOS's own (/usr/bin/tmux 3.7b) exited at once as a -D server under systemd ("open
# terminal failed: not a terminal"), and a client must speak its server's version.
tmux_bin=/home/linuxbrew/.linuxbrew/bin/tmux
[ -x "$tmux_bin" ] || tmux_bin="$(command -v tmux || true)"
[ -n "$tmux_bin" ] && [ -x "$tmux_bin" ] || { echo "no tmux (brew install tmux)" >&2; exit 1; }
t() { "$tmux_bin" -L kyty "$@"; }

if ! t has-session -t kyty 2>/dev/null; then
	systemctl --user is-active -q kyty-tmux 2>/dev/null ||
		systemd-run --user --unit=kyty-tmux --collect "$tmux_bin" -L kyty -D > /dev/null
	# Wait for that server's socket before any client call: a client that finds no server starts one of its own, a
	# daemon of this SSH session (gone when it closes), and the unit's -D server then exits ("not a terminal").
	socket="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/kyty"
	for _ in $(seq 50); do
		[ -S "$socket" ] && systemctl --user is-active -q kyty-tmux && break
		sleep 0.2
	done
	[ -S "$socket" ] && systemctl --user is-active -q kyty-tmux ||
		{ echo "the kyty tmux server did not start (journalctl --user -u kyty-tmux)" >&2; exit 1; }
	t new-session -d -s kyty -n main
	t has-session -t kyty || { echo "the kyty tmux server did not start (systemctl --user status kyty-tmux)" >&2; exit 1; }
fi

# One job per window name: a finished window of that name goes, a running one is left alone.
if t list-windows -t kyty -F '#{window_name} #{pane_dead}' | grep -qx "$window 0"; then
	echo "a job named $window is still running (tmux -L kyty attach)" >&2
	exit 1
fi
t list-windows -t kyty -F '#{window_name}' | grep -qx "$window" && t kill-window -t "kyty:$window"

# (Before the window opens: a job that ends at once keeps its window and its error.)
t set-option -wg remain-on-exit on
mkdir -p "$(dirname "$log")"
command="$(printf '%q ' "$@")"
t new-window -d -t kyty: -n "$window" -c "$PWD" \
	"set -o pipefail; echo \"\$(date '+%F %T') $window: $command\" | tee -a $(printf %q "$log"); $command 2>&1 | tee -a $(printf %q "$log"); s=\$?; echo \"\$(date '+%F %T') [exit \$s]\" | tee -a $(printf %q "$log")"
t display-message -p -t "kyty:$window" '#{pane_pid}'
