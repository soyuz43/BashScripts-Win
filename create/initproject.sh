#!/usr/bin/env bash
# new-project.sh
# Bootstrap a new project with Git, an optional GitHub repository,
# and an optional feature branch.
#
# Usage:
#   bash new-project.sh [options] [project-name] [feature-branch]
#
# Options:
#   --remote
#       Create a GitHub repository and configure it as origin.
#
#   --no-remote, --local-only
#       Create only the local Git repository.
#
#   --pub, --public
#       Create a public GitHub repository. Implies --remote.
#
#   --priv, --private
#       Create a private GitHub repository. Implies --remote.
#
#   --dry-run
#       Display planned commands without making changes.
#
#   -h, --help
#       Display this help message.

set -Eeuo pipefail
set -o pipefail

# ---------- ANSI helpers ----------
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

# ---------- Runtime configuration ----------
DRY_RUN=0

BASE_DIR=""
PROJECT_NAME=""
PROJECT_PATH=""
FEATURE_BRANCH=""
LANGUAGE=""

PROJECT_NAME_ARGUMENT=""
FEATURE_BRANCH_ARGUMENT=""

REMOTE_REQUEST="ask"
REPOSITORY_VISIBILITY="ask"
REMOTE_CREATED=0
REMOTE_CONFIGURED=0
REMOTE_REPOSITORY=""
REMOTE_URL=""
GH_LOGIN=""

LOCAL_PROJECT_CREATED=0
PROJECT_COMPLETE=0

LOG_DIR=""
LOG_FILE=""

# ---------- Output ----------
print_error() {
	local message
	message=$1

	printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$message" >&2
}

print_warning() {
	local message
	message=$1

	printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$message" >&2
}

print_info() {
	local message
	message=$1

	printf "%b[INFO]%b %s\n" "$BLUE" "$RESET" "$message"
}

print_success() {
	local message
	message=$1

	printf "%b[ OK ]%b %s\n" "$GREEN" "$RESET" "$message"
}

print_help() {
	printf '%s\n' \
		'new-project.sh' \
		'Bootstrap a new project with Git, an optional GitHub repository,' \
		'and an optional feature branch.' \
		'' \
		'Usage:' \
		'  bash new-project.sh [options] [project-name] [feature-branch]' \
		'' \
		'Options:' \
		'  --remote' \
		'      Create a GitHub repository and configure it as origin.' \
		'' \
		'  --no-remote, --local-only' \
		'      Create only the local Git repository.' \
		'' \
		'  --pub, --public' \
		'      Create a public GitHub repository. Implies --remote.' \
		'' \
		'  --priv, --private' \
		'      Create a private GitHub repository. Implies --remote.' \
		'' \
		'  --dry-run' \
		'      Display planned commands without making changes.' \
		'' \
		'  -h, --help' \
		'      Display this help message.' \
		'' \
		'Environment:' \
		'  BASE_DIR' \
		'      Parent directory for new projects.' \
		"      Default: ${HOME:-\$HOME}/workspace/personal" \
		'' \
		'  LANGUAGE' \
		'      Optional project language metadata.' \
		'' \
		'Examples:' \
		'  bash new-project.sh --private example-api feature/auth' \
		'  bash new-project.sh --public example-cli' \
		'  bash new-project.sh --no-remote local-tool' \
		'  bash new-project.sh --dry-run --remote example-service'
}

# ---------- Validation helpers ----------
contains_control_characters() {
	local value
	value=$1

	[[ "$value" == *$'\r'* ||
	   "$value" == *$'\n'* ||
	   "$value" == *$'\t'* ]]
}

