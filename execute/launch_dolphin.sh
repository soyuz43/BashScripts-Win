#!/usr/bin/env bash
# launch_dolphin.sh
# Select a GameCube game and launch it with Dolphin.

set -euo pipefail

DOLPHIN="/e/Video_Games/Emulators/Gamecube/Dolphin-x64/Dolphin.exe"
GAMES_DIR="/e/Video_Games/Emulators/Gamecube/Dolphin-x64/Games"

[[ -f "$DOLPHIN" ]] || {
	printf "Dolphin not found: %s\n" "$DOLPHIN" >&2
	exit 1
}

[[ -d "$GAMES_DIR" ]] || {
	printf "Games directory not found: %s\n" "$GAMES_DIR" >&2
	exit 1
}

command -v fzf >/dev/null 2>&1 || {
	printf "fzf is not installed or not available on PATH.\n" >&2
	exit 1
}

game=""

if ! game=$(
	find "$GAMES_DIR" -type f \
		\( \
			-iname "*.iso" -o \
			-iname "*.gcm" -o \
			-iname "*.ciso" -o \
			-iname "*.rvz" \
		\) |
		sort |
		sed "s|^$GAMES_DIR/||" |
		fzf \
			--height=21 \
			--border=sharp \
			--layout=reverse \
			--info=inline-right \
			--prompt="GameCube > " \
			--pointer=">" \
			--header="Enter to launch • Esc to cancel"
); then
	exit 0
fi

[[ -n "$game" ]] || exit 0

"$DOLPHIN" \
	-b \
	-e "$GAMES_DIR/$game" \
	>/dev/null 2>&1 &

disown