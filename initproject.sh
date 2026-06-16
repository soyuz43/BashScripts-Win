#!/usr/bin/env bash
# new-project.sh
# Bootstrap a new project with Git, GitHub remote, and optional feature branch.
# Usage:
#   bash new-project.sh [--dry-run] [project-name] [feature-branch]

set -euo pipefail

# ---------- ANSI helpers (consistent with install.sh) ----------
BOLD=""
DIM=""
GREEN=""
YELLOW=""
RED=""
BLUE=""
CYAN=""
RESET=""
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	BOLD=$'\033[1m'
	DIM=$'\033[2m'
	GREEN=$'\033[1;32m'
	YELLOW=$'\033[1;33m'
	RED=$'\033[1;31m'
	BLUE=$'\033[1;34m'
	CYAN=$'\033[1;36m'
	RESET=$'\033[0m'
fi

# ---------- Logging ----------
LOG_FILE="$HOME/.local/share/bashscripts/new-project.log"
mkdir -p "$(dirname "$LOG_FILE")"

log_action() {
	local msg="$1"
	printf "[%s] %s\n" "$(date -Iseconds)" "$msg" >>"$LOG_FILE"
}

# ---------- Dry-run helper ----------
DRY_RUN=0
run_cmd() {
	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b %s\n" "$DIM" "$RESET" "$*"
	else
		"$@"
	fi
}

# ---------- Early GitHub auth check ----------
check_gh_auth() {
	if ! command -v gh &>/dev/null; then
		printf "%b[WARN] GitHub CLI not found. Install: https://cli.github.com/%b\n" "$YELLOW" "$RESET"
		return 1
	fi
	if ! gh auth status &>/dev/null; then
		printf "%b[WARN] GitHub CLI is not authenticated.%b\n" "$YELLOW" "$RESET"
		if ((!DRY_RUN)); then
			read -rp "Would you like to log in now? [y/N] " answer
			if [[ "${answer,,}" == y || "${answer,,}" == yes ]]; then
				run_cmd gh auth login
			else
				printf "%b[INFO] Continuing without GitHub authentication. Remote setup will be skipped.%b\n" "$BLUE" "$RESET"
				return 1
			fi
		else
			printf "%b[DRY RUN] Would attempt 'gh auth login'%b\n" "$DIM" "$RESET"
			return 1
		fi
	fi
	return 0
}

# ---------- Atomic cleanup on failure ----------
PROJECT_PATH=""
ORIG_DIR_EXISTED=0
REMOTE_CREATED=0

cleanup_on_error() {
	printf "%b[ERROR] A failure occurred. Cleaning up partially created project.%b\n" "$RED" "$RESET"
	if ((!DRY_RUN)) && [[ -n "$PROJECT_PATH" ]] && [[ -d "$PROJECT_PATH" ]] && ((!ORIG_DIR_EXISTED)); then
		printf "Removing directory: %s\n" "$PROJECT_PATH"
		rm -rf "$PROJECT_PATH"
		log_action "Cleaned up directory $PROJECT_PATH"
	fi
	if ((REMOTE_CREATED)) && ((!DRY_RUN)); then
		printf "Attempting to delete remote repository: %s\n" "$PROJECT_NAME"
		gh repo delete "$PROJECT_NAME" --yes 2>/dev/null || true
		log_action "Cleaned up remote repository $PROJECT_NAME"
	fi
}
trap cleanup_on_error ERR

# ---------- Interactive inputs ----------
prompt_for_inputs() {
	if [[ -z "${1:-}" ]]; then
		read -rp "Project name: " PROJECT_NAME
	else
		PROJECT_NAME="$1"
	fi
	if [[ -z "${2:-}" ]]; then
		read -rp "Feature branch (optional): " FEATURE_BRANCH
	else
		FEATURE_BRANCH="$2"
	fi

	# Metadata prompts for future template integration
	if [[ -z "${LANGUAGE:-}" ]]; then
		read -rp "Language (e.g., python, rust) or Enter to skip: " LANGUAGE
	fi
	if [[ -z "${TEMPLATE:-}" && -n "${LANGUAGE:-}" ]]; then
		read -rp "Template (or Enter to skip): " TEMPLATE
	fi
}

# ---------- Validation ----------
validate_project_name() {
	if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		printf "%b[ERROR] Invalid project name. Allowed: a-z, 0-9, ., -, _%b\n" "$RED" "$RESET" >&2
		return 1
	fi
	PROJECT_PATH="$BASE_DIR/$PROJECT_NAME"
	if [[ -e "$PROJECT_PATH" ]]; then
		printf "%b[ERROR] '%s' already exists.%b\n" "$RED" "$PROJECT_PATH" "$RESET" >&2
		return 1
	fi
	ORIG_DIR_EXISTED=0 # we know it doesn't exist
	log_action "Project path: $PROJECT_PATH"
}