sanitize_single_line_input() {
	local value
	value=$1
	value=${value//$'\r'/}

	printf '%s' "$value"
}

# ---------- Logging ----------
initialize_paths() {
	local data_root

	if [[ -z "${HOME:-}" ]]; then
		print_error "HOME is not defined."
		return 1
	fi

	data_root=${XDG_DATA_HOME:-"$HOME/.local/share"}

	if contains_control_characters "$data_root"; then
		print_error "The configured data directory contains invalid control characters."
		return 1
	fi

	LOG_DIR="$data_root/bashscripts"
	LOG_FILE="$LOG_DIR/new-project.log"
	BASE_DIR=${BASE_DIR:-"$HOME/workspace/personal"}

	if [[ -z "$BASE_DIR" ]]; then
		print_error "BASE_DIR cannot be empty."
		return 1
	fi

	if contains_control_characters "$BASE_DIR"; then
		print_error "BASE_DIR contains invalid control characters."
		return 1
	fi

	BASE_DIR=${BASE_DIR%/}

	if [[ -z "$BASE_DIR" ]]; then
		BASE_DIR="/"
	fi
}

initialize_logging() {
	if ! mkdir -p -- "$LOG_DIR"; then
		print_error "Unable to create the log directory: $LOG_DIR"
		return 1
	fi

	if ! touch -- "$LOG_FILE"; then
		print_error "Unable to access the log file: $LOG_FILE"
		return 1
	fi
}

log_action() {
	local message
	local timestamp

	message=$1

	if ! timestamp=$(date -Iseconds 2>/dev/null); then
		if ! timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null); then
			timestamp="timestamp-unavailable"
		fi
	fi

	if ! printf '[%s] %s\n' "$timestamp" "$message" >>"$LOG_FILE"; then
		print_warning "Unable to write to the log file: $LOG_FILE"
	fi
}

# ---------- Dry-run support ----------
print_command() {
	local argument

	printf '%b[DRY RUN]%b' "$DIM" "$RESET"

	for argument in "$@"; do
		printf ' %q' "$argument"
	done

	printf '\n'
}

run_cmd() {
	if ((DRY_RUN)); then
		print_command "$@"
		return
	fi

	"$@"
}

# ---------- Cleanup ----------
cleanup_on_error() {
	local status
	status=$1

	trap - ERR
	set +e

	if ((PROJECT_COMPLETE)); then
		return "$status"
	fi

	printf '\n%b[ERROR]%b Project creation failed. Rolling back completed changes.\n' \
		"$RED" "$RESET" >&2

	if ((REMOTE_CREATED)) && [[ -n "$REMOTE_REPOSITORY" ]]; then
		printf 'Removing GitHub repository: %s\n' "$REMOTE_REPOSITORY" >&2

		if ! gh repo delete "$REMOTE_REPOSITORY" --yes >/dev/null 2>&1; then
			print_warning "Unable to remove GitHub repository: $REMOTE_REPOSITORY"
		else
			log_action "Removed GitHub repository after failure: $REMOTE_REPOSITORY"
		fi
	fi

	if ((LOCAL_PROJECT_CREATED)) &&
		[[ -n "$PROJECT_PATH" ]] &&
		[[ "$PROJECT_PATH" != "/" ]] &&
		[[ -d "$PROJECT_PATH" ]]
	then
		printf 'Removing local project directory: %s\n' "$PROJECT_PATH" >&2

		if ! rm -rf -- "$PROJECT_PATH"; then
			print_warning "Unable to remove local project directory: $PROJECT_PATH"
		else
			log_action "Removed local project directory after failure: $PROJECT_PATH"
		fi
	fi

	return "$status"
}

handle_signal() {
	local signal_name
	signal_name=$1

	printf '\n%b[ERROR]%b Received %s. Aborting.\n' \
		"$RED" "$RESET" "$signal_name" >&2
}

trap 'cleanup_on_error "$?"' ERR
trap 'handle_signal "SIGINT"; exit 130' INT
trap 'handle_signal "SIGTERM"; exit 143' TERM
trap 'handle_signal "SIGHUP"; exit 129' HUP

