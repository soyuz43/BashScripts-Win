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

get_branch() {
	local branch
	if ! branch=$(git branch --show-current 2>/dev/null); then
		printf "Error: Failed to get branch\n" >&2
		return 1
	fi

	if [[ -z "${branch// /}" ]]; then
		if ! branch=$(git rev-parse --short HEAD 2>/dev/null); then
			printf "Error: Detached HEAD and cannot resolve commit\n" >&2
			return 1
		fi
	fi

	printf "%s" "$branch"
}

sanitize_branch() {
	local raw="$1"
	local sanitized

	if ! sanitized=$(printf "%s" "$raw" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]'); then
		printf "Error: Failed to sanitize branch\n" >&2
		return 1
	fi

	if [[ -z "${sanitized// /}" ]]; then
		printf "Error: Sanitized branch empty\n" >&2
		return 1
	fi

	printf "%s" "$sanitized"
}

build_stat() {
	local stat="" unstaged staged

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]]; then
		if ! unstaged=$(git diff --stat); then
			printf "Error: Failed unstaged stat\n" >&2
			return 1
		fi
		if [[ -n "${unstaged// /}" ]]; then
			stat+="Unstaged:\n$unstaged\n"
		fi
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! staged=$(git diff --cached --stat); then
			printf "Error: Failed staged stat\n" >&2
			return 1
		fi
		if [[ -n "${staged// /}" ]]; then
			stat+="Staged:\n$staged"
		fi
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
		if [[ -n "${u// /}" ]]; then
			diff+=$'\n\nUnstaged changes:\n'"$u"
		fi
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! s=$(git diff --cached); then
			printf "Error: Failed staged diff\n" >&2
			return 1
		fi
		if [[ -n "${s// /}" ]]; then
			diff+=$'\n\nStaged changes:\n'"$s"
		fi
	fi

	printf "%s" "$diff"
}

build_output() {
	local branch sanitized stat diff timestamp output

	if ! branch=$(get_branch); then
		return 1
	fi

	if ! sanitized=$(sanitize_branch "$branch"); then
		return 1
	fi

	if ! stat=$(build_stat); then
		return 1
	fi

	if ! diff=$(build_diff); then
		return 1
	fi

	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	output=$(
		cat <<EOF
You are reviewing a git diff. Operate as a strict, signal-maximizing reviewer.

## Context
- Workflow: new → bet → pr
- Branch: $branch
- Timestamp: $timestamp
- bet guarantees:
  - formatting/linting already applied where configured
  - generated files are blocked

## Review Priorities (in order)
1. Correctness / Bugs (critical first)
2. Behavioral changes / regressions
3. Language-specific risks and edge cases
4. Maintainability improvements
5. Ignore pure formatting changes unless they affect behavior

## Output Rules (STRICT)
- Be informative, then concise
- Prioritize high-signal insights over completeness
- No filler or redundant statements
- Each bullet must add new, non-obvious information
- Max 6 bullets per section
- Use dense phrasing (compress after conveying meaning)
- Order bugs by severity (critical → minor)

## Files Changed
\`\`\`
$stat
\`\`\`

## Required Output

### Explanation
- 1–3 bullets summarizing what changed and why it matters

### Bugs
- Bullet list of concrete issues (or "None")

### Improvements
- Bullet list of actionable enhancements (or "None")

### Branch
\`\`\`bash
new ${sanitized}-<feature-description>
\`\`\`

### Commit Message
\`\`\`text
<imperative, ≤72 chars, no period>
\`\`\`

### PR Command
\`\`\`bash
gh pr create --title "<same as commit>" --body "<structured body>"
\`\`\`

## PR Body Format (STRICT)
Summary:
- <1–2 lines: what changed + why>

Changes:
- <key change 1>
- <key change 2>
- <key change 3>

Notes:
- <optional: risks, edge cases, or follow-ups (omit if none)>

## Additional Constraints
- Prefer minimal, safe changes over cleverness
- Preserve backward compatibility unless clearly intentional
- Follow the conventions of the language(s) in the diff
- Flag silent failure risks and missing error handling
- Highlight unsafe or non-idiomatic patterns even if they pass linters

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
