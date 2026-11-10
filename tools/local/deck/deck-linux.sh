#!/usr/bin/env bash
# The Steam Deck loop from a Linux PC (deck.sh's, without Windows and WSL): package builds, copy them to the Deck over
# SSH, precompile their shaders there and measure them. Each build goes into a folder of its own on the Deck,
# ~/Applications/KytyPS5-<name> (its own _PipelineCache, _SaveData and logs): the player's own install is left alone.
# The jobs' own output goes to jobs/, not logs/: decklive.py and decksoak.py follow the newest logs/*.log (the emulator's).
#   deck-linux.sh package <name> <source tree> <build dir>   kyty_emulator, kyty_shader_precompile, translator-id, the
#                                                            precompile files and the Deck tools -> _Build/deck-pkg/<name>
#   deck-linux.sh deploy <name>          the package into the Deck's ~/Applications/KytyPS5-<name>, an optional bench save (KYTY_BENCH_SAVE:
#                                        a _SaveData folder, its PPSA01341 in it) into its bench-save/; without one
#                                        each run starts a new game (the scripted pad goes through character creation)
#   deck-linux.sh precompile <name> [precompile-linux.sh options]   the full static precompile on the Deck, in the
#                                        background: tmux window precompile-<name> (deck-job.sh: the session "kyty",
#                                        socket -L kyty, a server SSH's end does not stop), jobs/precompile.log
#   deck-linux.sh status                 the Deck's jobs (tmux windows) and emulators, the last lines of their logs
#   deck-linux.sh tour <name> [cycles]   boot at run-deck.sh's settings, then the world tour (decksoak.py): worlds 2-5,
#                                        the Nexus, 1-1, 15 s each from 40 s after its load; memory and swap at the end
#   deck-linux.sh ssh [command]          a command on the Deck
# Watch the jobs on the Deck itself or over SSH: /home/linuxbrew/.linuxbrew/bin/tmux -L kyty attach (Ctrl-b d leaves them running).
# KYTY_DECK (default deck@<steamdeck.local's address>: DHCP moves it), KYTY_DECK_KEY (default ~/.ssh/dockers_buddy, else
# ~/.ssh/kyty_deck). The game on the Deck:
# KYTY_DECK_GAME, else ~/Games/PPSA01341-app0.zar or the folder ~/Games/PPSA01341-app0 (deckbench.py finds it).
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)"
if [ -z "${KYTY_DECK:-}" ]; then
	address="$(getent hosts steamdeck.local | awk '{print $1; exit}')"
	KYTY_DECK="deck@${address:-steamdeck.local}"
fi
DECK="$KYTY_DECK"
KEY="${KYTY_DECK_KEY:-}"
[ -n "$KEY" ] || for candidate in "$HOME/.ssh/dockers_buddy" "$HOME/.ssh/kyty_deck"; do [ -f "$candidate" ] && { KEY="$candidate"; break; }; done
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY" -o IdentitiesOnly=yes)
APPS=Applications
PKG="$ROOT/_Build/deck-pkg"
on_deck() { ssh "${SSH_OPTS[@]}" "$DECK" "$@"; }
die() { echo "$*" >&2; exit 1; }

# The tour's settings (run-deck.sh's, the same for every build) are in deck-tour.sh; KYTY_TOUR_SET="NAME=VALUE ..." adds
# or overrides some (KYTY_TOUR_LABEL: a word added to the label).

