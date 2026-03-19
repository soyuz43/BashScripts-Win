#!/usr/bin/env bash
set -o pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

DIFFP_OUTPUT_FILE=""
DIFFP_INCLUDE_STAGED=true
DIFFP_INCLUDE_UNSTAGED=true
DIFFP_COPY_TO_CLIPBOARD=true

print_help() {
	printf "Usage: diffp [options]\n"
	printf "Options:\n"
	printf "  --staged, -s     Only show staged changes\n"
	printf "  --unstaged, -u   Only show unstaged changes\n"
	printf "  --no-clip, -n    Don't copy to clipboard (print to stdout)\n"
	printf "  --output, -o     Save to FILE instead of clipboard\n"
	printf "  --help, -h       Show this help\n"
}

validate_git_repo() {
	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		printf "Error: Not in a git repository\n" >&2
		return 1
	fi
}

parse_args() {
	while [[ "$#" -gt 0 ]]; do
		case "$1" in
		--staged | -s) DIFFP_INCLUDE_UNSTAGED=false ;;
		--unstaged | -u) DIFFP_INCLUDE_STAGED=false ;;
		--no-clip | -n) DIFFP_COPY_TO_CLIPBOARD=false ;;
		--output | -o)
			shift
			if [[ -z "${1:-}" || "$1" =~ ^- ]]; then
				printf "Error: --output requires a valid file path\n" >&2
				return 1
			fi
			DIFFP_OUTPUT_FILE="$1"
			;;
		--help | -h)
			print_help
			return 0
			;;
		*)
			printf "Error: Unknown option: %s\n" "$1" >&2
			return 1
			;;
		esac
		shift
	done
}

check_changes() {
	local has_changes=false

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]] && ! git diff --quiet; then
		has_changes=true
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]] && ! git diff --cached --quiet; then
		has_changes=true
	fi

	if [[ "$has_changes" == false ]]; then
		printf "No changes to diff (staged or unstaged)\n" >&2
		return 1
	fi
}

build_stat() {
	local stat="" unstaged staged

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]]; then
		if ! unstaged=$(git diff --stat); then
			printf "Error: Failed unstaged stat\n" >&2
			return 1
		fi
		stat+="Unstaged:\n$unstaged\n"
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! staged=$(git diff --cached --stat); then
			printf "Error: Failed staged stat\n" >&2
			return 1
		fi
		stat+="Staged:\n$staged"
	fi

	printf "%b" "$stat"
}

build_diff() {
	local diff="" u s

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]]; then
		if ! u=$(git diff); then
			printf "Error: Failed unstaged diff\n" >&2
			return 1
		fi
		diff+=$'\n\nUnstaged changes:\n'"$u"
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! s=$(git diff --cached); then
			printf "Error: Failed staged diff\n" >&2
			return 1
		fi
		diff+=$'\n\nStaged changes:\n'"$s"
	fi

	printf "%s" "$diff"
}

build_output() {
	local branch sanitized stat diff timestamp output

	if ! branch=$(git branch --show-current); then
		printf "Error: Failed to get branch\n" >&2
		return 1
	fi

	if ! sanitized=$(printf "%s" "$branch" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]'); then
		printf "Error: Failed to sanitize branch\n" >&2
		return 1
	fi

	stat=$(build_stat) || return 1
	diff=$(build_diff) || return 1
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	output=$(
		cat <<EOF
You are reviewing a git diff. Operate as a strict, signal-maximizing reviewer.

## Context
- Workflow: new → bet → pr
- Branch: $branch
- Timestamp: $timestamp

## Files Changed
\`\`\`
$stat
\`\`\`

## Branch
\`\`\`bash
new ${sanitized}-<feature-description>
\`\`\`

## Diff
$diff
EOF
	)

	printf "%s" "$output"
}

write_output() {
	local content="$1"

	if [[ -n "${DIFFP_OUTPUT_FILE// /}" ]]; then
		if ! printf "%s\n" "$content" >"$DIFFP_OUTPUT_FILE"; then
			printf "Error: Failed to write file\n" >&2
			return 1
		fi
		printf "Saved: %s\n" "$DIFFP_OUTPUT_FILE"
		return
	fi

	if [[ "$DIFFP_COPY_TO_CLIPBOARD" == true ]]; then
		if command -v iconv >/dev/null 2>&1 && command -v clip.exe >/dev/null 2>&1; then
			if ! printf "%s" "$content" | iconv -f UTF-8 -t UTF-16LE | clip.exe; then
				printf "Error: Clipboard copy failed\n" >&2
				return 1
			fi
		else
			printf "Error: Clipboard tools missing\n" >&2
			return 1
		fi

		printf "[OK] Copied to clipboard\n"
		return
	fi

	printf "%s\n" "$content"
}

main() {
	if ! parse_args "$@"; then
		return $?
	fi

	if ! validate_git_repo; then
		return 1
	fi

	if ! check_changes; then
		return 1
	fi

	local output
	if ! output=$(build_output); then
		return 1
	fi

	write_output "$output"
}

main "$@"
