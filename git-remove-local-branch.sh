#!/usr/bin/env bash
# git-remove-local-branch.sh
# Interactive local-branch cleanup (no remote deletion).

set -o pipefail

# ---------- Colors ----------
PINK='\033[1;35m'
GREEN='\033[1;32m'
ITALIC='\033[3m'
RED='\033[1;31m'
RESET='\033[0m'
BOLDYELLOW='\033[1;33m'
YELLOW='\033[33m'

# ---------- Helpers ----------
die() {
	printf "%b%s%b\n" "$RED" "$*" "$RESET" >&2
	exit 1
}

warn() {
	printf "%b%s%b\n" "$BOLDYELLOW" "$*" "$RESET"
}

info() {
	printf "%b%s%b\n" "$GREEN" "$*" "$RESET"
}

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

print_final_state() {
	local deleted_count="$1"
	local skipped_count="$2"
	local failed_count="$3"

	printf "\n%bState:%b\n" "$YELLOW" "$RESET"
	printf "  Deleted: %s\n" "$deleted_count"
	printf "  Skipped: %s\n" "$skipped_count"
	printf "  Failed:  %s\n" "$failed_count"

	if ((deleted_count == 0)); then
		printf "%bNo branches were deleted.%b\n" "$BOLDYELLOW" "$RESET"
	else
		printf "%bBranch cleanup completed.%b\n" "$GREEN" "$RESET"
	fi
}

# ---------- Listing ----------
list_local_branches() {
	local branches_with_info
	if ! branches_with_info=$(git for-each-ref \
		--sort=creatordate \
		--format='%(refname:short) %(creatordate:format:%m-%d-%y) %(authorname)' refs/heads/); then
		return 1
	fi

	local max_branch_length
	max_branch_length=$(printf "%s\n" "$branches_with_info" | awk '{print length($1)}' | sort -nr | head -n1)

	printf "\nLocal branches:\n\n"

	printf "%s\n" "$branches_with_info" | while IFS=' ' read -r branch creation_date author; do
		local color end_color padding
		if [[ "$branch" == "main" || "$branch" == "master" ]]; then
			color=$GREEN
		else
			color=$PINK
		fi
		end_color=$RESET

		padding=$((max_branch_length + 2 - ${#branch}))

		printf "%b%s%*s%s | %bAuthor:%b %s\n" \
			"$color" "$branch" "$padding" "" "$creation_date" "$YELLOW" "$end_color" "$author"
	done

	printf "\n"
}

# ---------- Selection ----------
list_deletable_branches() {
	local curr
	curr=$(current_branch)

	git for-each-ref --format='%(refname:short)' refs/heads |
		while IFS= read -r branch; do
			[[ "$branch" == "$curr" ]] && continue
			is_protected "$branch" && continue
			printf "%s\n" "$branch"
		done
}

select_branches_interactive() {
	if command -v fzf >/dev/null 2>&1; then
		printf "Select branches to delete (TAB multi-select, ENTER confirm):\n" >&2
		list_deletable_branches |
			fzf -m --height=40% --border |
			tr '\n' ' ' | sed 's/ $//'
	else
		local temp_file
		if ! temp_file=$(mktemp); then
			printf "Error: mktemp failed\n" >&2
			return 1
		fi

		bash -c 'read -r -p "What branches? (space-separated): " input; printf "%s" "$input" > '"$temp_file"' 2>/dev/tty </dev/tty'

		local result
		result=$(cat "$temp_file")
		rm -f "$temp_file"

		printf "%s" "$result"
	fi
}

# ---------- Deletion ----------
delete_branches() {
	local branches=("$@")
	local num curr

	num=${#branches[@]}
	if ((num == 0)); then
		printf "No branch selected. Exiting.\n" >&2
		return 1
	fi

	curr=$(current_branch)
	if [[ -z "$curr" ]]; then
		die "Cannot determine current branch"
	fi

	local b
	for b in "${branches[@]}"; do
		if [[ ! "$b" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
			die "Invalid branch name format: $b"
		fi

		if [[ "$b" == "$curr" ]]; then
			die "Refusing to delete current branch: $b"
		fi

		if is_protected "$b"; then
			die "Refusing to delete protected branch: $b"
		fi

		if ! git show-ref --verify --quiet "refs/heads/$b"; then
			die "Branch does not exist: $b"
		fi
	done

	printf "\n%bWarning!%b %bDeleting:%b %b%s%b\n\n" \
		"$RED" "$RESET" "$YELLOW" "$RESET" "$PINK" "${branches[*]}" "$RESET"

	printf "%bType %bconfirm%b or %bq%b:%b " \
		"$YELLOW" "$GREEN" "$RESET" "$ITALIC" "$RESET" "$RESET"

	local confirm
	read -r confirm

	local deleted_count=0
	local skipped_count=0
	local failed_count=0

	case "$confirm" in
	confirm | con | conf)
		for b in "${branches[@]}"; do
			if ! git show-ref --verify --quiet "refs/heads/$b"; then
				warn "Branch disappeared before deletion: $b"
				((skipped_count += 1))
				continue
			fi

			if git branch -d "$b"; then
				printf "%bBranch '%s' deleted.%b\n" "$GREEN" "$b" "$RESET"
				((deleted_count += 1))
			else
				warn "Not fully merged: $b"
				printf "Force delete '%s'? [y/N] " "$b"

				local ans
				read -r ans

				if [[ "$ans" =~ ^[Yy]$ ]]; then
					if git branch -D "$b"; then
						printf "%bForce-deleted '%s'%b\n" "$GREEN" "$b" "$RESET"
						((deleted_count += 1))
					else
						printf "%bFailed force-delete '%s'%b\n" "$RED" "$b" "$RESET" >&2
						((failed_count += 1))
					fi
				else
					printf "Skipped '%s'\n" "$b"
					((skipped_count += 1))
				fi
			fi
		done

		print_final_state "$deleted_count" "$skipped_count" "$failed_count"
		;;
	q | n | no | quit | exit)
		printf "Quitting.\n"
		print_final_state 0 "${#branches[@]}" 0
		return 0
		;;
	*)
		printf "%bInvalid option: %s%b\n" "$RED" "$confirm" "$RESET"
		printf "Expected: confirm, con, conf, q, quit, n, no, or exit.\n"
		print_final_state 0 "${#branches[@]}" 0
		return 1
		;;
	esac
}

# ---------- Main ----------
main() {
	require_git_repo

	list_local_branches

	local selection
	if ! selection=$(select_branches_interactive); then
		return 1
	fi

	if [[ -z "$selection" ]]; then
		printf "No branches selected. Exiting.\n" >&2
		return 1
	fi

	local branches clean_branches branch
	# shellcheck disable=SC2206
	branches=($selection)

	clean_branches=()
	for branch in "${branches[@]}"; do
		[[ -n "$branch" ]] && clean_branches+=("$branch")
	done

	if ((${#clean_branches[@]} == 0)); then
		printf "No valid branches selected.\n" >&2
		return 1
	fi

	delete_branches "${clean_branches[@]}"
}

main "$@"
