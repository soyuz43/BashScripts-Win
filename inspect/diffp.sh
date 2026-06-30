#!/usr/bin/env bash
set -o pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

DIFFP_OUTPUT_FILE=""
DIFFP_INCLUDE_STAGED=true
DIFFP_INCLUDE_UNSTAGED=true
DIFFP_INCLUDE_UNTRACKED=true
DIFFP_COPY_TO_CLIPBOARD=true
DIFFP_PATH=""
DIFFP_PATHSPEC=""

print_help() {
	printf "Usage: diffp [options] [path]\n"
	printf "Options:\n"
	printf "  --staged, -s        Only show staged changes\n"
	printf "  --unstaged, -u      Only show unstaged changes, including untracked files\n"
	printf "  --tracked, -t       Only show tracked changes, excluding untracked files\n"
	printf "  --no-untracked      Exclude untracked files\n"
	printf "  --no-clip, -n       Don't copy to clipboard; print to stdout\n"
	printf "  --output, -o FILE   Save to FILE instead of clipboard\n"
	printf "  --help, -h          Show this help\n"
	printf "  path                Optional directory or file path to limit the diff\n"
}

validate_git_repo() {
	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		printf "Error: Not in a git repository\n" >&2
		return 1
	fi
}

set_diff_path() {
	local path="$1"

	if [[ -n "$DIFFP_PATH" ]]; then
		printf "Error: Only one path argument is allowed\n" >&2
		return 1
	fi

	if [[ -z "$path" ]]; then
		printf "Error: Path argument cannot be empty\n" >&2
		return 1
	fi

	DIFFP_PATH="$path"
}

