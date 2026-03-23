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

	if [[ "$DIFFP_INCLUDE_UNSTAGED" == true ]] && ! git diff --no-ext-diff --quiet; then
		has_changes=true
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]] && ! git diff --no-ext-diff --cached --quiet; then
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
		if ! unstaged=$(git diff --no-ext-diff --stat); then
			printf "Error: Failed unstaged stat\n" >&2
			return 1
		fi
		if [[ -n "${unstaged// /}" ]]; then
			stat+="Unstaged:\n$unstaged\n"
		fi
	fi

	if [[ "$DIFFP_INCLUDE_STAGED" == true ]]; then
		if ! staged=$(git diff --no-ext-diff --cached --stat); then
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
		if ! s=$(git diff --no-ext-diff --cached); then
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

## Decision
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
- Be informative, then concise
- Prioritize high-signal insights over completeness
- No filler or redundant statements
- Each bullet must add new, non-obvious information
- Max 6 bullets per section
- Use dense phrasing (compress after conveying meaning)
- Order bugs by severity (critical → minor)
- Bugs MUST be included in the PR body when Decision = "ALLOW" (do not omit or summarize away)
- If Bugs section is not "None", they must be copied into PR Body verbatim (compressed allowed)
- The Decision section is authoritative:
  - "BLOCK" → no further output allowed
  - "ALLOW" → full output required
  
## Files Changed
\`\`\`
$stat
\`\`\`

## Required Output

### Explanation
- 1–3 bullets summarizing what changed and why it matters

### Bugs
For EACH bug, use EXACT structure:

- [critical|high|medium] <issue>

  - Location:
    File: <file path>
    Symbol: <function | method | class | block name>

  - Why:
    <root cause + impact in 1–2 lines>

  - Existing Code:
\`\`\`<language>
<copy the relevant existing code EXACTLY as it appears in the diff>
\`\`\`

  - Replacement (FULL BLOCK — copy/paste ready):
\`\`\`<language>
<complete corrected version of the code above — no omissions, no placeholders>
\`\`\`

  - Notes:
    <edge cases / assumptions / alternatives (optional)>

- "None" if no issues

Rules:
- MUST include Location (File + Symbol)
- Symbol MUST be specific (function name, method, or clearly described block)
- MUST include BOTH "Existing Code" and "Replacement"
- Replacement MUST be a FULL, self-contained snippet (no "...", no omissions)
- Replacement MUST be directly copy-pasteable into the file
- Replacement MUST be complete enough to compile/run without additional edits
- DO NOT output diff-style code (+/-)
- DO NOT describe fixes without code
- Prefer replacing entire logical units (function/block) over partial edits
- If the fix affects multiple locations, include multiple full replacements
- Use the SAME language as the diff
- Existing Code MUST match or be directly derived from the diff (no fabrication)
- If exact existing code is not shown, infer the smallest valid enclosing block and include it fully
- Replacement MUST be complete enough to compile/run without requiring additional edits
- Default to minimal, localized replacements; escalate to full function/class replacement only when the fix spans multiple lines or affects control flows

### Branch
\`\`\`bash
new wrs/<feature|bug|chore>-<description>
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
- 3–6 bullets ONLY (no prose blocks)
- Each bullet MUST follow: <change> → <why> → <impact>
- Prioritize behavioral changes, regressions, and user-visible effects first; structural/internal changes last
- MUST incorporate (not repeat verbatim) key points from Explanation
- NO vague phrasing (e.g., "improved", "refactored", "updated") without specifying what and why
- Each bullet must be information-dense, non-redundant, and ≤30 words

Changes:
- 3–6 bullets, each a distinct concrete change (WHAT only; no why/impact)
- MUST NOT duplicate Summary bullets verbatim
- Use precise, implementation-level language

Bugs:
- MUST mirror Bugs section above (verbatim or compressed, no loss of meaning)
- Preserve severity labels (critical/high/medium)
- "None" if no issues

Notes:
- Optional; include only risks, edge cases, or follow-ups NOT already covered
- No repetition of Summary or Bugs

## Example Output (REFERENCE — STRUCTURE ONLY)

---
Summary:
- [change → why → impact; behavioral/user-visible; ≤30 words; no vague terms]
- [change → why → impact; include regression or risk if applicable; ≤30 words]
- [change → why → impact; structural/internal if lower priority; ≤30 words]

Changes:
- [specific implementation change (WHAT only; no why/impact)]
- [distinct code-level modification; precise and non-redundant]
- [additional concrete change if applicable]

Bugs:
- [critical/high/medium] [concise issue description]
- ["None" if no issues]

Notes:
- [optional: risks, edge cases, follow-ups not already covered; omit section if none]

---

## Additional Constraints
- Prefer minimal, safe changes over cleverness
- Preserve backward compatibility unless clearly intentional
- Follow the conventions of the language(s) in the diff
- Flag silent failure risks and missing error handling
- Highlight unsafe or non-idiomatic patterns even if they pass linters
- Use github CLI ('gh') to create PR
- The PR command must be shell-safe.
- Escape ALL backticks using \`
- Escape ALL double quotes using \"
- Escape ALL dollar signs using \$
- Do NOT use unescaped backticks, quotes, or shell expansions inside the PR body
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
