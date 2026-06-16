#!/usr/bin/env bash
# launch_xemu.sh
# Select an original Xbox disc image and launch it with xemu.

set -euo pipefail

XEMU="/e/Video_Games/Emulators/Xbox/xemu/xemu.exe"
GAMES_DIR="/e/Video_Games/Emulators/Xbox/xemu/Games"

[[ -f "$XEMU" ]] || {
	printf "xemu not found: %s\n" "$XEMU" >&2
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
		\( -iname "*.iso" -o -iname "*.xiso" \) |
		sort |
		sed "s|^$GAMES_DIR/||" |
		fzf \
			--height=21 \
			--border=sharp \
			--layout=reverse \
			--info=inline-right \
			--prompt="Xbox ISO > " \
			--pointer="→" \
			--header=$'Enter to launch · Esc to cancel'
); then
	exit 0
fi

[[ -n "$game" ]] || exit 0

"$XEMU" \
	-full-screen \
	-dvd_path "$GAMES_DIR/$game" \
	>/dev/null 2>&1 &

disown