build_pathspec() {
	local path="$DIFFP_PATH"

	if [[ -z "$path" ]]; then
		DIFFP_PATHSPEC=""
		return
	fi

	if [[ "$path" == /* ]]; then
		while [[ "$path" == /* ]]; do
			path="${path#/}"
		done

		if [[ -z "$path" ]]; then
			path="."
		fi

		DIFFP_PATHSPEC=":(top,literal)$path"
		return
	fi

	DIFFP_PATHSPEC=":(literal)$path"
}

parse_args() {
	while (($# > 0)); do
		case "$1" in
		--staged | -s)
			DIFFP_INCLUDE_STAGED=true
			DIFFP_INCLUDE_UNSTAGED=false
			DIFFP_INCLUDE_UNTRACKED=false
			;;
		--unstaged | -u)
			DIFFP_INCLUDE_STAGED=false
			DIFFP_INCLUDE_UNSTAGED=true
			DIFFP_INCLUDE_UNTRACKED=true
			;;
		--tracked | -t)
			DIFFP_INCLUDE_UNTRACKED=false
			;;
		--no-untracked)
			DIFFP_INCLUDE_UNTRACKED=false
			;;
		--no-clip | -n)
			DIFFP_COPY_TO_CLIPBOARD=false
			;;
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
			return 2
			;;
		--)
			shift

			while (($# > 0)); do
				if ! set_diff_path "$1"; then
					return 1
				fi
				shift
			done

			break
			;;
		-*)
			printf "Error: Unknown option: %s\n" "$1" >&2
			return 1
			;;
		*)
			if ! set_diff_path "$1"; then
				return 1
			fi
			;;
		esac

		shift
	done

	build_pathspec
}

# Original git diff wrapper (no compaction) – used for --quiet / --stat
git_diff_no_ext_raw() {
	local -a extra_args=("$@")

	if [[ -n "$DIFFP_PATHSPEC" ]]; then
		git diff --no-ext-diff "${extra_args[@]}" -- "$DIFFP_PATHSPEC"
		return
	fi

	git diff --no-ext-diff "${extra_args[@]}" --
}

# Compaction filter: summarises large deletions, detects whole file removal
compact_diff() {
	awk '
	function flush_deletions() {
		if (deletion_count > 5) {
			printf "-[%d lines deleted]\n", deletion_count
		} else {
			for (i = 0; i < deletion_count; i++) {
				print "-"
			}
		}

		deletion_count = 0
	}

	BEGIN {
		deletion_count = 0
	}

	/^-/ && !/^--- / {
		deletion_count++
		next
	}

	{
		flush_deletions()
		print
	}

	END {
		flush_deletions()
	}
	'
}

git_ls_untracked() {
	local -a extra_args=("$@")

	if [[ -n "$DIFFP_PATHSPEC" ]]; then
		git ls-files --others --exclude-standard "${extra_args[@]}" -- "$DIFFP_PATHSPEC"
		return
	fi

	git ls-files --others --exclude-standard "${extra_args[@]}" --
}

has_untracked_changes() {
	local untracked=""

	if ! untracked=$(git_ls_untracked --directory --no-empty-directory); then
		printf "Error: Failed to inspect untracked files\n" >&2
		return 2
	fi

	[[ -n "${untracked//[[:space:]]/}" ]]
}

check_changes() {
	local has_changes=false

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]] && ! git_diff_no_ext_raw --quiet; then
		has_changes=true
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]] && ! git_diff_no_ext_raw --cached --quiet; then
		has_changes=true
	fi

	if [[ "$DIFFP_INCLUDE_UNTRACKED" == true ]] && has_untracked_changes; then
		has_changes=true
	fi

	if [[ "$has_changes" == false ]]; then
		if [[ -n "$DIFFP_PATH" ]]; then
			printf "No changes to diff for path: %s\n" "$DIFFP_PATH" >&2
		else
			printf "No changes to diff\n" >&2
		fi
		return 1
	fi
}

get_branch() {
	local branch=""

	if ! branch=$(git branch --show-current 2>/dev/null); then
		printf "Error: Failed to get branch\n" >&2
		return 1
	fi

	if [[ -z "${branch//[[:space:]]/}" ]]; then
		if ! branch=$(git rev-parse --short HEAD 2>/dev/null); then
			printf "Error: Detached HEAD and cannot resolve commit\n" >&2
			return 1
		fi
	fi

	printf "%s" "$branch"
}

build_untracked_stat() {
	local files=""

	if ! files=$(git_ls_untracked); then
		printf "Error: Failed untracked stat\n" >&2
		return 1
	fi

	if [[ -n "${files//[[:space:]]/}" ]]; then
		printf "Untracked:\n%s\n" "$files"
	fi
}

build_stat() {
	local stat=""
	local unstaged=""
	local staged=""
	local untracked=""

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]]; then
		if ! unstaged=$(git_diff_no_ext_raw --stat); then
			printf "Error: Failed unstaged stat\n" >&2
			return 1
		fi

		if [[ -n "${unstaged//[[:space:]]/}" ]]; then
			stat+="Unstaged:"$'\n'"$unstaged"$'\n'
		fi
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! staged=$(git_diff_no_ext_raw --cached --stat); then
			printf "Error: Failed staged stat\n" >&2
			return 1
		fi

		if [[ -n "${staged//[[:space:]]/}" ]]; then
			stat+="Staged:"$'\n'"$staged"$'\n'
		fi
	fi

	if [[ "$DIFFP_INCLUDE_UNTRACKED" == true ]]; then
		if ! untracked=$(build_untracked_stat); then
			return 1
		fi

		if [[ -n "${untracked//[[:space:]]/}" ]]; then
			stat+="$untracked"
		fi
	fi

	printf "%s" "$stat"
}

read_untracked_files() {
	local -n files_ref="$1"

	files_ref=()
	# shellcheck disable=SC2034  # false positive: nameref used by caller
	if ! mapfile -d '' -t files_ref < <(git_ls_untracked -z); then
		printf "Error: Failed to read untracked files\n" >&2
		return 1
	fi
}

diff_untracked_file() {
	local file="$1"
	local file_diff=""
	local status=0

	if [[ ! -e "$file" && ! -L "$file" ]]; then
		printf "Error: Untracked path disappeared while diffing: %s\n" "$file" >&2
		return 1
	fi

	file_diff=$(git diff --no-ext-diff --no-index -- /dev/null "$file" 2>/dev/null)
	status=$?

	if ((status > 1)); then
		printf "Error: Failed untracked diff for: %s\n" "$file" >&2
		return 1
	fi

	if [[ -z "${file_diff//[[:space:]]/}" ]]; then
		printf "diff --git a/%s b/%s\nnew file mode 100644\n" "$file" "$file"
		return
	fi

	printf "%s\n" "$file_diff"
}

build_untracked_diff() {
	local -a files=()
	local file=""
	local part=""

	if ! read_untracked_files files; then
		return 1
	fi

	if ((${#files[@]} == 0)); then
		return
	fi

	printf '\n\nUntracked files:\n'

	for file in "${files[@]}"; do
		if [[ -z "$file" ]]; then
			continue
		fi

		if ! part=$(diff_untracked_file "$file"); then
			return 1
		fi

		printf '\n%s\n' "$part"
	done
}

build_output() {
	local outfile="$1"
	local branch=""
	local stat=""

	if ! branch=$(get_branch); then
		return 1
	fi

	if ! stat=$(build_stat); then
		return 1
	fi

	# Write header (static template with dynamic branch/timestamp)
	cat >"$outfile" <<EOF
You are reviewing a git diff. Operate as a strict, signal-maximizing reviewer.

## Context
- Workflow: new → bet → pr
- Branch: $branch
- Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
- bet guarantees:
  - formatting/linting already applied where configured
  - generated files are blocked

## Review Priorities (in order)
1. Correctness / Bugs (critical first)
2. Behavioral changes / regressions
3. Language-specific risks and edge cases
4. Maintainability improvements
5. Ignore pure formatting changes unless they affect behavior

## Decision
- Output EXACTLY one:
  - BLOCK
  - ALLOW

## Execution Rule (CRITICAL)

- If Decision = "BLOCK":
  - DO NOT generate PR command
  - DO NOT generate commit message

  - Instead output ONLY these sections:

### Explanation
- 1–3 bullets summarizing what changed and why it matters

### Critical Bugs (BLOCKING)
- [critical] <issue>
  - Why it is a problem
  - Concrete fix (code snippet if applicable)

### Additional Bugs
- [high]/[medium] issues (optional, same format)

### Fix Suggestions
- Provide a consolidated patch if multiple bugs are related
- Prefer minimal diffs over rewrites
- Use correct language syntax from the diff
- Ensure snippets are copy-pasteable and complete (no placeholders)

### Status
BLOCKED: Critical bugs must be fixed before creating a PR

- DO NOT output PR command or commit message under any condition

- If Decision = "ALLOW":
  - Proceed with full output format below

## Output Rules (STRICT)

- The Decision is required, but it is not the entire response.
- Output exactly one complete format: BLOCK or ALLOW.
- Never output only \`BLOCK\` or only \`ALLOW\`.
- Use every required heading exactly as shown and in the listed order.
- Do not add preambles, extra sections, or trailing commentary.
- Be concise and high-signal; max 6 top-level bullets per section.
- Order bugs by severity: critical → high → medium → low.
- Do not use placeholders, pseudocode, ellipses, or incomplete fixes.

### Required BLOCK Format

### Decision
BLOCK

### Explanation
- 1–3 bullets summarizing the change and blocking risk

### Critical Bugs (BLOCKING)
- [critical] <specific bug and consequence>
  - Why: <exact failure mode>
  - Location: <file and function, symbol, or diff hunk>
  - Existing code:
    \`\`\`<language>
    <exact code copied from the diff>
    \`\`\`
  - Replace with:
    \`\`\`<language>
    <complete copy-pasteable replacement>
    \`\`\`

### Additional Bugs
- [high]/[medium] findings in the same format, or \`None\`

### Fix Suggestions
- Provide a minimal consolidated patch when related edits are required
- For insertions, show an exact existing anchor and state whether to insert before or after it
- Include required imports, declarations, type changes, and call-site updates

### Status
BLOCKED: Critical bugs must be fixed before creating a PR

For BLOCK:
- Include at least one critical bug.
- Never include Branch Name, Commit Message, PR Body, or PR Command.
- Copy existing code exactly from the diff; do not invent surrounding code.
- Fixes must be complete, valid, and directly copy-pasteable.
- If the diff lacks enough context for an exact fix, state precisely what context is missing instead of fabricating code.

### Required ALLOW Format

### Decision
ALLOW

### Explanation
- 1–3 bullets summarizing the change and review result

### Bugs
- \`None\`, or severity-tagged non-blocking bugs

### PR Body
<complete PR body>

### Branch Name
\`\`\`text
new <recommended-branch-name>
\`\`\`

### Commit Message
\`\`\`text
<commit message only>
\`\`\`

### PR Command
\`\`\`sh
<complete executable gh pr create command>
\`\`\`

For ALLOW:
- Include every section above; never output only \`ALLOW\`.
- Branch Name must be exactly one shell command using the \`new\` alias followed by the recommended branch name.
- Branch Name must not use \`git switch\`, \`git checkout\`, or any other Git command.
- Commit Message must contain only the commit message; do not include \`git commit\` or any shell command.
- PR Command must contain only a complete executable \`gh pr create\` command.
- Do not add a branch or head argument to the PR command unless required by the reviewed workflow.
- If Bugs is not \`None\`, copy every bug into the PR body without omitting its severity, location, or consequence.

Before responding, silently verify:
- The selected format is complete.
- BLOCK contains at least one critical bug and no branch, commit, or PR output.
- ALLOW contains PR Body, Branch Name, Commit Message, and PR Command.
- Branch Name begins with \`new \` and contains no Git command.
- Commit Message contains no command.
- PR Command is an executable \`gh pr create\` command.

## Files Changed
\`\`\`
$stat
\`\`\`

## Diff
EOF

	# Append the actual diffs (compacted) directly to the file
	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]]; then
		{
			printf '\n\nUnstaged changes:\n'
			git_diff_no_ext_raw | compact_diff
		} >>"$outfile" || {
			printf "Error: Failed unstaged diff\n" >&2
			return 1
		}
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		{
			printf '\n\nStaged changes:\n'
			git_diff_no_ext_raw --cached | compact_diff
		} >>"$outfile" || {
			printf "Error: Failed staged diff\n" >&2
			return 1
		}
	fi

	if [[ "$DIFFP_INCLUDE_UNTRACKED" == true ]]; then
		build_untracked_diff >>"$outfile" || return 1
	fi
}

write_output() {
	local src="$1"

	if [[ -n "${DIFFP_OUTPUT_FILE//[[:space:]]/}" ]]; then
		if ! cp "$src" "$DIFFP_OUTPUT_FILE"; then
			printf "Error: Failed to write file: %s\n" "$DIFFP_OUTPUT_FILE" >&2
			return 1
		fi
		printf "Saved: %s\n" "$DIFFP_OUTPUT_FILE"
		return
	fi

	if [[ "$DIFFP_COPY_TO_CLIPBOARD" == true ]]; then
		if command -v iconv >/dev/null 2>&1 && command -v clip.exe >/dev/null 2>&1; then
			if ! {
				printf '\xff\xfe'
				iconv -f UTF-8 -t UTF-16LE <"$src"
			} | clip.exe; then
				printf "Error: Clipboard copy failed\n" >&2
				return 1
			fi
			printf "[OK] Copied to clipboard\n"
			return
		fi
		printf "Error: Clipboard tools missing; use --no-clip or --output FILE\n" >&2
		return 1
	fi

	cat "$src"
}

main() {
	local parse_status=0
	local tmpfile=""

	parse_args "$@"
	parse_status=$?

	case "$parse_status" in
	0) ;;
	2) return ;;
	*) return 1 ;;
	esac

	if ! validate_git_repo; then
		return 1
	fi

	if ! check_changes; then
		return 1
	fi

	tmpfile=$(mktemp) || {
		printf "Error: Could not create temporary file\n" >&2
		return 1
	}
	trap 'rm -f "$tmpfile"' EXIT

	if ! build_output "$tmpfile"; then
		return 1
	fi

	if ! write_output "$tmpfile"; then
		return 1
	fi
}

main "$@"