case "${1:-}" in
package)
	[ $# -eq 4 ] || die "package <name> <source tree> <build dir>"
	name="$2" src="$(readlink -f "$3")" build="$(readlink -f "$4")"
	out="$PKG/$name"
	rm -rf "$out"
	mkdir -p "$out/tools/local/static-precompile"
	cp "$build/kyty_emulator" "$build/kyty_shader_precompile" "$out/"
	[ -f "$build/translator-id" ] && cp "$build/translator-id" "$out/"
	cp "$src/precompile-linux.sh" "$src/tools/local/deck/run-deck.sh" "$out/"
	cp "$src/tools/local/static-precompile/pass-states.json" "$out/tools/local/static-precompile/"
	cp "$src/tools/local/static-precompile/"hints-*.hints "$out/tools/local/static-precompile/" 2>/dev/null || true
	# The measuring tools from this tree (the same for both builds; both builds answer the same live commands).
	for tool in deck-job.sh deck-tour.sh deckbench.py decksoak.py deckpasses.py deckab.py gpumetrics.py decklive.py deck-perf.sh; do
		cp "$ROOT/tools/local/deck/$tool" "$out/"
	done
	cp "$ROOT/tools/local/live-trace.py" "$out/"
	git -C "$src" rev-parse --short HEAD > "$out/commit"
	git -C "$src" status --porcelain -- src CMakeLists.txt | grep -q . && echo "+local changes" >> "$out/commit"
	chmod +x "$out/kyty_emulator" "$out/kyty_shader_precompile" "$out/"*.sh
	echo "$out: $(tr '\n' ' ' < "$out/commit")" ;;
deploy)
	[ $# -eq 2 ] || die "deploy <name>"
	name="$2"
	[ -d "$PKG/$name" ] || die "no package $PKG/$name (deck-linux.sh package first)"
	on_deck "mkdir -p ~/$APPS/KytyPS5-$name/bench-save ~/$APPS/KytyPS5-$name/logs ~/$APPS/KytyPS5-$name/prof ~/$APPS/KytyPS5-$name/shots ~/$APPS/KytyPS5-$name/jobs"
	rsync -rlt --info=stats1 -e "ssh ${SSH_OPTS[*]}" "$PKG/$name/" "$DECK:$APPS/KytyPS5-$name/"
	if [ -n "${KYTY_BENCH_SAVE:-}" ]; then
		[ -d "$KYTY_BENCH_SAVE/PPSA01341" ] || die "KYTY_BENCH_SAVE: no PPSA01341 in $KYTY_BENCH_SAVE"
		rsync -rt --delete -e "ssh ${SSH_OPTS[*]}" "$KYTY_BENCH_SAVE/PPSA01341" "$DECK:$APPS/KytyPS5-$name/bench-save/"
	fi
	on_deck "ls ~/$APPS/KytyPS5-$name/bench-save/PPSA01341 >/dev/null 2>&1 || echo 'no bench save: runs start a new game'" ;;
precompile)
	[ $# -ge 2 ] || die "precompile <name> [options]"
	name="$2"
	shift 2
	game="${KYTY_DECK_GAME:-}"
	# shellcheck disable=SC2016
	on_deck "set -e; cd ~/$APPS/KytyPS5-$name; game='$game'
		if [ -z \"\$game\" ]; then for g in ~/Games/PPSA01341-app0.zar ~/Games/PPSA01341-app0; do [ -e \"\$g\" ] && { game=\"\$g\"; break; }; done; fi
		[ -n \"\$game\" ] || { echo 'no game in ~/Games (KYTY_DECK_GAME)'; exit 1; }
		./deck-job.sh precompile-$name \$HOME/$APPS/KytyPS5-$name/jobs/precompile.log ./precompile-linux.sh --game \"\$game\" $* >/dev/null
		echo \"precompile of $name started on \$game: tmux -L kyty attach (window precompile-$name), ~/$APPS/KytyPS5-$name/jobs/precompile.log\"" ;;
status)
	on_deck 'systemctl --user list-units --no-legend "kyty-*" 2>/dev/null; pgrep -a kyty_ || true
		t=/home/linuxbrew/.linuxbrew/bin/tmux; $t -L kyty list-windows -t kyty -F "#{window_name}: #{?pane_dead,ended (exit #{pane_dead_status}),running}" 2>/dev/null || true
		for f in ~/'"$APPS"'/KytyPS5-*/jobs/precompile.log; do [ -f "$f" ] && { echo "== $f"; tail -n 3 "$f"; }; done
		free -m | head -3; cat /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1' ;;
tour)
	[ $# -ge 2 ] || die "tour <name> [cycles]"
	name="$2" cycles="${3:-1}"
	# deck-tour.sh in the tmux window tour-<name> (deck-job.sh), its log followed here until it ends; a dropped
	# connection leaves the tour running (deck-linux.sh status, jobs/tour-<name>-*.log, tmux -L kyty attach).
	game="${KYTY_DECK_GAME:-}"
	label="tour-$name-$(date +%m%d-%H%M)${KYTY_TOUR_LABEL:+-$KYTY_TOUR_LABEL}"
	extra="${KYTY_TOUR_SET:+KYTY_TOUR_SET=$(printf %q "$KYTY_TOUR_SET")}"
	on_deck "set -e; cd ~/$APPS/KytyPS5-$name; log=\$HOME/$APPS/KytyPS5-$name/jobs/$label.log
		pid=\$(./deck-job.sh tour-$name \$log env ${game:+KYTY_GAME=$(printf %q "$game")} $extra ./deck-tour.sh $label $cycles)
		for _ in \$(seq 100); do [ -f \$log ] && break; sleep 0.1; done
		tail -n +1 -f \$log --pid=\$pid" ;;
ssh)
	shift
	on_deck "$@" ;;
*)
	sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
	exit 1 ;;
esac
