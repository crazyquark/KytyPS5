#!/bin/bash
# The world tour on the Steam Deck, run from its install folder (deck-linux.sh tour starts it as a systemd user unit, so
# an SSH that drops does not end it): a boot at run-deck.sh's settings (deckbench.py run --keep; a new game when
# bench-save/ is empty), then decksoak.py's world changes (worlds 2-5, the Nexus, 1-1; 15 s each from 40 s after its
# load), the memory and the emulator's swap at the end, and the emulator stopped.
#   deck-tour.sh <label> [cycles]      KYTY_GAME: the game (else deckbench.py looks in ~/Games)
#   deck-tour.sh <label> keep          only the boot, the game left running (deckbench.py stop ends it)
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
cd "$here" || exit 1
label="${1:?label}"
cycles="${2:-1}"
# run-deck.sh's settings (360p, Lowest, no projected decals, sun shadows to 20 m) and the Steam Deck build's defaults,
# the same for every build measured.
settings=(KYTY_RENDER_HEIGHT=360 KYTY_HD_OUTPUT=1 KYTY_TEXTURE_REDUCE=2 KYTY_PRESENT_ASPECT=fit KYTY_HIDE_CURSOR=1
	"KYTY_GAME_CONVARS=r_forceViewportHeightForPixelSizeCalc=480;r_enableAmbientShadowing=false;r_enableSpotShadows=false;r_projectedDecalEnable=false;sunShadowMaxDistance=20"
	KYTY_UFFD_WP=1 KYTY_UFFD_MINOR=1 SDL_AUDIODRIVER=alsa,pulseaudio KYTY_BDA_GROUP_WALKS=1 KYTY_UPLOAD_HELP=1
	KYTY_RENDER_CORE=2)
# Game Mode (gamescope): a window Steam did not start is not shown. The emulator's window is tagged as a game (STEAM_GAME)
# and made the base layer gamescope shows; Steam's own (769) again when the tour ends.
gamescope_session() { pgrep -x gamescope >/dev/null && DISPLAY=:0 xprop -root GAMESCOPE_FOCUSED_APP >/dev/null 2>&1; }
show_game() {
	gamescope_session || return 0
	local window
	window="$(DISPLAY=:0 xdotool search --class kyty_emulator 2>/dev/null | head -1)"
	[ -n "$window" ] || return 0
	DISPLAY=:0 xprop -id "$window" -f STEAM_GAME 32c -set STEAM_GAME 7777
	DISPLAY=:0 xprop -root -f GAMESCOPECTRL_BASELAYER_APPID 32c -set GAMESCOPECTRL_BASELAYER_APPID 7777,769
}
show_steam() { gamescope_session && DISPLAY=:0 xprop -root -f GAMESCOPECTRL_BASELAYER_APPID 32c -set GAMESCOPECTRL_BASELAYER_APPID 769; }
gamescope_session && systemctl --user set-environment DISPLAY=:0 XDG_SESSION_TYPE=x11
# KYTY_TOUR_SET="NAME=VALUE ...": settings added or overriding these (the last --set of a name wins).
read -r -a tour_sets <<< "${KYTY_TOUR_SET:-}"
sets=()
for setting in "${settings[@]}" "${tour_sets[@]}"; do sets+=(--set "$setting"); done
echo "$(date '+%F %T') tour $label: $(tr '\n' ' ' < commit 2>/dev/null) ${KYTY_TOUR_SET:+[$KYTY_TOUR_SET] }game ${KYTY_GAME:-(deckbench default)}"
if [ "$cycles" = keep ]; then
	python3 deckbench.py run --dir "$here" --preset none "${sets[@]}" --label "$label" --settle 30 --measure 10 --keep
	show_game
	echo "$(date '+%F %T') boot $label: left running"
	exit 0
fi
if python3 deckbench.py run --dir "$here" --preset none "${sets[@]}" --label "$label" --settle 60 --measure 15 --keep; then
	show_game
	python3 decksoak.py --dir "$here" --cycles "$cycles" --settle 40 --stay 15
fi
echo
echo "memory at the end:"
free -m | head -3
pid="$(pgrep -x kyty_emulator | head -1)"
[ -n "$pid" ] && grep -E 'VmRSS|VmSwap' "/proc/$pid/status"
python3 deckbench.py stop
show_steam
echo "$(date '+%F %T') tour $label ended"
