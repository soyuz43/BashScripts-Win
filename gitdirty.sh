#!/usr/bin/env bash
set -o pipefail

BASE="$HOME/workspace"
ROOT="${BASE}/${1:-}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

process_repo() {
	local gitdir repo branch dirty ahead behind file

	gitdir="$1"
	repo="${gitdir%/.git}"

	local branch_tmp
	if ! branch_tmp=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null); then
		branch="unknown"
	else
		branch="$branch_tmp"
	fi

	local dirty_tmp
	if ! dirty_tmp=$(git -C "$repo" status --porcelain 2>/dev/null); then
		dirty=""
	else
		dirty="$dirty_tmp"
	fi

	if git -C "$repo" rev-parse '@{u}' >/dev/null 2>&1; then
		local ahead_tmp behind_tmp

		if ! ahead_tmp=$(git -C "$repo" rev-list --count '@{u}..' 2>/dev/null); then
			ahead=0
		else
			ahead="$ahead_tmp"
		fi

		if ! behind_tmp=$(git -C "$repo" rev-list --count '..@{u}' 2>/dev/null); then
			behind=0
		else
			behind="$behind_tmp"
		fi
	else
		ahead=0
		behind=0
	fi

	if [[ -n "$dirty" || "$ahead" -gt 0 || "$behind" -gt 0 ]]; then
		file="$TMP_DIR/$(basename "$repo").$$.$RANDOM"

		{
			printf "REPO:%s\n" "$repo"
			[[ -n "$dirty" ]] && printf "DIRTY\n"
			[[ "$ahead" -gt 0 ]] && printf "AHEAD:%s\n" "$ahead"
			[[ "$behind" -gt 0 ]] && printf "BEHIND:%s\n" "$behind"
		} >"$file"

		printf "\n[repo] %s\n" "$repo"
		printf "  branch: %s\n" "$branch"
		[[ -n "$dirty" ]] && printf "  [!] dirty\n"
		[[ "$ahead" -gt 0 ]] && printf "  [+] ahead %s\n" "$ahead"
		[[ "$behind" -gt 0 ]] && printf "  [-] behind %s\n" "$behind"
	fi
}

export -f process_repo TMP_DIR

find "$ROOT" -name ".git" -type d -print0 |
	xargs -0 -P 8 -I {} bash -c 'process_repo "$@"' _ {}

aggregate() {
	local total dirty_count ahead_count behind_count
	local files

	total=$(find "$ROOT" -name ".git" -type d | wc -l)

	shopt -s nullglob
	files=("$TMP_DIR"/*)
	shopt -u nullglob

	if [[ ${#files[@]} -gt 0 ]]; then
		dirty_count=$(grep -hc "^DIRTY" "${files[@]}" 2>/dev/null)
		ahead_count=$(awk -F: '/^AHEAD:/ {s+=$2} END{print s+0}' "${files[@]}" 2>/dev/null)
		behind_count=$(awk -F: '/^BEHIND:/ {s+=$2} END{print s+0}' "${files[@]}" 2>/dev/null)
	else
		dirty_count=0
		ahead_count=0
		behind_count=0
	fi

	printf "\n--- Summary ---\n"
	printf "Repos: %s\n" "$total"
	printf "Dirty: %s\n" "$dirty_count"
	printf "Ahead commits: %s\n" "$ahead_count"
	printf "Behind commits: %s\n" "$behind_count"
}

aggregate