# ---------- Dependency validation ----------
validate_dependencies() {
	local command_name
	local -a required_commands
	local -a missing_commands

	required_commands=(date git mkdir rm touch)
	missing_commands=()

	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing_commands+=("$command_name")
		fi
	done

	if ((${#missing_commands[@]} > 0)); then
		printf '%b[ERROR]%b Missing required command(s): %s\n' \
			"$RED" "$RESET" "${missing_commands[*]}" >&2
		return 1
	fi
}

# ---------- Argument state ----------
set_remote_request() {
	local requested_value
	requested_value=$1

	if [[ "$requested_value" != "yes" && "$requested_value" != "no" ]]; then
		print_error "Invalid remote request state: $requested_value"
		return 1
	fi

	if [[ "$REMOTE_REQUEST" != "ask" && "$REMOTE_REQUEST" != "$requested_value" ]]; then
		print_error "Conflicting remote creation options were provided."
		return 1
	fi

	if [[ "$requested_value" == "no" && "$REPOSITORY_VISIBILITY" != "ask" ]]; then
		print_error "--no-remote cannot be combined with a repository visibility option."
		return 1
	fi

	REMOTE_REQUEST=$requested_value
}

set_repository_visibility() {
	local requested_visibility
	requested_visibility=$1

	if [[ "$requested_visibility" != "public" &&
	      "$requested_visibility" != "private" ]]
	then
		print_error "Invalid repository visibility: $requested_visibility"
		return 1
	fi

	if [[ "$REMOTE_REQUEST" == "no" ]]; then
		print_error "Repository visibility cannot be used with --no-remote."
		return 1
	fi

	if [[ "$REPOSITORY_VISIBILITY" != "ask" &&
	      "$REPOSITORY_VISIBILITY" != "$requested_visibility" ]]
	then
		print_error "Conflicting repository visibility options were provided."
		return 1
	fi

	REPOSITORY_VISIBILITY=$requested_visibility
	REMOTE_REQUEST="yes"
}

# ---------- Argument parsing ----------
parse_arguments() {
	local argument
	local -a positional_arguments

	positional_arguments=()

	while (($# > 0)); do
		argument=$1

		case "$argument" in
			--dry-run)
				DRY_RUN=1
				;;
			--remote)
				if ! set_remote_request "yes"; then
					return 1
				fi
				;;
			--no-remote | --local-only)
				if ! set_remote_request "no"; then
					return 1
				fi
				;;
			--pub | --public | --pubic)
				if ! set_repository_visibility "public"; then
					return 1
				fi
				;;
			--priv | --private)
				if ! set_repository_visibility "private"; then
					return 1
				fi
				;;
			-h | --help)
				print_help
				return 2
				;;
			--)
				shift

				while (($# > 0)); do
					positional_arguments+=("$1")
					shift
				done

				break
				;;
			-*)
				print_error "Unknown option: $argument"
				return 1
				;;
			*)
				positional_arguments+=("$argument")
				;;
		esac

		shift
	done

	if ((${#positional_arguments[@]} > 2)); then
		print_error "Expected at most a project name and a feature branch."
		return 1
	fi

	if ((${#positional_arguments[@]} >= 1)); then
		PROJECT_NAME_ARGUMENT=${positional_arguments[0]}
	fi

	if ((${#positional_arguments[@]} == 2)); then
		FEATURE_BRANCH_ARGUMENT=${positional_arguments[1]}
	fi
}

# ---------- Interactive prompts ----------
prompt_project_name() {
	local response

	if [[ -n "$PROJECT_NAME_ARGUMENT" ]]; then
		PROJECT_NAME=$PROJECT_NAME_ARGUMENT
		return
	fi

	printf '\n%bProject configuration%b\n' "$BOLD$CYAN" "$RESET"
	printf 'Project name: '

	if ! IFS= read -r response; then
		print_error "Unable to read the project name."
		return 1
	fi

	if ! PROJECT_NAME=$(sanitize_single_line_input "$response"); then
		print_error "Unable to sanitize the project name."
		return 1
	fi
}

prompt_feature_branch() {
	local response

	if [[ -n "$FEATURE_BRANCH_ARGUMENT" ]]; then
		FEATURE_BRANCH=$FEATURE_BRANCH_ARGUMENT
		return
	fi

	printf 'Feature branch [optional]: '

	if ! IFS= read -r response; then
		FEATURE_BRANCH=""
		return
	fi

	if ! FEATURE_BRANCH=$(sanitize_single_line_input "$response"); then
		print_error "Unable to sanitize the feature branch."
		return 1
	fi
}

prompt_language() {
	local response

	if [[ -n "${LANGUAGE:-}" ]]; then
		if contains_control_characters "$LANGUAGE"; then
			print_error "LANGUAGE contains invalid control characters."
			return 1
		fi

		return
	fi

	printf 'Primary language [optional]: '

	if ! IFS= read -r response; then
		LANGUAGE=""
		return
	fi

	if ! LANGUAGE=$(sanitize_single_line_input "$response"); then
		print_error "Unable to sanitize the language value."
		return 1
	fi
}

prompt_remote_request() {
	local selection

	if [[ "$REMOTE_REQUEST" != "ask" ]]; then
		return
	fi

	printf '\n%bGitHub repository%b\n' "$BOLD$CYAN" "$RESET"
	printf 'Create and link a GitHub remote repository?\n\n'
	printf '  %b1)%b Yes - create the repository and configure origin\n' \
		"$BOLD" "$RESET"
	printf '  %b2)%b No  - keep this project local\n\n' \
		"$BOLD" "$RESET"

	while true; do
		printf 'Selection [1]: '

		if ! IFS= read -r selection; then
			print_error "Unable to read the remote repository selection."
			return 1
		fi

		if ! selection=$(sanitize_single_line_input "$selection"); then
			print_error "Unable to sanitize the remote repository selection."
			return 1
		fi

		selection=${selection,,}

		case "$selection" in
			"" | 1 | y | yes)
				REMOTE_REQUEST="yes"
				return
				;;
			2 | n | no)
				REMOTE_REQUEST="no"
				return
				;;
			*)
				printf '%bInvalid selection.%b Enter 1 or 2.\n' \
					"$RED" "$RESET" >&2
				;;
		esac
	done
}

prompt_repository_visibility() {
	local selection

	if [[ "$REMOTE_REQUEST" != "yes" ]]; then
		return
	fi

	if [[ "$REPOSITORY_VISIBILITY" != "ask" ]]; then
		return
	fi

	printf '\n%bRepository visibility%b\n' "$BOLD$CYAN" "$RESET"
	printf 'Select the access level for the GitHub repository.\n\n'
	printf '  %b1)%b Private - access is restricted to authorized users\n' \
		"$BOLD" "$RESET"
	printf '  %b2)%b Public  - visible to everyone\n\n' \
		"$BOLD" "$RESET"

	while true; do
		printf 'Selection [1]: '

		if ! IFS= read -r selection; then
			print_error "Unable to read the repository visibility selection."
			return 1
		fi

		if ! selection=$(sanitize_single_line_input "$selection"); then
			print_error "Unable to sanitize the visibility selection."
			return 1
		fi

		selection=${selection,,}

		case "$selection" in
			"" | 1 | private | priv)
				REPOSITORY_VISIBILITY="private"
				return
				;;
			2 | public | pub)
				REPOSITORY_VISIBILITY="public"
				return
				;;
			*)
				printf '%bInvalid selection.%b Enter 1 or 2.\n' \
					"$RED" "$RESET" >&2
				;;
		esac
	done
}

prompt_yes_no() {
	local message
	local default_answer
	local prompt_suffix
	local response

	message=$1
	default_answer=$2

	case "$default_answer" in
		y)
			prompt_suffix="[Y/n]"
			;;
		n)
			prompt_suffix="[y/N]"
			;;
		*)
			print_error "Invalid confirmation default: $default_answer"
			return 2
			;;
	esac

	while true; do
		printf '%s %s: ' "$message" "$prompt_suffix"

		if ! IFS= read -r response; then
			return 1
		fi

		if ! response=$(sanitize_single_line_input "$response"); then
			print_error "Unable to sanitize the confirmation response."
			return 2
		fi

		response=${response,,}

		if [[ -z "$response" ]]; then
			[[ "$default_answer" == "y" ]]
			return
		fi

		case "$response" in
			y | yes)
				return 0
				;;
			n | no)
				return 1
				;;
			*)
				printf '%bInvalid response.%b Enter y or n.\n' \
					"$RED" "$RESET" >&2
				;;
		esac
	done
}

