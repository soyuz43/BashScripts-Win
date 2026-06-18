#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

BLOCK_PATTERNS=(
	"^code\.md$"
	"^code-.*\.md$"
	"^diff\.txt$"
)

# ------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------

check_branch() {
	local branch_name
	branch_name=$(git rev-parse --abbrev-ref HEAD)
	if [[ "$branch_name" == "main" || "$branch_name" == "master" ]]; then
		printf "\e[1;31mError: on %s — commit manually.\e[0m\n" "$branch_name" >&2
		return 1
	fi
}

fix_crlf() {
	echo -e "\n\e[1;3;36mNormalizing line endings (LF)...\e[0m"
	git ls-files -z --cached --others --exclude-standard '*.sh' | while IFS= read -r -d '' file; do
		if [[ -f "$file" ]]; then # <-- only if file exists
			sed -i 's/\r$//' "$file"
		fi
	done
}

detect_crlf() {
	local bad_files=()
	while IFS= read -r -d '' file; do
		if [[ -f "$file" ]] && grep -q $'\r' "$file"; then # <-- skip missing
			bad_files+=("$file")
		fi
	done < <(git ls-files -z --cached --others --exclude-standard '*.sh')

	if ((${#bad_files[@]} > 0)); then
		echo -e "\n\e[1;31mCRLF detected in:\e[0m"
		printf '  %s\n' "${bad_files[@]}"
		exit 1
	fi
}

format_shell() {
	if command -v shfmt >/dev/null 2>&1; then
		echo -e "\n\e[1;3;36mFormatting shell scripts (shfmt)...\e[0m"

		local files=()

		while IFS= read -r -d '' file; do
			[[ -f "$file" ]] || continue
			files+=("$file")
		done < <(
			git ls-files -z --cached --others --exclude-standard -- '*.sh'
		)

		if ((${#files[@]} > 0)); then
			shfmt -w "${files[@]}"
		fi

		echo -e "\e[1;32mFormatting complete.\e[0m"
	else
		echo -e "\n\e[1;33mshfmt not installed — skipping.\e[0m"
	fi
}

run_shellcheck() {
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo -e "\n\e[1;33mShellCheck not installed — skipping.\e[0m"
		return 0
	fi

	echo -e "\n\e[1;3;36mRunning ShellCheck...\e[0m"

	local staged_sh_files
	staged_sh_files=$(git diff --cached --name-only | grep -E '\.sh$' || true)

	[[ -z "$staged_sh_files" ]] && return 0

	local failed=0

	while IFS= read -r file; do
		[[ -f "$file" ]] || continue

		echo -e "\nChecking $file"

		if ! shellcheck -S error "$file"; then
			failed=1
		fi
	done <<<"$staged_sh_files"

	if [[ $failed -ne 0 ]]; then
		echo -e "\n\e[1;31mShellCheck failed. Fix errors before committing.\e[0m"
		return 1
	fi

	echo -e "\n\e[1;32mShellCheck passed.\e[0m"
}

block_junk_files() {
	local staged_files blocked_found=()

	staged_files=$(git diff --cached --name-only)

	while IFS= read -r file; do
		for pattern in "${BLOCK_PATTERNS[@]}"; do
			if [[ "$file" =~ $pattern ]]; then
				blocked_found+=("$file")
			fi
		done
	done <<<"$staged_files"

	if ((${#blocked_found[@]} > 0)); then
		echo -e "\n\e[1;31mBlocked files detected:\e[0m"
		printf '  - %s\n' "${blocked_found[@]}"

		read -r -p $'\e[1;33mRemove them and continue? ([y]/n): \e[0m' fix
		fix=${fix:-y}

		if [[ "$fix" == "y" ]]; then
			for f in "${blocked_found[@]}"; do
				git restore --staged "$f"
			done
			echo -e "\e[1;32mRemoved from staging.\e[0m"
		else
			echo -e "\e[1;31mCommit aborted.\e[0m"
			return 1
		fi
	fi
}

review_changes() {
	echo -e "\n\e[1;3;36mStaged snapshot:\e[0m"
	git status --porcelain

	echo -e "\n\e[1;3;36mSummary:\e[0m"
	git --no-pager diff --staged --stat
}

confirm_commit() {
	local decision msg trimmed

	read -r -p $'\e[1;33mCommit? [[y]/N or message]: \e[0m' decision
	decision=${decision:-y}

	case "$decision" in
	y | Y)
		read -r -p $'\e[1;32mCommit message: \e[0m' msg
		;;

	n | N)
		echo -e "\e[1;31mCommit aborted.\e[0m"
		return 1
		;;

	*)
		msg="$decision"

		# Fast-path safety check:
		# prevent accidental short input from becoming a commit message.
		trimmed="${msg//[[:space:]]/}"

		if ((${#trimmed} < 5)); then
			echo -e "\e[1;31mCommit blocked: message too short to safely interpret.\e[0m"
			echo -e "\e[1;33mUse Enter or 'y' and enter a short message below.\e[0m"
			return 1
		fi

		echo -e "\n\e[1;36mInline commit message detected:\e[0m"
		printf "  %s\n" "$msg"
		echo -e "\e[1;32mProceeding with commit...\e[0m"
		;;
	esac

	git commit -m "$msg"

	echo -e "\e[1;32mCommit successful.\e[0m"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {

	[[ -d ".git" ]] || {
		echo -e "\e[1;31mNot a git repository.\e[0m"
		return 1
	}

	check_branch

	fix_crlf
	detect_crlf

	format_shell

	git add .

	if git diff --cached --quiet; then
		echo -e "\e[1;33mNo changes to commit.\e[0m"
		return 0
	fi

	run_shellcheck

	block_junk_files

	review_changes

	confirm_commit
}

main "$@"
