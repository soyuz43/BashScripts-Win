#!/usr/bin/env bash

BASE="$HOME/workspace"

if [[ -n "${1:-}" ]]; then
	ROOT="$BASE/$1"
else
	ROOT="$BASE"
fi
export ROOT

# Color setup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Temporary file for collecting results
tmpfile="$(mktemp).gitdirty"
trap 'rm -f "$tmpfile"' EXIT

# Process a single repository (exported for xargs)
process_repo() {
	local gitdir="$1"
	local repo="${gitdir%/.git}"
	local output=""

	# Use git -C to avoid cd
	local branch dirty ahead behind

	branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
	dirty=$(git -C "$repo" status --porcelain 2>/dev/null)

	if git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
		ahead=$(git -C "$repo" rev-list --count '@{u}..' 2>/dev/null || echo 0)
		behind=$(git -C "$repo" rev-list --count '..@{u}' 2>/dev/null || echo 0)
	else
		ahead=0
		behind=0
	fi

	# Only output if something is interesting
	if [[ -n "$dirty" || $ahead -gt 0 || $behind -gt 0 ]]; then
		# Build output lines
		output+=$'\n'
		# Highlight repos on main/master with changes
		if [[ "$branch" == "main" || "$branch" == "master" ]] && [[ -n "$dirty" ]]; then
			output+="${RED}⚠️  $repo (on $branch with changes)${NC}\n"
		else
			output+="${GREEN}📦 $repo${NC}\n"
		fi
		output+="  branch: $branch\n"
		if [[ -n "$dirty" ]]; then
			output+="  ${RED}→ Uncommitted changes${NC}\n"
		fi
		if [[ $ahead -gt 0 ]]; then
			output+="  ${YELLOW}→ Ahead by $ahead commit(s)${NC}\n"
		fi
		if [[ $behind -gt 0 ]]; then
			output+="  ${BLUE}→ Behind by $behind commit(s)${NC}\n"
		fi

		# Write to temp file for summary
		local mytmp
		mytmp="$(mktemp "${tmpfile}.XXXX")"

		echo "REPO: $repo" >>"$mytmp"
		[[ -n "$dirty" ]] && echo "DIRTY" >>"$mytmp"
		[[ $ahead -gt 0 ]] && echo "AHEAD:$ahead" >>"$mytmp"
		[[ $behind -gt 0 ]] && echo "BEHIND:$behind" >>"$mytmp"
		echo "---" >>"$mytmp"
	fi

	# Print output immediately (if any)
	if [[ -n "$output" ]]; then
		printf "%b" "$output"
	fi
}
export -f process_repo

# Find all .git directories and process in parallel
find "$ROOT" -name ".git" -type d -print0 |
	xargs -0 -P 8 -I {} bash -c 'process_repo "$@"' _ {} 2>/dev/null
#  MERGE parallel temp files into one
cat "${tmpfile}".* 2>/dev/null >"$tmpfile" || true
# Gather totals from the temporary file
total=$(find "$ROOT" -name ".git" -type d | wc -l)
dirty_count=$(grep -c "^DIRTY$" "$tmpfile" 2>/dev/null || echo 0)
unpushed_count=$(grep -c "^AHEAD:" "$tmpfile" 2>/dev/null || echo 0)
ahead_count=$(awk -F: '/^AHEAD:/ {sum+=$2} END {print sum}' "$tmpfile" 2>/dev/null || echo 0)
behind_count=$(awk -F: '/^BEHIND:/ {sum+=$2} END {print sum}' "$tmpfile" 2>/dev/null || echo 0)

# Summary
echo ""
echo "--- Summary ---"
echo "Scanned repositories: $total"
echo -e "${RED}Dirty: $dirty_count${NC}"
echo -e "${YELLOW}Repos with unpushed commits: $unpushed_count${NC}"
echo -e "${YELLOW}Total ahead commits: $ahead_count${NC}"
echo -e "${BLUE}Total behind commits: $behind_count${NC}"
rm -f "${tmpfile}".*
