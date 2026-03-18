#!/usr/bin/env bash
# git-remove-local-branch.sh
# Interactive local-branch cleanup (no remote deletion).

set -o pipefail

# ---------- Colors ----------
PINK='\033[1;35m'  # Bold Pink (non-main branches)
GREEN='\033[1;32m' # Bold Green (main/master)
BOLD='\033[1m'
ITALIC='\033[3m'
RED='\033[1;31m' # Bold Red (warnings)
RESET='\033[0m'
BOLDYELLOW='\033[1;33m'
YELLOW='\033[33m' # Author names

# ---------- Helpers ----------
die() {
	printf "${RED}%s${RESET}\n" "$*" >&2
	exit 1
}
warn() { printf "${BOLDYELLOW}%s${RESET}\n" "$*"; }
info() { printf "${GREEN}%s${RESET}\n" "$*"; }

require_git_repo() {
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git repository."
}

current_branch() {
	git rev-parse --abbrev-ref HEAD 2>/dev/null
}

is_protected() {
	case "$1" in
	main | master | develop | dev) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------- Listing ----------
list_local_branches() {
	# Format: <name> <MM-DD-YY> <author>
	local branches_with_info
	branches_with_info=$(git for-each-ref \
		--sort=creatordate \
		--format='%(refname:short) %(creatordate:format:%m-%d-%y) %(authorname)' refs/heads/) || return 1

	# Compute max name length for alignment
	local max_branch_length
	max_branch_length=$(echo "$branches_with_info" | awk '{print length($1)}' | sort -nr | head -n1)

	printf "\nLocal branches:\n\n"
	echo "$branches_with_info" | while IFS=' ' read -r branch creation_date author; do
		# Choose color for branch name
		local color end_color
		if [[ "$branch" == "main" || "$branch" == "master" ]]; then
			color=$GREEN
			end_color=$RESET
		else
			color=$PINK
			end_color=$RESET
		fi
		# padding
		local padding=$((max_branch_length + 2 - ${#branch}))
		# aligned, colored line
		printf "%b%s%*s%s | %bAuthor:%b %s\n" \
			"$color" "$branch" "$padding" "" "$creation_date" "$YELLOW" "$end_color" "$author"
	done
	printf "\n"
}

# ---------- Selection ----------
select_branches_interactive() {
	# Returns selection via stdout (space-separated) or empty string
	if command -v fzf >/dev/null 2>&1; then
		# Print the prompt to terminal, not to stdout that gets captured
		printf "Select branches to delete (TAB to multi-select, ENTER to confirm):\n" >&2
		# Run fzf and capture only its selection output, not the prompt
		git for-each-ref --format='%(refname:short)' refs/heads |
			fzf -m --height=40% --border |
			tr '\n' ' ' | sed 's/ $//'
	else
		# Create a temporary file to store the result
		local temp_file
		temp_file=$(mktemp)

		# Use bash -i to ensure interactive mode
		bash -c 'read -r -p "What branches? (space-separated): " input; echo "$input" > '"$temp_file"' 2>/dev/tty </dev/tty'

		# Read the result and clean up
		local result
		result=$(cat "$temp_file")
		rm -f "$temp_file"
		echo "$result"
	fi
}

# ---------- Deletion ----------
delete_branches() {
	local branches=("$@")
	local num=${#branches[@]}
	if ((num == 0)); then
		printf "No branch selected. Exiting.\n" >&2
		return 1
	fi

	# Validate branch names and re-check current branch (race condition prevention)
	local curr
	curr="$(current_branch)"
	if [[ -z "$curr" ]]; then
		die "Cannot determine current branch"
	fi

	for b in "${branches[@]}"; do
		# Validate branch name format (basic validation)
		if [[ ! "$b" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
			die "Invalid branch name format: $b"
		fi

		if [[ "$b" == "$curr" ]]; then
			die "Refusing to delete the current branch: $b"
		fi
		if is_protected "$b"; then
			die "Refusing to delete protected branch: $b"
		fi

		# Verify branch actually exists
		if ! git show-ref --verify --quiet "refs/heads/$b"; then
			die "Branch does not exist: $b"
		fi
	done

	printf "\n${RED}Warning!${RESET} ${YELLOW}You are about to delete branch(es):${RESET} ${PINK}%s${RESET}\n\n" "${branches[*]}"
	printf "${YELLOW}Type ${ITALIC}${GREEN}confirm${RESET}${YELLOW} to delete, or ${ITALIC}q${RESET}${YELLOW} to quit:${RESET} "
	local confirm
	read -r confirm

	case "$confirm" in
	confirm | con | conf)
		for b in "${branches[@]}"; do
			# Re-verify branch exists before deletion (race condition)
			if ! git show-ref --verify --quiet "refs/heads/$b"; then
				warn "Branch no longer exists: $b"
				continue
			fi

			if git branch -d "$b"; then
				printf "${GREEN}Branch '%s' deleted successfully.${RESET}\n" "$b"
			else
				# Offer force delete when not fully merged
				warn "Branch '$b' is not fully merged or could not be deleted."
				printf "Force delete '%s'? [y/N] " "$b"
				local ans
				read -r ans
				if [[ "$ans" =~ ^[Yy]$ ]]; then
					if git branch -D "$b"; then
						printf "${GREEN}Branch '%s' force-deleted.${RESET}\n" "$b"
					else
						printf "${RED}Failed to force-delete '%s'.${RESET}\n" "$b" >&2
					fi
				else
					printf "Skipped '%s'.\n" "$b"
				fi
			fi
		done
		;;
	q | n | no | quit | exit)
		printf "Quitting.\n"
		return 0
		;;
	*)
		printf "${RED}Invalid option. Exiting.${RESET}\n"
		return 1
		;;
	esac
}

# ---------- Main ----------
main() {
	require_git_repo

	list_local_branches

	# Selection (fzf or manual)
	local selection
	selection=$(select_branches_interactive)

	# Validate and convert selection to array safely
	if [[ -n "$selection" ]]; then
		# shellcheck disable=SC2206
		local branches=($selection)

		# Remove empty elements
		local clean_branches=()
		for branch in "${branches[@]}"; do
			if [[ -n "$branch" ]]; then
				clean_branches+=("$branch")
			fi
		done

		if ((${#clean_branches[@]} > 0)); then
			delete_branches "${clean_branches[@]}"
		else
			printf "No valid branches selected.\n" >&2
			return 1
		fi
	else
		printf "No branches selected. Exiting.\n" >&2
		return 1
	fi
}

main "$@"