# ---------- Directory structure ----------
create_structure() {
	run_cmd mkdir -p "$PROJECT_PATH/src" "$PROJECT_PATH/tests" "$PROJECT_PATH/docs"
	run_cmd touch "$PROJECT_PATH/README.md" "$PROJECT_PATH/.gitignore" "$PROJECT_PATH/LICENSE"
	run_cmd touch "$PROJECT_PATH/docs/overview.md"
	log_action "Created directory structure for $PROJECT_NAME"
}

# ---------- Git init ----------
init_git_repo() {
	cd "$PROJECT_PATH"
	if [[ ! -d .git ]]; then
		run_cmd git init
		printf "%b[ OK ]%b Git repository initialized.\n" "$GREEN" "$RESET"
		log_action "Initialized Git repository in $PROJECT_PATH"
	else
		printf "%b[WARN] Git repository already exists — skipping init.%b\n" "$YELLOW" "$RESET"
	fi
}

# ---------- Remote setup ----------
setup_remote() {
	if ! command -v gh &>/dev/null; then
		printf "%b[WARN] GitHub CLI missing. Skipping remote setup.%b\n" "$YELLOW" "$RESET"
		return 0
	fi
	if git remote get-url origin &>/dev/null; then
		printf "%b[WARN] Remote 'origin' already exists — skipping.%b\n" "$YELLOW" "$RESET"
		return 0
	fi

	if check_gh_auth; then
		run_cmd gh repo create "$PROJECT_NAME" --source=. --public --remote=origin
		REMOTE_CREATED=1
		printf "%b[ OK ]%b Remote repository created and linked.\n" "$GREEN" "$RESET"
		log_action "Created remote GitHub repo $PROJECT_NAME"
	else
		printf "%b[INFO] Remote setup skipped because GitHub CLI authentication is required.%b\n" "$BLUE" "$RESET"
	fi
}

# ---------- Initial commit & push ----------
make_initial_commit_and_push_main() {
	if ! git rev-parse --verify HEAD &>/dev/null; then
		run_cmd git add .
		run_cmd git commit -m "initial commit"
		run_cmd git branch -M main
		log_action "Created initial commit on main"
		if git remote get-url origin &>/dev/null; then
			run_cmd git push -u origin main
			printf "%b[ OK ]%b Initial commit pushed to 'main'.\n" "$GREEN" "$RESET"
			log_action "Pushed main to origin"
		else
			printf "%b[INFO] No remote configured. Commit remains local.%b\n" "$BLUE" "$RESET"
		fi
	else
		printf "%b[WARN] Repository already has commits — skipping commit/push.%b\n" "$YELLOW" "$RESET"
	fi
}

# ---------- Feature branch ----------
create_feature_branch() {
	if [[ -n "$FEATURE_BRANCH" ]]; then
		if git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
			run_cmd git switch "$FEATURE_BRANCH"
			printf "%b[ OK ]%b Switched to existing branch: %s\n" "$GREEN" "$RESET" "$FEATURE_BRANCH"
		else
			run_cmd git switch -c "$FEATURE_BRANCH"
			printf "%b[ OK ]%b Created and switched to new branch: %s\n" "$GREEN" "$RESET" "$FEATURE_BRANCH"
		fi
		log_action "Switched to feature branch $FEATURE_BRANCH"
	fi
}

# ---------- Summary ----------
print_summary() {
	local user
	user=$(gh api user --jq .login 2>/dev/null || echo "unknown-user")

	printf "\n%b=== Project '%s' initialized ===%b\n" "$BOLD$CYAN" "$PROJECT_NAME" "$RESET"
	printf "   %bLocal:%b  cd %q\n" "$BOLD" "$RESET" "$PROJECT_PATH"
	if git remote get-url origin &>/dev/null; then
		printf "   %bGitHub:%b https://github.com/%s/%s\n" "$BOLD" "$RESET" "$user" "$PROJECT_NAME"
	fi
	printf "\n%b--> Next Steps:%b\n" "$BOLD" "$RESET"
	printf "    cd %q\n" "$PROJECT_PATH"
	printf "    code .\n"
	if [[ -n "$FEATURE_BRANCH" ]] && git remote get-url origin &>/dev/null; then
		printf "    git push -u origin %s  # when ready\n" "$FEATURE_BRANCH"
	fi
}

# ---------- Main ----------
main() {
	if [[ "${1:-}" == "--dry-run" ]]; then
		DRY_RUN=1
		shift
	fi

	BASE_DIR="${BASE_DIR:-$HOME/workspace/personal}"
	PROJECT_NAME=""
	FEATURE_BRANCH=""
	LANGUAGE=""
	TEMPLATE=""

	prompt_for_inputs "$@"
	validate_project_name
	create_structure
	init_git_repo
	setup_remote
	make_initial_commit_and_push_main
	create_feature_branch
	print_summary

	# Success – disable error cleanup trap
	trap - ERR
	log_action "Project $PROJECT_NAME created successfully."
}

main "$@"