# ---------- Project validation ----------
validate_project_name() {
	if [[ -z "$PROJECT_NAME" ]]; then
		print_error "Project name cannot be empty."
		return 1
	fi

	if ((${#PROJECT_NAME} > 100)); then
		print_error "Project name cannot exceed 100 characters."
		return 1
	fi

	if [[ ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		print_error "Invalid project name. Allowed characters: letters, numbers, '.', '-', and '_'."
		return 1
	fi

	if [[ "$PROJECT_NAME" == "." || "$PROJECT_NAME" == ".." ]]; then
		print_error "Project name cannot be '.' or '..'."
		return 1
	fi

	if [[ "$BASE_DIR" == "/" ]]; then
		PROJECT_PATH="/$PROJECT_NAME"
	else
		PROJECT_PATH="$BASE_DIR/$PROJECT_NAME"
	fi

	if [[ -e "$PROJECT_PATH" ]]; then
		print_error "The project path already exists: $PROJECT_PATH"
		return 1
	fi

	log_action "Validated project path: $PROJECT_PATH"
}

validate_feature_branch() {
	if [[ -z "$FEATURE_BRANCH" ]]; then
		return
	fi

	if contains_control_characters "$FEATURE_BRANCH"; then
		print_error "Feature branch contains invalid control characters."
		return 1
	fi

	if ((${#FEATURE_BRANCH} > 200)); then
		print_error "Feature branch cannot exceed 200 characters."
		return 1
	fi

	if ! git check-ref-format --branch "$FEATURE_BRANCH" >/dev/null 2>&1; then
		print_error "Invalid Git feature branch name: $FEATURE_BRANCH"
		return 1
	fi
}

validate_language() {
	if contains_control_characters "$LANGUAGE"; then
		print_error "Language contains invalid control characters."
		return 1
	fi

	if ((${#LANGUAGE} > 100)); then
		print_error "Language cannot exceed 100 characters."
		return 1
	fi
}

# ---------- Directory structure ----------
create_structure() {
	if ! run_cmd mkdir -p -- \
		"$PROJECT_PATH/src" \
		"$PROJECT_PATH/tests" \
		"$PROJECT_PATH/docs"
	then
		print_error "Unable to create the project directory structure."
		return 1
	fi

	if ((!DRY_RUN)); then
		LOCAL_PROJECT_CREATED=1
	fi

	if ! run_cmd touch -- \
		"$PROJECT_PATH/README.md" \
		"$PROJECT_PATH/.gitignore" \
		"$PROJECT_PATH/LICENSE" \
		"$PROJECT_PATH/docs/overview.md"
	then
		print_error "Unable to create the initial project files."
		return 1
	fi

	print_success "Created project directory structure."
	log_action "Created directory structure for $PROJECT_NAME"
}

# ---------- Git initialization ----------
initialize_git_repository() {
	if ((DRY_RUN)); then
		if ! run_cmd git -C "$PROJECT_PATH" init; then
			print_error "Unable to plan Git repository initialization."
			return 1
		fi

		print_success "Git repository initialization planned."
		return
	fi

	if [[ -d "$PROJECT_PATH/.git" ]]; then
		print_warning "Git repository already exists; initialization was skipped."
		return
	fi

	if ! run_cmd git -C "$PROJECT_PATH" init; then
		print_error "Unable to initialize the Git repository."
		return 1
	fi

	print_success "Git repository initialized."
	log_action "Initialized Git repository in $PROJECT_PATH"
}

# ---------- GitHub authentication ----------
check_github_authentication() {
	local login_requested

	if ! command -v gh >/dev/null 2>&1; then
		print_warning "GitHub CLI is not installed. Remote repository creation will be skipped."
		printf 'Install GitHub CLI: https://cli.github.com/\n'
		return 1
	fi

	if gh auth status >/dev/null 2>&1; then
		return
	fi

	print_warning "GitHub CLI is not authenticated."

	if ! prompt_yes_no "Authenticate with GitHub now?" "n"; then
		return 1
	fi

	login_requested=1

	if ((login_requested)) && ! gh auth login; then
		print_error "GitHub authentication failed."
		return 1
	fi

	if ! gh auth status >/dev/null 2>&1; then
		print_error "GitHub CLI authentication could not be verified."
		return 1
	fi
}

resolve_github_login() {
	local login

	if ! login=$(gh api user --jq '.login' 2>/dev/null); then
		GH_LOGIN=""
		return
	fi

	if [[ -z "$login" || ! "$login" =~ ^[a-zA-Z0-9-]+$ ]]; then
		GH_LOGIN=""
		return
	fi

	GH_LOGIN=$login
}

# ---------- Remote repository ----------
setup_remote_repository() {
	local visibility_option
	local existing_remote

	if [[ "$REMOTE_REQUEST" != "yes" ]]; then
		print_info "GitHub remote creation was not requested."
		log_action "Skipped GitHub remote creation for $PROJECT_NAME"
		return
	fi

	if [[ "$REPOSITORY_VISIBILITY" != "public" &&
	      "$REPOSITORY_VISIBILITY" != "private" ]]
	then
		print_error "Repository visibility was not resolved."
		return 1
	fi

	visibility_option="--$REPOSITORY_VISIBILITY"

	if ((DRY_RUN)); then
		if ! run_cmd gh repo create \
			"$PROJECT_NAME" \
			--source="$PROJECT_PATH" \
			"$visibility_option" \
			--remote=origin
		then
			print_error "Unable to plan GitHub repository creation."
			return 1
		fi

		REMOTE_CONFIGURED=1
		print_success "GitHub repository creation planned."
		return
	fi

	if existing_remote=$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null); then
		if [[ -z "$existing_remote" ]]; then
			print_error "Git returned an empty URL for the existing origin remote."
			return 1
		fi

		REMOTE_URL=$existing_remote
		REMOTE_CONFIGURED=1
		print_warning "Remote 'origin' already exists; GitHub repository creation was skipped."
		return
	fi

	if ! check_github_authentication; then
		print_info "GitHub remote setup was skipped. The local project remains available."
		log_action "Skipped GitHub remote setup because authentication was unavailable"
		return
	fi

	resolve_github_login

	if ! run_cmd gh repo create \
		"$PROJECT_NAME" \
		--source="$PROJECT_PATH" \
		"$visibility_option" \
		--remote=origin
	then
		print_error "Unable to create the GitHub repository."
		return 1
	fi

	REMOTE_CREATED=1
	REMOTE_CONFIGURED=1

	if [[ -n "$GH_LOGIN" ]]; then
		REMOTE_REPOSITORY="$GH_LOGIN/$PROJECT_NAME"
	else
		REMOTE_REPOSITORY=$PROJECT_NAME
	fi

	if ! REMOTE_URL=$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null); then
		print_error "The GitHub repository was created, but origin could not be verified."
		return 1
	fi

	if [[ -z "$REMOTE_URL" ]]; then
		print_error "The configured origin remote URL is empty."
		return 1
	fi

	print_success "GitHub repository created and linked as origin."
	printf '       Visibility: %s\n' "$REPOSITORY_VISIBILITY"
	printf '       Remote:     %s\n' "$REMOTE_URL"

	log_action "Created $REPOSITORY_VISIBILITY GitHub repository: $REMOTE_REPOSITORY"
}

# ---------- Initial commit ----------
create_initial_commit() {
	if ((DRY_RUN)); then
		if ! run_cmd git -C "$PROJECT_PATH" add --all; then
			print_error "Unable to plan Git staging."
			return 1
		fi

		if ! run_cmd git -C "$PROJECT_PATH" commit -m "initial commit"; then
			print_error "Unable to plan the initial commit."
			return 1
		fi

		if ! run_cmd git -C "$PROJECT_PATH" branch -M main; then
			print_error "Unable to plan the main branch rename."
			return 1
		fi

		if ((REMOTE_CONFIGURED)); then
			if ! run_cmd git -C "$PROJECT_PATH" push -u origin main; then
				print_error "Unable to plan the initial push."
				return 1
			fi
		fi

		print_success "Initial commit and main branch setup planned."
		return
	fi

	if git -C "$PROJECT_PATH" rev-parse --verify HEAD >/dev/null 2>&1; then
		print_warning "Repository already contains commits; initial commit was skipped."
		return
	fi

	if ! run_cmd git -C "$PROJECT_PATH" add --all; then
		print_error "Unable to stage the initial project files."
		return 1
	fi

	if ! run_cmd git -C "$PROJECT_PATH" commit -m "initial commit"; then
		print_error "Unable to create the initial Git commit."
		return 1
	fi

	if ! run_cmd git -C "$PROJECT_PATH" branch -M main; then
		print_error "Unable to rename the default branch to main."
		return 1
	fi

	print_success "Initial commit created on main."
	log_action "Created initial commit on main"

	if ! git -C "$PROJECT_PATH" remote get-url origin >/dev/null 2>&1; then
		print_info "No remote is configured. The initial commit remains local."
		return
	fi

	if ! run_cmd git -C "$PROJECT_PATH" push -u origin main; then
		print_error "Unable to push the initial commit to origin."
		return 1
	fi

	print_success "Initial commit pushed to origin/main."
	log_action "Pushed main branch to origin"
}

# ---------- Feature branch ----------
create_feature_branch() {
	if [[ -z "$FEATURE_BRANCH" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		if ! run_cmd git -C "$PROJECT_PATH" switch -c "$FEATURE_BRANCH"; then
			print_error "Unable to plan feature branch creation."
			return 1
		fi

		print_success "Feature branch creation planned: $FEATURE_BRANCH"
		return
	fi

	if git -C "$PROJECT_PATH" show-ref \
		--verify \
		--quiet \
		"refs/heads/$FEATURE_BRANCH"
	then
		if ! run_cmd git -C "$PROJECT_PATH" switch "$FEATURE_BRANCH"; then
			print_error "Unable to switch to feature branch: $FEATURE_BRANCH"
			return 1
		fi

		print_success "Switched to existing feature branch: $FEATURE_BRANCH"
	else
		if ! run_cmd git -C "$PROJECT_PATH" switch -c "$FEATURE_BRANCH"; then
			print_error "Unable to create feature branch: $FEATURE_BRANCH"
			return 1
		fi

		print_success "Created and switched to feature branch: $FEATURE_BRANCH"
	fi

	log_action "Switched to feature branch: $FEATURE_BRANCH"
}

# ---------- Summary ----------
print_summary() {
	printf '\n%bProject initialization complete%b\n' "$BOLD$CYAN" "$RESET"
	printf '%b-----------------------------------%b\n' "$DIM" "$RESET"
	printf '  %-12s %s\n' "Project:" "$PROJECT_NAME"
	printf '  %-12s %s\n' "Local path:" "$PROJECT_PATH"

	if [[ -n "$LANGUAGE" ]]; then
		printf '  %-12s %s\n' "Language:" "$LANGUAGE"
	fi

	if [[ "$REMOTE_REQUEST" == "yes" ]]; then
		printf '  %-12s %s\n' "Visibility:" "$REPOSITORY_VISIBILITY"

		if ((DRY_RUN)) && ((REMOTE_CONFIGURED)); then
			printf '  %-12s %s\n' "GitHub:" "repository creation planned"
		elif [[ -n "$REMOTE_URL" ]]; then
			printf '  %-12s %s\n' "GitHub:" "$REMOTE_URL"
		else
			printf '  %-12s %s\n' "GitHub:" "not configured"
		fi
	else
		printf '  %-12s %s\n' "GitHub:" "local project only"
	fi

	if [[ -n "$FEATURE_BRANCH" ]]; then
		printf '  %-12s %s\n' "Branch:" "$FEATURE_BRANCH"
	fi

	printf '\n%bNext steps%b\n' "$BOLD" "$RESET"
	printf '  cd %q\n' "$PROJECT_PATH"
	printf '  code .\n'

	if [[ -n "$FEATURE_BRANCH" && "$REMOTE_CONFIGURED" -eq 1 ]]; then
		printf '  git push -u origin %q\n' "$FEATURE_BRANCH"
	fi
}

# ---------- Directory navigation ----------
resolve_interactive_shell() {
	local shell_path

	shell_path=${SHELL:-}

	if [[ -n "$shell_path" && -x "$shell_path" ]]; then
		printf '%s' "$shell_path"
		return
	fi

	if ! shell_path=$(command -v bash); then
		print_error "Unable to locate an interactive shell."
		return 1
	fi

	if [[ -z "$shell_path" || ! -x "$shell_path" ]]; then
		print_error "The detected interactive shell is not executable."
		return 1
	fi

	printf '%s' "$shell_path"
}

auto_navigate_to_project() {
	local shell_path

	printf '\n'

	if ! prompt_yes_no "Auto-navigate to the new project directory?" "y"; then
		return
	fi

	if ((DRY_RUN)); then
		print_command cd "$PROJECT_PATH"
		print_info "An interactive shell would be opened in the project directory."
		return
	fi

	if ! cd -- "$PROJECT_PATH"; then
		print_error "Unable to enter the project directory: $PROJECT_PATH"
		return 1
	fi

	printf '\n%bOpened project directory:%b %s\n' \
		"$GREEN" "$RESET" "$PROJECT_PATH"

	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return
	fi

	if ! shell_path=$(resolve_interactive_shell); then
		return 1
	fi

	printf '%bStarting interactive shell...%b\n' "$DIM" "$RESET"

	if ! exec "$shell_path" -i; then
		print_error "Unable to start the interactive shell: $shell_path"
		return 1
	fi
}

# ---------- Main ----------
main() {
	local parse_status

	if parse_arguments "$@"; then
		:
	else
		parse_status=$?

		if ((parse_status == 2)); then
			return 0
		fi

		return 1
	fi

	if ! initialize_paths; then
		return 1
	fi

	if ! initialize_logging; then
		return 1
	fi

	if ! validate_dependencies; then
		return 1
	fi

	if ! prompt_project_name; then
		return 1
	fi

	if ! prompt_feature_branch; then
		return 1
	fi

	if ! prompt_language; then
		return 1
	fi

	if ! prompt_remote_request; then
		return 1
	fi

	if ! prompt_repository_visibility; then
		return 1
	fi

	if ! validate_project_name; then
		return 1
	fi

	if ! validate_feature_branch; then
		return 1
	fi

	if ! validate_language; then
		return 1
	fi

	if ! create_structure; then
		return 1
	fi

	if ! initialize_git_repository; then
		return 1
	fi

	if ! setup_remote_repository; then
		return 1
	fi

	if ! create_initial_commit; then
		return 1
	fi

	if ! create_feature_branch; then
		return 1
	fi

	if ! print_summary; then
		return 1
	fi

	log_action "Project created successfully: $PROJECT_NAME"
	PROJECT_COMPLETE=1
	trap - ERR

	if ! auto_navigate_to_project; then
		return 1
	fi
}

main "$@"