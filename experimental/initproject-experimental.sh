#!/usr/bin/env bash
# initproject-experimental.sh
# Production-oriented project bootstrapper for Git and GitHub.
#
# Usage:
#   initproject-experimental.sh [options] [project-name] [feature-branch]
#
# Environment variables:
#   PROJECT_NAME
#   FEATURE_BRANCH
#   BASE_DIR
#   PROJECT_DESCRIPTION
#   LANGUAGE
#   GITHUB_REMOTE
#   GITHUB_VISIBILITY
#   GITHUB_ORG
#   GITHUB_HOST
#   LICENSE_ID
#   INITIAL_BRANCH
#   CREATE_CI
#   SIGN_COMMIT
#   SECRET_SCAN
#   ADOPT_EXISTING
#   ADOPT_EXISTING_REMOTE
#   SHARED_REPOSITORY
#   TEMPLATE_SOURCE
#   POST_INIT
#   NON_INTERACTIVE
#   AUTO_NAVIGATE
#   OPEN_EDITOR
#   EDITOR_COMMAND
#   SEND_NOTIFICATION

set -Eeuo pipefail
set -o pipefail

umask 077

readonly SCRIPT_VERSION="0.1.0-experimental"
readonly PROGRAM_NAME="${0##*/}"
readonly MAX_LOG_BYTES=1048576
readonly NETWORK_ATTEMPTS=3

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

DRY_RUN=0
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
ASSUME_YES=0
SHOW_HELP=0
RUN_CANCELLED=0

BASE_DIR="${BASE_DIR:-$HOME/workspace/personal}"
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_PATH=""
PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-}"
FEATURE_BRANCH="${FEATURE_BRANCH:-}"
LANGUAGE="${LANGUAGE:-}"
INITIAL_BRANCH="${INITIAL_BRANCH:-}"
LICENSE_ID="${LICENSE_ID:-ask}"

REMOTE_REQUEST="${GITHUB_REMOTE:-ask}"
REPOSITORY_VISIBILITY="${GITHUB_VISIBILITY:-ask}"
GITHUB_ORG="${GITHUB_ORG:-}"
GITHUB_HOST="${GITHUB_HOST:-github.com}"
TARGET_OWNER=""
REPOSITORY_FULL_NAME=""
REMOTE_URL=""
REMOTE_ACTION="none"
REMOTE_CONFIGURED=0
REMOTE_CREATED=0
REMOTE_CREATION_CERTAIN=0
REMOTE_HAS_HISTORY=0
REMOTE_DEFAULT_BRANCH=""

CREATE_CI="${CREATE_CI:-ask}"
SIGN_COMMIT="${SIGN_COMMIT:-ask}"
SECRET_SCAN="${SECRET_SCAN:-auto}"
SHARED_REPOSITORY="${SHARED_REPOSITORY:-}"
ADOPT_EXISTING="${ADOPT_EXISTING:-ask}"
ADOPT_EXISTING_REMOTE="${ADOPT_EXISTING_REMOTE:-ask}"
ROLLBACK_MODE="ask"

TEMPLATE_SOURCE="${TEMPLATE_SOURCE:-}"
POST_INIT="${POST_INIT:-}"
CREATE_METADATA=1

AUTO_NAVIGATE="${AUTO_NAVIGATE:-ask}"
OPEN_EDITOR="${OPEN_EDITOR:-ask}"
EDITOR_COMMAND="${EDITOR_COMMAND:-}"
SEND_NOTIFICATION="${SEND_NOTIFICATION:-false}"

LOG_DIR=""
LOG_FILE=""
RUNTIME_DIR=""
LOCK_DIR=""
LOCK_ACQUIRED=0

PROJECT_DIRECTORY_CREATED=0
PROJECT_DIRECTORY_ADOPTED=0
PROJECT_COMPLETE=0
CLEANUP_COMPLETED=0

GIT_USER_NAME=""
GIT_USER_EMAIL=""
GIT_IDENTITY_PENDING=0
GIT_SIGNING_KEY=""

LAST_COMMAND_DISPLAY=""
LAST_COMMAND_OUTPUT=""
LAST_COMMAND_STATUS=0

PROMPT_RESULT=""
FAILURE_CONTEXT=""
BASH_PATH=""

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

print_failure() {
	local message
	message=$1

	printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$message" >&2
}

print_section() {
	local title
	title=$1

	printf "\n%b%s%b\n" "$BOLD$CYAN" "$title" "$RESET"
	printf "%b----------------------------------------%b\n" "$DIM" "$RESET"
}

print_help() {
	printf '%s\n' \
		"$PROGRAM_NAME $SCRIPT_VERSION" \
		'Bootstrap a local Git project and optionally create or connect a GitHub repository.' \
		'' \
		'Usage:' \
		"  $PROGRAM_NAME [options] [project-name] [feature-branch]" \
		'' \
		'Core options:' \
		'  --name <name>' \
		'      Set the project name.' \
		'' \
		'  --base-dir <path>' \
		'      Set the parent directory for the project.' \
		'' \
		'  --feature-branch <name>' \
		'      Create and switch to a feature branch after initialization.' \
		'' \
		'  --initial-branch <name>' \
		'      Set the initial branch. Defaults to init.defaultBranch or main.' \
		'' \
		'  --description <text>' \
		'      Set the README and GitHub repository description.' \
		'' \
		'GitHub options:' \
		'  --remote' \
		'      Create or connect a GitHub repository.' \
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
		'  --org <organization>' \
		'      Create the repository under a GitHub organization.' \
		'' \
		'  --github-host <hostname>' \
		'      Select a GitHub host. Default: github.com' \
		'' \
		'  --adopt-existing-remote' \
		'      Connect to an existing repository with the same owner and name.' \
		'' \
		'Project generation:' \
		'  --language <name>' \
		'      Generate a language-aware .gitignore and CI workflow.' \
		'' \
		'  --license <id>' \
		'      License: none, mit, apache-2.0, or gpl-3.0.' \
		'' \
		'  --ci, --no-ci' \
		'      Enable or disable GitHub Actions workflow generation.' \
		'' \
		'  --template <path-or-url>' \
		'      Apply a local directory or Git repository as a project template.' \
		'' \
		'  --post-init <script>' \
		'      Run a Bash hook inside the project before the initial commit.' \
		'' \
		'  --no-metadata' \
		'      Do not create .project.json.' \
		'' \
		'Git and security:' \
		'  --sign, --no-sign' \
		'      Enable or disable signing of the initial commit.' \
		'' \
		'  --secret-scan, --no-secret-scan' \
		'      Require or disable a gitleaks/git-secrets scan.' \
		'' \
		'  --shared-repository <mode>' \
		'      Configure core.sharedRepository.' \
		'' \
		'Reliability:' \
		'  --adopt-existing' \
		'      Permit use of an existing project directory.' \
		'' \
		'  --rollback-on-failure' \
		'      Automatically remove resources created by a failed run.' \
		'' \
		'  --preserve-on-failure' \
		'      Never remove created resources after a failure.' \
		'' \
		'  --dry-run' \
		'      Validate configuration and display the planned operations.' \
		'' \
		'Automation and completion:' \
		'  --non-interactive, --yes' \
		'      Disable prompts and use supplied values or safe defaults.' \
		'' \
		'  --open-editor, --no-open-editor' \
		'      Enable or disable opening the completed project in an editor.' \
		'' \
		'  --editor <command>' \
		'      Select the editor command.' \
		'' \
		'  --navigate, --no-navigate' \
		'      Enable or disable opening an interactive shell in the project.' \
		'' \
		'  --notify, --no-notify' \
		'      Enable or disable a desktop completion notification.' \
		'' \
		'  -h, --help' \
		'      Display this help.' \
		'' \
		'Examples:' \
		"  $PROGRAM_NAME --private example-api feature/auth" \
		"  $PROGRAM_NAME --public --language python --ci example-cli" \
		"  $PROGRAM_NAME --no-remote --license mit local-tool" \
		"  $PROGRAM_NAME --non-interactive --private --name service-api" \
		"  PROJECT_NAME=widget GITHUB_REMOTE=true GITHUB_VISIBILITY=private $PROGRAM_NAME --non-interactive"
}

contains_control_characters() {
	local value
	value=$1

	[[ "$value" == *$'\r'* ||
		"$value" == *$'\n'* ||
		"$value" == *$'\t'* ]]
}

sanitize_single_line() {
	local value
	value=$1
	value=${value//$'\r'/}
	value=${value//$'\n'/ }
	value=${value//$'\t'/ }

	printf '%s' "$value"
}

normalize_boolean() {
	local value
	value=${1,,}

	case "$value" in
	1 | true | yes | y | on)
		printf 'true'
		;;
	0 | false | no | n | off)
		printf 'false'
		;;
	ask | auto)
		printf '%s' "$value"
		;;
	*)
		return 1
		;;
	esac
}

normalize_visibility() {
	local value
	value=${1,,}

	case "$value" in
	public | pub)
		printf 'public'
		;;
	private | priv)
		printf 'private'
		;;
	ask | "")
		printf 'ask'
		;;
	*)
		return 1
		;;
	esac
}

normalize_license() {
	local value
	value=${1,,}

	case "$value" in
	"" | ask)
		printf 'ask'
		;;
	none | no)
		printf 'none'
		;;
	mit)
		printf 'mit'
		;;
	apache | apache-2 | apache-2.0)
		printf 'apache-2.0'
		;;
	gpl | gpl-3 | gpl-3.0 | gpl-3.0-only)
		printf 'gpl-3.0'
		;;
	*)
		return 1
		;;
	esac
}

validate_hostname() {
	local hostname
	hostname=$1

	[[ "$hostname" =~ ^[A-Za-z0-9.-]+$ &&
		"$hostname" != .* &&
		"$hostname" != *. &&
		"$hostname" != *..* ]]
}

validate_repository_owner() {
	local owner
	owner=$1

	[[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ &&
		"$owner" != *- ]]
}

validate_email() {
	local email
	email=$1

	[[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

format_command() {
	local argument
	local formatted
	formatted=""

	for argument in "$@"; do
		printf -v argument '%q' "$argument"
		formatted+="${formatted:+ }$argument"
	done

	printf '%s' "$formatted"
}

print_dry_run_command() {
	local command_display

	if ! command_display=$(format_command "$@"); then
		print_error "Unable to format a dry-run command."
		return 1
	fi

	printf "%b[DRY RUN]%b %s\n" "$DIM" "$RESET" "$command_display"
}

capture_command() {
	local output
	local command_display
	local status

	if ! command_display=$(format_command "$@"); then
		print_error "Unable to format command."
		return 1
	fi

	LAST_COMMAND_DISPLAY=$command_display
	LAST_COMMAND_OUTPUT=""
	LAST_COMMAND_STATUS=0

	if output=$("$@" 2>&1); then
		LAST_COMMAND_OUTPUT=$output
		return
	fi

	status=$?
	LAST_COMMAND_OUTPUT=$output
	LAST_COMMAND_STATUS=$status
	return "$status"
}

report_last_command_failure() {
	local context
	context=$1

	print_failure "$context"
	printf "       Command: %s\n" "$LAST_COMMAND_DISPLAY" >&2
	printf "       Exit:    %d\n" "$LAST_COMMAND_STATUS" >&2

	if [[ -n "${LAST_COMMAND_OUTPUT//[[:space:]]/}" ]]; then
		printf "       Output:\n" >&2
		while IFS= read -r line; do
			printf "         %s\n" "$line" >&2
		done <<<"$LAST_COMMAND_OUTPUT"
	fi
}

run_checked() {
	local context
	context=$1
	shift

	if ((DRY_RUN)); then
		print_dry_run_command "$@"
		return
	fi

	if ! capture_command "$@"; then
		report_last_command_failure "$context"
		return "$LAST_COMMAND_STATUS"
	fi
}

run_streaming_checked() {
	local context
	local command_display
	local status

	context=$1
	shift

	if ((DRY_RUN)); then
		print_dry_run_command "$@"
		return
	fi

	if ! command_display=$(format_command "$@"); then
		print_error "Unable to format command."
		return 1
	fi

	if "$@"; then
		return
	fi

	status=$?
	print_failure "$context"
	printf "       Command: %s\n" "$command_display" >&2
	printf "       Exit:    %d\n" "$status" >&2
	return "$status"
}

run_captured_with_spinner() {
	local label
	local output_file
	local command_display
	local spinner
	local frame
	local command_pid
	local status
	local output

	label=$1
	shift

	if ((DRY_RUN)); then
		print_dry_run_command "$@"
		LAST_COMMAND_OUTPUT=""
		LAST_COMMAND_STATUS=0
		return
	fi

	if ! command_display=$(format_command "$@"); then
		print_error "Unable to format command."
		return 1
	fi

	output_file="$RUNTIME_DIR/command-output.$RANDOM.$RANDOM"

	LAST_COMMAND_DISPLAY=$command_display
	LAST_COMMAND_OUTPUT=""
	LAST_COMMAND_STATUS=0

	"$@" >"$output_file" 2>&1 &
	command_pid=$!

	if [[ -t 1 ]]; then
		spinner=$'|/-\\'
		frame=0

		while kill -0 "$command_pid" 2>/dev/null; do
			printf "\r%b[%c]%b %s" \
				"$CYAN" "${spinner:frame++%4:1}" "$RESET" "$label"
			sleep 0.1
		done

		printf "\r\033[K"
	fi

	if wait "$command_pid"; then
		status=0
	else
		status=$?
	fi

	if [[ -r "$output_file" ]]; then
		if ! output=$(<"$output_file"); then
			output=""
		fi
	else
		output=""
	fi

	rm -f -- "$output_file"

	LAST_COMMAND_OUTPUT=$output
	LAST_COMMAND_STATUS=$status

	if ((status != 0)); then
		return "$status"
	fi
}

run_network_command() {
	local label
	local attempt
	local delay

	label=$1
	shift

	if ((DRY_RUN)); then
		print_dry_run_command "$@"
		return
	fi

	attempt=1
	delay=1

	while ((attempt <= NETWORK_ATTEMPTS)); do
		if run_captured_with_spinner \
			"$label (attempt $attempt/$NETWORK_ATTEMPTS)" \
			"$@"; then
			return
		fi

		if ((attempt == NETWORK_ATTEMPTS)); then
			report_last_command_failure "$label failed after $NETWORK_ATTEMPTS attempts."
			return "$LAST_COMMAND_STATUS"
		fi

		print_warning "$label failed; retrying in ${delay}s."
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
}

initialize_environment_values() {
	local normalized

	if ! normalized=$(normalize_boolean "$NON_INTERACTIVE"); then
		print_error "Invalid NON_INTERACTIVE value: $NON_INTERACTIVE"
		return 1
	fi
	NON_INTERACTIVE=$normalized

	if ! normalized=$(normalize_boolean "$REMOTE_REQUEST"); then
		print_error "Invalid GITHUB_REMOTE value: $REMOTE_REQUEST"
		return 1
	fi
	REMOTE_REQUEST=$normalized

	if ! normalized=$(normalize_visibility "$REPOSITORY_VISIBILITY"); then
		print_error "Invalid GITHUB_VISIBILITY value: $REPOSITORY_VISIBILITY"
		return 1
	fi
	REPOSITORY_VISIBILITY=$normalized

	if ! normalized=$(normalize_license "$LICENSE_ID"); then
		print_error "Invalid LICENSE_ID value: $LICENSE_ID"
		return 1
	fi
	LICENSE_ID=$normalized

	if ! normalized=$(normalize_boolean "$CREATE_CI"); then
		print_error "Invalid CREATE_CI value: $CREATE_CI"
		return 1
	fi
	CREATE_CI=$normalized

	if ! normalized=$(normalize_boolean "$SIGN_COMMIT"); then
		print_error "Invalid SIGN_COMMIT value: $SIGN_COMMIT"
		return 1
	fi
	SIGN_COMMIT=$normalized

	if ! normalized=$(normalize_boolean "$ADOPT_EXISTING"); then
		print_error "Invalid ADOPT_EXISTING value: $ADOPT_EXISTING"
		return 1
	fi
	ADOPT_EXISTING=$normalized

	if ! normalized=$(normalize_boolean "$ADOPT_EXISTING_REMOTE"); then
		print_error "Invalid ADOPT_EXISTING_REMOTE value: $ADOPT_EXISTING_REMOTE"
		return 1
	fi
	ADOPT_EXISTING_REMOTE=$normalized

	if ! normalized=$(normalize_boolean "$AUTO_NAVIGATE"); then
		print_error "Invalid AUTO_NAVIGATE value: $AUTO_NAVIGATE"
		return 1
	fi
	AUTO_NAVIGATE=$normalized

	if ! normalized=$(normalize_boolean "$OPEN_EDITOR"); then
		print_error "Invalid OPEN_EDITOR value: $OPEN_EDITOR"
		return 1
	fi
	OPEN_EDITOR=$normalized

	if ! normalized=$(normalize_boolean "$SEND_NOTIFICATION"); then
		print_error "Invalid SEND_NOTIFICATION value: $SEND_NOTIFICATION"
		return 1
	fi
	SEND_NOTIFICATION=$normalized

	SECRET_SCAN=${SECRET_SCAN,,}

	case "$SECRET_SCAN" in
	true | false | auto) ;;
	1 | yes | y | on)
		SECRET_SCAN="true"
		;;
	0 | no | n | off)
		SECRET_SCAN="false"
		;;
	*)
		print_error "Invalid SECRET_SCAN value: $SECRET_SCAN"
		return 1
		;;
	esac
}

set_remote_request() {
	local value
	value=$1

	if [[ "$value" != "true" && "$value" != "false" ]]; then
		print_error "Invalid remote request state: $value"
		return 1
	fi

	if [[ "$REMOTE_REQUEST" != "ask" &&
		"$REMOTE_REQUEST" != "$value" ]]; then
		print_error "Conflicting remote creation options were provided."
		return 1
	fi

	if [[ "$value" == "false" &&
		"$REPOSITORY_VISIBILITY" != "ask" ]]; then
		print_error "--no-remote cannot be combined with repository visibility."
		return 1
	fi

	REMOTE_REQUEST=$value
}

set_repository_visibility() {
	local value
	value=$1

	if [[ "$value" != "public" && "$value" != "private" ]]; then
		print_error "Invalid repository visibility: $value"
		return 1
	fi

	if [[ "$REMOTE_REQUEST" == "false" ]]; then
		print_error "Repository visibility cannot be combined with --no-remote."
		return 1
	fi

	if [[ "$REPOSITORY_VISIBILITY" != "ask" &&
		"$REPOSITORY_VISIBILITY" != "$value" ]]; then
		print_error "Conflicting repository visibility options were provided."
		return 1
	fi

	REPOSITORY_VISIBILITY=$value
	REMOTE_REQUEST="true"
}

require_option_value() {
	local option
	local remaining

	option=$1
	remaining=$2

	if ((remaining == 0)); then
		print_error "$option requires a value."
		return 1
	fi
}

parse_arguments() {
	local argument
	local normalized
	local -a positional_arguments

	positional_arguments=()

	while (($# > 0)); do
		argument=$1

		case "$argument" in
		--name)
			shift
			require_option_value "--name" "$#" || return 1
			PROJECT_NAME=$1
			;;
		--name=*)
			PROJECT_NAME=${argument#*=}
			;;
		--base-dir)
			shift
			require_option_value "--base-dir" "$#" || return 1
			BASE_DIR=$1
			;;
		--base-dir=*)
			BASE_DIR=${argument#*=}
			;;
		--feature-branch)
			shift
			require_option_value "--feature-branch" "$#" || return 1
			FEATURE_BRANCH=$1
			;;
		--feature-branch=*)
			FEATURE_BRANCH=${argument#*=}
			;;
		--initial-branch)
			shift
			require_option_value "--initial-branch" "$#" || return 1
			INITIAL_BRANCH=$1
			;;
		--initial-branch=*)
			INITIAL_BRANCH=${argument#*=}
			;;
		--description)
			shift
			require_option_value "--description" "$#" || return 1
			PROJECT_DESCRIPTION=$1
			;;
		--description=*)
			PROJECT_DESCRIPTION=${argument#*=}
			;;
		--language)
			shift
			require_option_value "--language" "$#" || return 1
			LANGUAGE=$1
			;;
		--language=*)
			LANGUAGE=${argument#*=}
			;;
		--license)
			shift
			require_option_value "--license" "$#" || return 1
			if ! normalized=$(normalize_license "$1"); then
				print_error "Unsupported license: $1"
				return 1
			fi
			LICENSE_ID=$normalized
			;;
		--license=*)
			if ! normalized=$(normalize_license "${argument#*=}"); then
				print_error "Unsupported license: ${argument#*=}"
				return 1
			fi
			LICENSE_ID=$normalized
			;;
		--remote)
			set_remote_request "true" || return 1
			;;
		--no-remote | --local-only)
			set_remote_request "false" || return 1
			;;
		--pub | --public | --pubic)
			set_repository_visibility "public" || return 1
			;;
		--priv | --private)
			set_repository_visibility "private" || return 1
			;;
		--org)
			shift
			require_option_value "--org" "$#" || return 1
			GITHUB_ORG=$1
			REMOTE_REQUEST="true"
			;;
		--org=*)
			GITHUB_ORG=${argument#*=}
			REMOTE_REQUEST="true"
			;;
		--github-host)
			shift
			require_option_value "--github-host" "$#" || return 1
			GITHUB_HOST=$1
			;;
		--github-host=*)
			GITHUB_HOST=${argument#*=}
			;;
		--ci)
			CREATE_CI="true"
			;;
		--no-ci)
			CREATE_CI="false"
			;;
		--sign)
			SIGN_COMMIT="true"
			;;
		--no-sign)
			SIGN_COMMIT="false"
			;;
		--secret-scan)
			SECRET_SCAN="true"
			;;
		--no-secret-scan)
			SECRET_SCAN="false"
			;;
		--shared-repository)
			shift
			require_option_value "--shared-repository" "$#" || return 1
			SHARED_REPOSITORY=$1
			;;
		--shared-repository=*)
			SHARED_REPOSITORY=${argument#*=}
			;;
		--adopt-existing)
			ADOPT_EXISTING="true"
			;;
		--adopt-existing-remote)
			ADOPT_EXISTING_REMOTE="true"
			REMOTE_REQUEST="true"
			;;
		--template)
			shift
			require_option_value "--template" "$#" || return 1
			TEMPLATE_SOURCE=$1
			;;
		--template=*)
			TEMPLATE_SOURCE=${argument#*=}
			;;
		--post-init)
			shift
			require_option_value "--post-init" "$#" || return 1
			POST_INIT=$1
			;;
		--post-init=*)
			POST_INIT=${argument#*=}
			;;
		--no-metadata)
			CREATE_METADATA=0
			;;
		--rollback-on-failure)
			ROLLBACK_MODE="true"
			;;
		--preserve-on-failure)
			ROLLBACK_MODE="false"
			;;
		--open-editor)
			OPEN_EDITOR="true"
			;;
		--no-open-editor)
			OPEN_EDITOR="false"
			;;
		--editor)
			shift
			require_option_value "--editor" "$#" || return 1
			EDITOR_COMMAND=$1
			OPEN_EDITOR="true"
			;;
		--editor=*)
			EDITOR_COMMAND=${argument#*=}
			OPEN_EDITOR="true"
			;;
		--navigate)
			AUTO_NAVIGATE="true"
			;;
		--no-navigate)
			AUTO_NAVIGATE="false"
			;;
		--notify)
			SEND_NOTIFICATION="true"
			;;
		--no-notify)
			SEND_NOTIFICATION="false"
			;;
		--dry-run)
			DRY_RUN=1
			;;
		--non-interactive | --yes)
			NON_INTERACTIVE="true"
			ASSUME_YES=1
			;;
		-h | --help)
			SHOW_HELP=1
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
		if [[ -n "$PROJECT_NAME" &&
			"$PROJECT_NAME" != "${positional_arguments[0]}" ]]; then
			print_error "Project name was provided more than once with different values."
			return 1
		fi

		PROJECT_NAME=${positional_arguments[0]}
	fi

	if ((${#positional_arguments[@]} == 2)); then
		if [[ -n "$FEATURE_BRANCH" &&
			"$FEATURE_BRANCH" != "${positional_arguments[1]}" ]]; then
			print_error "Feature branch was provided more than once with different values."
			return 1
		fi

		FEATURE_BRANCH=${positional_arguments[1]}
	fi
}

validate_dependencies() {
	local command_name
	local -a required_commands
	local -a missing_commands

	required_commands=(
		awk
		bash
		cksum
		date
		find
		git
		grep
		head
		mkdir
		mktemp
		mv
		pwd
		rm
		sed
		sleep
		tar
		touch
		tr
		wc
	)

	missing_commands=()

	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing_commands+=("$command_name")
		fi
	done

	if ((${#missing_commands[@]} > 0)); then
		printf "%b[ERROR]%b Missing required command(s): %s\n" \
			"$RED" "$RESET" "${missing_commands[*]}" >&2
		return 1
	fi

	if ! BASH_PATH=$(command -v bash); then
		print_error "Unable to locate Bash."
		return 1
	fi

	if [[ -z "$BASH_PATH" ||
		! -x "$BASH_PATH" ]] ||
		contains_control_characters "$BASH_PATH"; then
		print_error "The detected Bash executable is unsafe or unavailable."
		return 1
	fi
}

expand_home_path() {
	local value
	value=$1

	case "$value" in
	"~")
		printf '%s' "$HOME"
		;;
	"$HOME"*)
		printf '%s/%s' "$HOME" "${value#~/}"
		;;
	*)
		printf '%s' "$value"
		;;
	esac
}

normalize_absolute_path() {
	local value
	local component
	local -a components
	local -a resolved

	value=$1

	if [[ "$value" != /* ]]; then
		value="$PWD/$value"
	fi

	IFS='/' read -r -a components <<<"${value#/}"
	resolved=()

	for component in "${components[@]}"; do
		case "$component" in
		"" | ".") ;;
		"..")
			if ((${#resolved[@]} > 0)); then
				unset 'resolved[${#resolved[@]}-1]'
			fi
			;;
		*)
			resolved+=("$component")
			;;
		esac
	done

	if ((${#resolved[@]} == 0)); then
		printf '/'
		return
	fi

	printf '/%s' "${resolved[0]}"

	for component in "${resolved[@]:1}"; do
		printf '/%s' "$component"
	done
}

find_existing_parent() {
	local path

	path=$1

	while [[ ! -e "$path" ]]; do
		if [[ "$path" == "/" ]]; then
			break
		fi

		path=${path%/*}

		if [[ -z "$path" ]]; then
			path="/"
		fi
	done

	printf '%s' "$path"
}

prepare_base_directory() {
	local expanded
	local absolute
	local physical
	local existing_parent
	local write_test

	if [[ -z "${HOME:-}" ]]; then
		print_error "HOME is not defined."
		return 1
	fi

	if contains_control_characters "$BASE_DIR"; then
		print_error "BASE_DIR contains invalid control characters."
		return 1
	fi

	if ! expanded=$(expand_home_path "$BASE_DIR"); then
		print_error "Unable to expand BASE_DIR."
		return 1
	fi

	if ! absolute=$(normalize_absolute_path "$expanded"); then
		print_error "Unable to resolve BASE_DIR."
		return 1
	fi

	if ((DRY_RUN)); then
		if [[ -e "$absolute" && ! -d "$absolute" ]]; then
			print_error "BASE_DIR exists but is not a directory: $absolute"
			return 1
		fi

		if [[ -d "$absolute" ]]; then
			if [[ ! -w "$absolute" || ! -x "$absolute" ]]; then
				print_error "BASE_DIR is not writable and searchable: $absolute"
				return 1
			fi
		else
			if ! existing_parent=$(find_existing_parent "$absolute"); then
				print_error "Unable to identify an existing parent for BASE_DIR."
				return 1
			fi

			if [[ ! -d "$existing_parent" ||
				! -w "$existing_parent" ||
				! -x "$existing_parent" ]]; then
				print_error "The nearest existing BASE_DIR parent is not writable: $existing_parent"
				return 1
			fi
		fi

		BASE_DIR=$absolute
		return
	fi

	if ! mkdir -p -- "$absolute"; then
		print_error "Unable to create BASE_DIR: $absolute"
		return 1
	fi

	if [[ ! -d "$absolute" ||
		! -w "$absolute" ||
		! -x "$absolute" ]]; then
		print_error "BASE_DIR is not writable and searchable: $absolute"
		return 1
	fi

	if ! physical=$(cd -- "$absolute" && pwd -P); then
		print_error "Unable to resolve the physical BASE_DIR path."
		return 1
	fi

	if [[ -z "$physical" ]] || contains_control_characters "$physical"; then
		print_error "The resolved BASE_DIR path is invalid."
		return 1
	fi

	BASE_DIR=$physical

	if ! write_test=$(mktemp -d "$BASE_DIR/.initproject-write-test.XXXXXXXX"); then
		print_error "BASE_DIR failed an actual write test: $BASE_DIR"
		return 1
	fi

	if ! rm -rf -- "$write_test"; then
		print_error "Unable to remove the BASE_DIR write-test directory."
		return 1
	fi
}

initialize_logging() {
	local data_root

	data_root=${XDG_DATA_HOME:-"$HOME/.local/share"}

	if contains_control_characters "$data_root"; then
		print_error "The configured data directory is invalid."
		return 1
	fi

	LOG_DIR="$data_root/bashscripts"
	LOG_FILE="$LOG_DIR/initproject-experimental.log"

	if ! mkdir -p -- "$LOG_DIR"; then
		print_error "Unable to create log directory: $LOG_DIR"
		return 1
	fi

	if ! chmod 700 -- "$LOG_DIR"; then
		print_error "Unable to secure log directory permissions: $LOG_DIR"
		return 1
	fi

	if ! rotate_log_if_needed; then
		return 1
	fi

	if ! touch -- "$LOG_FILE"; then
		print_error "Unable to create log file: $LOG_FILE"
		return 1
	fi

	if ! chmod 600 -- "$LOG_FILE"; then
		print_error "Unable to secure log file permissions."
		return 1
	fi
}

rotate_log_if_needed() {
	local bytes

	if [[ ! -e "$LOG_FILE" ]]; then
		return
	fi

	if ! bytes=$(wc -c <"$LOG_FILE"); then
		print_error "Unable to inspect log file size."
		return 1
	fi

	bytes=${bytes//[[:space:]]/}

	if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
		print_error "The log file size could not be validated."
		return 1
	fi

	if ((bytes <= MAX_LOG_BYTES)); then
		return
	fi

	rm -f -- "$LOG_FILE.3"

	if [[ -e "$LOG_FILE.2" ]]; then
		mv -- "$LOG_FILE.2" "$LOG_FILE.3"
	fi

	if [[ -e "$LOG_FILE.1" ]]; then
		mv -- "$LOG_FILE.1" "$LOG_FILE.2"
	fi

	mv -- "$LOG_FILE" "$LOG_FILE.1"
}

log_action() {
	local message
	local timestamp

	message=$1

	if [[ -z "$LOG_FILE" ]]; then
		return
	fi

	if ! timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); then
		timestamp="timestamp-unavailable"
	fi

	if ! printf '[%s] %s\n' "$timestamp" "$message" >>"$LOG_FILE"; then
		print_warning "Unable to write to the log file."
	fi
}

create_runtime_directory() {
	if ! RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/initproject.XXXXXXXX"); then
		print_error "Unable to create a secure runtime directory."
		return 1
	fi

	if [[ -z "$RUNTIME_DIR" ||
		! -d "$RUNTIME_DIR" ]]; then
		print_error "The runtime directory is invalid."
		return 1
	fi

	if ! chmod 700 -- "$RUNTIME_DIR"; then
		print_error "Unable to secure the runtime directory."
		return 1
	fi
}

prompt_line() {
	local prompt
	local default_value
	local response

	prompt=$1
	default_value=${2:-}

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		PROMPT_RESULT=$default_value
		return
	fi

	if [[ ! -t 0 ]]; then
		print_error "Interactive input is required, but stdin is not a terminal."
		return 1
	fi

	if [[ -n "$default_value" ]]; then
		printf '%s [%s]: ' "$prompt" "$default_value"
	else
		printf '%s: ' "$prompt"
	fi

	if ! IFS= read -r response; then
		print_error "Unable to read interactive input."
		return 1
	fi

	if ! response=$(sanitize_single_line "$response"); then
		print_error "Unable to sanitize interactive input."
		return 1
	fi

	PROMPT_RESULT=${response:-$default_value}
}

prompt_yes_no() {
	local message
	local default_answer
	local suffix
	local response

	message=$1
	default_answer=$2

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		[[ "$default_answer" == "y" ]]
		return
	fi

	case "$default_answer" in
	y)
		suffix="[Y/n]"
		;;
	n)
		suffix="[y/N]"
		;;
	*)
		print_error "Invalid confirmation default: $default_answer"
		return 2
		;;
	esac

	while true; do
		printf '%s %s: ' "$message" "$suffix"

		if ! IFS= read -r response; then
			return 1
		fi

		if ! response=$(sanitize_single_line "$response"); then
			print_error "Unable to sanitize confirmation response."
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
			printf "%bInvalid response.%b Enter y or n.\n" \
				"$RED" "$RESET" >&2
			;;
		esac
	done
}

collect_project_name() {
	if [[ -n "$PROJECT_NAME" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		print_error "PROJECT_NAME or --name is required in non-interactive mode."
		return 1
	fi

	print_section "Project configuration"

	prompt_line "Project name" || return 1
	PROJECT_NAME=$PROMPT_RESULT
}

collect_optional_project_values() {
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		return
	fi

	if [[ -z "$FEATURE_BRANCH" ]]; then
		prompt_line "Feature branch, optional" || return 1
		FEATURE_BRANCH=$PROMPT_RESULT
	fi

	if [[ -z "$LANGUAGE" ]]; then
		prompt_line "Primary language, optional" || return 1
		LANGUAGE=$PROMPT_RESULT
	fi

	if [[ -z "$PROJECT_DESCRIPTION" ]]; then
		prompt_line "Project description, optional" || return 1
		PROJECT_DESCRIPTION=$PROMPT_RESULT
	fi
}

collect_remote_request() {
	local selection

	if [[ "$REMOTE_REQUEST" != "ask" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		REMOTE_REQUEST="false"
		return
	fi

	print_section "GitHub repository"
	printf '%s\n\n' \
		'Choose whether this project should be connected to GitHub.' \
		"  ${BOLD}1)${RESET} Create or connect a GitHub repository" \
		"  ${BOLD}2)${RESET} Keep the project local"

	while true; do
		prompt_line "Selection" "1" || return 1
		selection=${PROMPT_RESULT,,}

		case "$selection" in
		1 | y | yes)
			REMOTE_REQUEST="true"
			return
			;;
		2 | n | no)
			REMOTE_REQUEST="false"
			return
			;;
		*)
			print_warning "Enter 1 or 2."
			;;
		esac
	done
}

collect_visibility() {
	local selection

	if [[ "$REMOTE_REQUEST" != "true" ||
		"$REPOSITORY_VISIBILITY" != "ask" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		REPOSITORY_VISIBILITY="private"
		return
	fi

	print_section "Repository visibility"
	printf '%s\n\n' \
		'Select the GitHub repository access level.' \
		"  ${BOLD}1)${RESET} Private - restricted to authorized users" \
		"  ${BOLD}2)${RESET} Public  - visible to everyone"

	while true; do
		prompt_line "Selection" "1" || return 1
		selection=${PROMPT_RESULT,,}

		case "$selection" in
		1 | private | priv)
			REPOSITORY_VISIBILITY="private"
			return
			;;
		2 | public | pub)
			REPOSITORY_VISIBILITY="public"
			return
			;;
		*)
			print_warning "Enter 1 or 2."
			;;
		esac
	done
}

collect_license() {
	local selection

	if [[ "$LICENSE_ID" != "ask" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		LICENSE_ID="none"
		return
	fi

	print_section "License"
	printf '%s\n\n' \
		'Select a license for the generated repository.' \
		"  ${BOLD}1)${RESET} None" \
		"  ${BOLD}2)${RESET} MIT" \
		"  ${BOLD}3)${RESET} Apache License 2.0" \
		"  ${BOLD}4)${RESET} GNU GPL 3.0"

	while true; do
		prompt_line "Selection" "1" || return 1
		selection=${PROMPT_RESULT,,}

		case "$selection" in
		1 | none)
			LICENSE_ID="none"
			return
			;;
		2 | mit)
			LICENSE_ID="mit"
			return
			;;
		3 | apache | apache-2.0)
			LICENSE_ID="apache-2.0"
			return
			;;
		4 | gpl | gpl-3.0)
			LICENSE_ID="gpl-3.0"
			return
			;;
		*)
			print_warning "Enter a number from 1 through 4."
			;;
		esac
	done
}

collect_ci_request() {
	if [[ "$CREATE_CI" != "ask" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		CREATE_CI="false"
		return
	fi

	if prompt_yes_no "Generate a GitHub Actions CI workflow?" "n"; then
		CREATE_CI="true"
	else
		CREATE_CI="false"
	fi
}

resolve_initial_branch() {
	local configured_branch

	if [[ -n "$INITIAL_BRANCH" ]]; then
		return
	fi

	if configured_branch=$(git config --get init.defaultBranch 2>/dev/null); then
		if [[ -n "${configured_branch//[[:space:]]/}" ]]; then
			INITIAL_BRANCH=$configured_branch
		fi
	fi

	INITIAL_BRANCH=${INITIAL_BRANCH:-main}
}

validate_project_configuration() {
	if [[ -z "$PROJECT_NAME" ]]; then
		print_error "Project name cannot be empty."
		return 1
	fi

	if contains_control_characters "$PROJECT_NAME"; then
		print_error "Project name contains invalid control characters."
		return 1
	fi

	if ((${#PROJECT_NAME} > 100)); then
		print_error "Project name cannot exceed 100 characters."
		return 1
	fi

	if [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ||
		"$PROJECT_NAME" == "." ||
		"$PROJECT_NAME" == ".." ]]; then
		print_error "Project name may contain only letters, numbers, '.', '-', and '_'."
		return 1
	fi

	PROJECT_PATH="$BASE_DIR/$PROJECT_NAME"

	if [[ -L "$PROJECT_PATH" ]]; then
		print_error "The project path cannot be a symbolic link: $PROJECT_PATH"
		return 1
	fi

	if [[ -n "$FEATURE_BRANCH" ]]; then
		if contains_control_characters "$FEATURE_BRANCH"; then
			print_error "Feature branch contains invalid control characters."
			return 1
		fi

		if ! git check-ref-format --branch "$FEATURE_BRANCH" >/dev/null 2>&1; then
			print_error "Invalid feature branch name: $FEATURE_BRANCH"
			return 1
		fi
	fi

	if ! git check-ref-format --branch "$INITIAL_BRANCH" >/dev/null 2>&1; then
		print_error "Invalid initial branch name: $INITIAL_BRANCH"
		return 1
	fi

	if [[ -n "$LANGUAGE" ]] && contains_control_characters "$LANGUAGE"; then
		print_error "Language contains invalid control characters."
		return 1
	fi

	if [[ -n "$PROJECT_DESCRIPTION" ]] &&
		contains_control_characters "$PROJECT_DESCRIPTION"; then
		print_error "Project description must be a single line."
		return 1
	fi

	if [[ -n "$GITHUB_ORG" ]] &&
		! validate_repository_owner "$GITHUB_ORG"; then
		print_error "Invalid GitHub organization name: $GITHUB_ORG"
		return 1
	fi

	if ! validate_hostname "$GITHUB_HOST"; then
		print_error "Invalid GitHub hostname: $GITHUB_HOST"
		return 1
	fi

	if [[ -n "$SHARED_REPOSITORY" &&
		! "$SHARED_REPOSITORY" =~ ^(group|true|all|world|everybody|umask|false|0[0-7]{3})$ ]]; then
		print_error "Invalid core.sharedRepository value: $SHARED_REPOSITORY"
		return 1
	fi
}

resolve_existing_file_path() {
	local path
	local directory
	local filename
	local physical_directory

	path=$1

	if contains_control_characters "$path"; then
		return 1
	fi

	if [[ "$path" != /* ]]; then
		path="$PWD/$path"
	fi

	directory=${path%/*}
	filename=${path##*/}

	if [[ "$directory" == "$path" ]]; then
		directory=$PWD
	fi

	if ! physical_directory=$(cd -- "$directory" 2>/dev/null && pwd -P); then
		return 1
	fi

	printf '%s/%s' "$physical_directory" "$filename"
}

validate_optional_sources() {
	local resolved

	if [[ -n "$POST_INIT" ]]; then
		if ! resolved=$(resolve_existing_file_path "$POST_INIT"); then
			print_error "Unable to resolve post-init hook: $POST_INIT"
			return 1
		fi

		POST_INIT=$resolved

		if [[ ! -f "$POST_INIT" ||
			! -r "$POST_INIT" ]]; then
			print_error "Post-init hook is not a readable file: $POST_INIT"
			return 1
		fi
	fi

	if [[ -n "$TEMPLATE_SOURCE" &&
		-e "$TEMPLATE_SOURCE" ]]; then
		if [[ ! -d "$TEMPLATE_SOURCE" ]]; then
			print_error "Local template source is not a directory: $TEMPLATE_SOURCE"
			return 1
		fi
	fi
}

inspect_existing_project_path() {
	local first_entry

	if [[ ! -e "$PROJECT_PATH" ]]; then
		return
	fi

	if [[ ! -d "$PROJECT_PATH" ]]; then
		print_error "Project path exists but is not a directory: $PROJECT_PATH"
		return 1
	fi

	if [[ ! -w "$PROJECT_PATH" ||
		! -x "$PROJECT_PATH" ]]; then
		print_error "Existing project directory is not writable: $PROJECT_PATH"
		return 1
	fi

	if [[ "$ADOPT_EXISTING" == "ask" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			ADOPT_EXISTING="false"
		elif prompt_yes_no \
			"Project directory already exists. Adopt it without deleting existing files?" \
			"n"; then
			ADOPT_EXISTING="true"
		else
			ADOPT_EXISTING="false"
		fi
	fi

	if [[ "$ADOPT_EXISTING" != "true" ]]; then
		print_error "Project path already exists: $PROJECT_PATH"
		return 1
	fi

	if first_entry=$(find "$PROJECT_PATH" -mindepth 1 -maxdepth 1 -print -quit); then
		:
	else
		print_error "Unable to inspect the existing project directory."
		return 1
	fi

	if [[ -n "$first_entry" &&
		! -d "$PROJECT_PATH/.git" &&
		"$NON_INTERACTIVE" != "true" ]]; then
		if ! prompt_yes_no \
			"The directory is non-empty and is not a Git repository. Continue?" \
			"n"; then
			print_error "Existing directory adoption was declined."
			return 1
		fi
	fi

	PROJECT_DIRECTORY_ADOPTED=1
	log_action "Adopting existing project directory: $PROJECT_PATH"
}

acquire_project_lock() {
	local lock_key
	local lock_pid
	local lock_base

	if ((DRY_RUN)); then
		return
	fi

	if ! lock_key=$(printf '%s\0%s' "$BASE_DIR" "$PROJECT_NAME" | cksum); then
		print_error "Unable to calculate project lock identifier."
		return 1
	fi

	lock_key=${lock_key%% *}
	lock_base="${TMPDIR:-/tmp}/initproject-${UID:-user}-${PROJECT_NAME}-${lock_key}"
	LOCK_DIR="$lock_base.lock"

	if mkdir -- "$LOCK_DIR" 2>/dev/null; then
		printf '%d\n' "$$" >"$LOCK_DIR/pid"
		LOCK_ACQUIRED=1
		return
	fi

	lock_pid=""

	if [[ -r "$LOCK_DIR/pid" ]]; then
		if ! lock_pid=$(<"$LOCK_DIR/pid"); then
			lock_pid=""
		fi
	fi

	if [[ "$lock_pid" =~ ^[0-9]+$ ]] &&
		kill -0 "$lock_pid" 2>/dev/null; then
		print_error "Another process is already initializing this project (PID $lock_pid)."
		return 1
	fi

	print_warning "Removing a stale project lock."

	if ! rm -rf -- "$LOCK_DIR"; then
		print_error "Unable to remove stale project lock: $LOCK_DIR"
		return 1
	fi

	if ! mkdir -- "$LOCK_DIR"; then
		print_error "Unable to acquire project lock: $LOCK_DIR"
		return 1
	fi

	printf '%d\n' "$$" >"$LOCK_DIR/pid"
	LOCK_ACQUIRED=1
}

release_project_lock() {
	if ((LOCK_ACQUIRED)) &&
		[[ -n "$LOCK_DIR" &&
			-d "$LOCK_DIR" ]]; then
		rm -rf -- "$LOCK_DIR"
	fi

	LOCK_ACQUIRED=0
}

read_git_identity() {
	local value

	if value=$(git config --get user.name 2>/dev/null); then
		GIT_USER_NAME=$value
	fi

	if value=$(git config --get user.email 2>/dev/null); then
		GIT_USER_EMAIL=$value
	fi

	if [[ -z "$GIT_USER_NAME" &&
		-n "${GIT_AUTHOR_NAME:-}" ]]; then
		GIT_USER_NAME=$GIT_AUTHOR_NAME
	fi

	if [[ -z "$GIT_USER_EMAIL" &&
		-n "${GIT_AUTHOR_EMAIL:-}" ]]; then
		GIT_USER_EMAIL=$GIT_AUTHOR_EMAIL
	fi
}

collect_missing_git_identity() {
	local set_globally

	if [[ -n "$GIT_USER_NAME" &&
		-n "$GIT_USER_EMAIL" ]]; then
		return
	fi

	print_section "Git identity"

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		if [[ -z "$GIT_USER_NAME" ||
			-z "$GIT_USER_EMAIL" ]]; then
			print_error "Git user.name and user.email are required before creating the initial commit."
			printf '%s\n' \
				'Set them with:' \
				'  git config --global user.name "Your Name"' \
				'  git config --global user.email "you@example.com"' >&2
			return 1
		fi
	fi

	if [[ -z "$GIT_USER_NAME" ]]; then
		printf '%s\n' "Git user.name is not configured."

		if ! prompt_line "Git user name"; then
			return 1
		fi

		GIT_USER_NAME=$PROMPT_RESULT
	fi

	if [[ -z "$GIT_USER_EMAIL" ]]; then
		printf '%s\n' "Git user.email is not configured."

		if ! prompt_line "Git email address"; then
			return 1
		fi

		GIT_USER_EMAIL=$PROMPT_RESULT
	fi

	if contains_control_characters "$GIT_USER_NAME" ||
		[[ -z "${GIT_USER_NAME//[[:space:]]/}" ]]; then
		print_error "Git user name is invalid."
		return 1
	fi

	if ! validate_email "$GIT_USER_EMAIL"; then
		print_error "Git email address is invalid: $GIT_USER_EMAIL"
		return 1
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		GIT_IDENTITY_PENDING=1
		return
	fi

	if prompt_yes_no "Save this Git identity globally?" "n"; then
		set_globally=1
	else
		set_globally=0
	fi

	if ((set_globally)); then
		if ! run_checked \
			"Unable to configure global Git user.name." \
			git config --global user.name "$GIT_USER_NAME"; then
			return 1
		fi

		if ! run_checked \
			"Unable to configure global Git user.email." \
			git config --global user.email "$GIT_USER_EMAIL"; then
			return 1
		fi

		GIT_IDENTITY_PENDING=0
		print_success "Global Git identity configured."
	else
		GIT_IDENTITY_PENDING=1
		print_info "Git identity will be configured only for the new repository."
	fi
}

resolve_commit_signing() {
	local configured_signing
	local signing_default

	if configured_signing=$(git config --get user.signingkey 2>/dev/null); then
		GIT_SIGNING_KEY=$configured_signing
	fi

	if [[ "$SIGN_COMMIT" == "true" &&
		-z "$GIT_SIGNING_KEY" ]]; then
		print_error "--sign was requested, but user.signingkey is not configured."
		return 1
	fi

	if [[ "$SIGN_COMMIT" == "false" ]]; then
		return
	fi

	if [[ -z "$GIT_SIGNING_KEY" ]]; then
		SIGN_COMMIT="false"
		return
	fi

	if [[ "$SIGN_COMMIT" == "true" ]]; then
		return
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		if configured_signing=$(git config --bool --get commit.gpgsign 2>/dev/null); then
			SIGN_COMMIT=$configured_signing
		else
			SIGN_COMMIT="false"
		fi
		return
	fi

	signing_default="n"

	if configured_signing=$(git config --bool --get commit.gpgsign 2>/dev/null); then
		if [[ "$configured_signing" == "true" ]]; then
			signing_default="y"
		fi
	fi

	if prompt_yes_no \
		"Sign the initial commit using the configured signing key?" \
		"$signing_default"; then
		SIGN_COMMIT="true"
	else
		SIGN_COMMIT="false"
	fi
}

check_github_cli_support() {
	local version_output
	local help_output

	if ! command -v gh >/dev/null 2>&1; then
		print_error "GitHub CLI is required for remote repository operations."
		printf '%s\n' 'Install it from: https://cli.github.com/' >&2
		return 1
	fi

	if ! version_output=$(gh --version 2>&1); then
		print_error "Unable to determine the GitHub CLI version."
		return 1
	fi

	if [[ -z "${version_output//[[:space:]]/}" ]]; then
		print_error "GitHub CLI returned an empty version response."
		return 1
	fi

	print_info "$(printf '%s\n' "$version_output" | head -n 1)"

	if ! help_output=$(gh repo create --help 2>&1); then
		print_error "Unable to inspect GitHub CLI repository creation support."
		return 1
	fi

	if ! grep -q -- '--source' <<<"$help_output"; then
		print_error "This GitHub CLI version does not support 'gh repo create --source'."
		return 1
	fi
}

ensure_github_authentication() {
	if env "GH_HOST=$GITHUB_HOST" \
		gh auth status --hostname "$GITHUB_HOST" >/dev/null 2>&1; then
		return
	fi

	print_warning "GitHub CLI is not authenticated for $GITHUB_HOST."

	if [[ "$NON_INTERACTIVE" == "true" ||
		$DRY_RUN -eq 1 ]]; then
		print_error "Authenticate before using non-interactive GitHub operations."
		printf 'Run: gh auth login --hostname %q\n' "$GITHUB_HOST" >&2
		return 1
	fi

	if ! prompt_yes_no "Authenticate with GitHub now?" "y"; then
		print_error "GitHub authentication is required for remote creation."
		return 1
	fi

	run_streaming_checked \
		"GitHub authentication failed." \
		gh auth login --hostname "$GITHUB_HOST" || return 1

	if ! env "GH_HOST=$GITHUB_HOST" \
		gh auth status --hostname "$GITHUB_HOST" >/dev/null 2>&1; then
		print_error "GitHub authentication could not be verified."
		return 1
	fi
}

check_github_auth_scopes() {
	local headers
	local scopes
	local normalized_scopes

	if ! headers=$(env "GH_HOST=$GITHUB_HOST" \
		gh api --hostname "$GITHUB_HOST" --include user 2>/dev/null); then
		print_warning "Unable to inspect GitHub token scopes."
		return
	fi

	if ! scopes=$(
		awk '
			BEGIN { IGNORECASE = 1 }
			/^x-oauth-scopes:/ {
				sub(/^[^:]+:[[:space:]]*/, "")
				print
				exit
			}
		' <<<"$headers"
	); then
		print_warning "Unable to parse GitHub token scopes."
		return
	fi

	if [[ -z "${scopes//[[:space:]]/}" ]]; then
		print_warning "GitHub did not report classic OAuth scopes; the token may be fine-grained."
		return
	fi

	normalized_scopes=",${scopes// /},"
	normalized_scopes=${normalized_scopes,,}

	if [[ "$REPOSITORY_VISIBILITY" == "private" ]]; then
		if [[ "$normalized_scopes" != *,repo,* ]]; then
			print_warning "The token does not report the classic 'repo' scope required by many private-repository operations."
		fi
	else
		if [[ "$normalized_scopes" != *,repo,* &&
			"$normalized_scopes" != *,public_repo,* ]]; then
			print_warning "The token does not report 'repo' or 'public_repo' scope."
		fi
	fi

	if [[ "$normalized_scopes" != *,delete_repo,* ]]; then
		print_warning "The token does not report 'delete_repo'; automatic remote rollback may be unavailable."
	fi
}

resolve_github_owner() {
	local login

	if [[ -n "$GITHUB_ORG" ]]; then
		TARGET_OWNER=$GITHUB_ORG
	else
		if ! login=$(env "GH_HOST=$GITHUB_HOST" \
			gh api --hostname "$GITHUB_HOST" user --jq '.login' 2>/dev/null); then
			print_error "Unable to determine the authenticated GitHub account."
			return 1
		fi

		if [[ -z "$login" ]] ||
			! validate_repository_owner "$login"; then
			print_error "GitHub returned an invalid account name."
			return 1
		fi

		TARGET_OWNER=$login
	fi

	REPOSITORY_FULL_NAME="$TARGET_OWNER/$PROJECT_NAME"
	REMOTE_URL="https://$GITHUB_HOST/$REPOSITORY_FULL_NAME"
}

query_existing_github_repository() {
	local repository_data
	local status
	local web_url
	local ssh_url
	local is_private
	local default_branch
	local protocol

	if repository_data=$(env "GH_HOST=$GITHUB_HOST" \
		gh repo view "$REPOSITORY_FULL_NAME" \
		--json url,sshUrl,isPrivate,defaultBranchRef \
		--jq '[
			.url,
			.sshUrl,
			(.isPrivate | tostring),
			(.defaultBranchRef.name // "")
		] | @tsv' 2>&1); then
		:
	else
		status=$?

		if grep -Eqi \
			'(HTTP[[:space:]/.0-9]*404|not found|Could not resolve to a Repository)' \
			<<<"$repository_data"; then
			return 1
		fi

		LAST_COMMAND_DISPLAY="gh repo view $REPOSITORY_FULL_NAME"
		LAST_COMMAND_OUTPUT=$repository_data
		LAST_COMMAND_STATUS=$status
		report_last_command_failure "Unable to determine whether the GitHub repository exists."
		return 2
	fi

	IFS=$'\t' read -r web_url ssh_url is_private default_branch <<<"$repository_data"

	if [[ -z "$web_url" ]]; then
		print_error "GitHub returned an existing repository without a URL."
		return 2
	fi

	protocol="https"

	if protocol=$(env "GH_HOST=$GITHUB_HOST" \
		gh config get git_protocol --host "$GITHUB_HOST" 2>/dev/null); then
		:
	else
		protocol="https"
	fi

	if [[ "$protocol" == "ssh" &&
		-n "$ssh_url" ]]; then
		REMOTE_URL=$ssh_url
	else
		REMOTE_URL=$web_url
	fi

	REMOTE_DEFAULT_BRANCH=$default_branch

	if [[ -n "$REMOTE_DEFAULT_BRANCH" ]]; then
		REMOTE_HAS_HISTORY=1
	fi

	if [[ "$is_private" == "true" &&
		"$REPOSITORY_VISIBILITY" == "public" ]]; then
		print_warning "The existing repository is private; requested public visibility will not be changed."
	fi

	if [[ "$is_private" == "false" &&
		"$REPOSITORY_VISIBILITY" == "private" ]]; then
		print_warning "The existing repository is public; requested private visibility will not be changed."
	fi

	return 0
}

resolve_remote_collision() {
	local query_status

	if query_existing_github_repository; then
		query_status=0
	else
		query_status=$?
	fi

	case "$query_status" in
	0)
		if [[ "$ADOPT_EXISTING_REMOTE" == "ask" ]]; then
			if [[ "$NON_INTERACTIVE" == "true" ]]; then
				ADOPT_EXISTING_REMOTE="false"
			elif prompt_yes_no \
				"GitHub repository $REPOSITORY_FULL_NAME already exists. Connect to it?" \
				"n"; then
				ADOPT_EXISTING_REMOTE="true"
			else
				ADOPT_EXISTING_REMOTE="false"
			fi
		fi

		if [[ "$ADOPT_EXISTING_REMOTE" != "true" ]]; then
			print_error "GitHub repository already exists: $REPOSITORY_FULL_NAME"
			return 1
		fi

		REMOTE_ACTION="adopt"
		print_info "Existing GitHub repository will be connected as origin."
		;;
	1)
		REMOTE_ACTION="create"
		;;
	*)
		return 1
		;;
	esac
}

preflight_github_remote() {
	if [[ "$REMOTE_REQUEST" != "true" ]]; then
		REMOTE_ACTION="none"
		return
	fi

	check_github_cli_support || return 1
	ensure_github_authentication || return 1
	check_github_auth_scopes
	resolve_github_owner || return 1
	resolve_remote_collision || return 1
}

print_plan() {
	print_section "Execution plan"

	printf "  %-21s %s\n" "Project:" "$PROJECT_NAME"
	printf "  %-21s %s\n" "Location:" "$PROJECT_PATH"
	printf "  %-21s %s\n" "Initial branch:" "$INITIAL_BRANCH"
	printf "  %-21s %s\n" "Feature branch:" "${FEATURE_BRANCH:-none}"
	printf "  %-21s %s\n" "Language:" "${LANGUAGE:-unspecified}"
	printf "  %-21s %s\n" "License:" "$LICENSE_ID"
	printf "  %-21s %s\n" "CI workflow:" "$CREATE_CI"
	printf "  %-21s %s\n" "Signed commit:" "$SIGN_COMMIT"
	printf "  %-21s %s\n" "Secret scan:" "$SECRET_SCAN"
	printf "  %-21s %s\n" "Metadata file:" "$([[ $CREATE_METADATA -eq 1 ]] && printf yes || printf no)"

	if [[ "$REMOTE_REQUEST" == "true" ]]; then
		printf "  %-21s %s\n" "GitHub repository:" "$REPOSITORY_FULL_NAME"
		printf "  %-21s %s\n" "Remote action:" "$REMOTE_ACTION"
		printf "  %-21s %s\n" "Visibility:" "$REPOSITORY_VISIBILITY"
		printf "  %-21s %s\n" "Remote URL:" "$REMOTE_URL"
	else
		printf "  %-21s %s\n" "GitHub repository:" "disabled"
	fi

	if [[ -n "$TEMPLATE_SOURCE" ]]; then
		printf "  %-21s %s\n" "Template:" "$TEMPLATE_SOURCE"
	fi

	if [[ -n "$POST_INIT" ]]; then
		printf "  %-21s %s\n" "Post-init hook:" "$POST_INIT"
	fi

	if ((DRY_RUN)); then
		printf "\n%bRollback plan%b\n" "$BOLD" "$RESET"
		printf "  Remote repository: %s\n" \
			"$([[ $ROLLBACK_MODE == true ]] && printf 'would be deleted' || printf 'would be preserved or confirmed')"
		printf "  Local directory:   %s\n" \
			"$([[ $ROLLBACK_MODE == true ]] && printf 'would be deleted if newly created' || printf 'would be preserved or confirmed')"
	fi
}

confirm_execution() {
	if ((DRY_RUN)) ||
		[[ "$NON_INTERACTIVE" == "true" ]] ||
		((ASSUME_YES)); then
		return
	fi

	if ! prompt_yes_no "Proceed with project initialization?" "y"; then
		RUN_CANCELLED=1
		PROJECT_COMPLETE=1
		print_info "Project initialization canceled."
	fi
}

create_project_directory() {
	if [[ -d "$PROJECT_PATH" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		print_dry_run_command mkdir -p -- "$PROJECT_PATH"
		return
	fi

	if ! mkdir -p -- "$PROJECT_PATH"; then
		print_error "Unable to create project directory: $PROJECT_PATH"
		return 1
	fi

	PROJECT_DIRECTORY_CREATED=1
	log_action "Created project directory: $PROJECT_PATH"
}

copy_template_directory() {
	local source
	source=$1

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Copy template %q into %q\n" \
			"$DIM" "$RESET" "$source" "$PROJECT_PATH"
		return
	fi

	if ! tar \
		-C "$source" \
		--exclude='./.git' \
		--exclude='.git' \
		-cf - . |
		tar -C "$PROJECT_PATH" -xf -; then
		print_error "Unable to copy project template."
		return 1
	fi
}

apply_project_template() {
	local cloned_template

	if [[ -z "$TEMPLATE_SOURCE" ]]; then
		return
	fi

	print_info "Applying project template."

	if [[ -d "$TEMPLATE_SOURCE" ]]; then
		copy_template_directory "$TEMPLATE_SOURCE" || return 1
		return
	fi

	cloned_template="$RUNTIME_DIR/template"

	run_network_command \
		"Cloning project template" \
		git clone --depth 1 -- "$TEMPLATE_SOURCE" "$cloned_template" || return 1

	copy_template_directory "$cloned_template" || return 1
}

write_readme() {
	local readme_file

	readme_file="$PROJECT_PATH/README.md"

	if [[ -e "$readme_file" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s\n" "$DIM" "$RESET" "$readme_file"
		return
	fi

	{
		printf '# %s\n\n' "$PROJECT_NAME"

		if [[ -n "$PROJECT_DESCRIPTION" ]]; then
			printf '%s\n' "$PROJECT_DESCRIPTION"
		else
			printf 'Project description goes here.\n'
		fi

		printf '\n## Development\n\n'
		printf 'Development instructions will be added as the project evolves.\n'
	} >"$readme_file"
}

write_editorconfig() {
	local editorconfig_file

	editorconfig_file="$PROJECT_PATH/.editorconfig"

	if [[ -e "$editorconfig_file" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s\n" "$DIM" "$RESET" "$editorconfig_file"
		return
	fi

	cat >"$editorconfig_file" <<'EDITORCONFIG'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = tab
trim_trailing_whitespace = true

[*.{json,yaml,yml,md}]
indent_style = space
indent_size = 2

[Makefile]
indent_style = tab
EDITORCONFIG
}

write_gitignore() {
	local gitignore_file
	local language_key

	gitignore_file="$PROJECT_PATH/.gitignore"

	if [[ -e "$gitignore_file" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create language-aware %s\n" \
			"$DIM" "$RESET" "$gitignore_file"
		return
	fi

	language_key=${LANGUAGE,,}

	{
		printf '%s\n' \
			'.DS_Store' \
			'Thumbs.db' \
			'*.swp' \
			'*.swo' \
			'.idea/' \
			'.vscode/' \
			'.env' \
			'.env.*' \
			'!.env.example'

		case "$language_key" in
		python | py)
			printf '%s\n' \
				'__pycache__/' \
				'*.py[cod]' \
				'.pytest_cache/' \
				'.mypy_cache/' \
				'.ruff_cache/' \
				'.venv/' \
				'venv/' \
				'dist/' \
				'build/' \
				'*.egg-info/'
			;;
		node | nodejs | javascript | typescript | js | ts)
			printf '%s\n' \
				'node_modules/' \
				'dist/' \
				'build/' \
				'coverage/' \
				'.npm/' \
				'.yarn/' \
				'*.tsbuildinfo'
			;;
		rust)
			printf '%s\n' \
				'target/' \
				'**/*.rs.bk'
			;;
		go | golang)
			printf '%s\n' \
				'bin/' \
				'coverage.out' \
				'*.test'
			;;
		java | kotlin)
			printf '%s\n' \
				'.gradle/' \
				'build/' \
				'target/' \
				'*.class' \
				'*.jar'
			;;
		c | cpp | c++)
			printf '%s\n' \
				'build/' \
				'cmake-build-*/' \
				'*.o' \
				'*.obj' \
				'*.a' \
				'*.so' \
				'*.dll' \
				'*.exe'
			;;
		esac
	} >"$gitignore_file"
}

write_overview() {
	local overview_file

	overview_file="$PROJECT_PATH/docs/overview.md"

	if [[ -e "$overview_file" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s\n" "$DIM" "$RESET" "$overview_file"
		return
	fi

	cat >"$overview_file" <<EOF
# Project Overview

## Purpose

${PROJECT_DESCRIPTION:-Describe the purpose of this project.}

## Architecture

Document the project architecture here.

## Operations

Document build, test, deployment, and support procedures here.
EOF
}

download_license_file() {
	local license_url
	local output_file

	output_file=$1

	case "$LICENSE_ID" in
	apache-2.0)
		license_url="https://raw.githubusercontent.com/spdx/license-list-data/main/text/Apache-2.0.txt"
		;;
	gpl-3.0)
		license_url="https://raw.githubusercontent.com/spdx/license-list-data/main/text/GPL-3.0-only.txt"
		;;
	*)
		print_error "Unsupported downloadable license: $LICENSE_ID"
		return 1
		;;
	esac

	if command -v curl >/dev/null 2>&1; then
		run_network_command \
			"Downloading $LICENSE_ID license" \
			curl --fail --silent --show-error --location \
			--output "$output_file" "$license_url" || return 1
	elif command -v wget >/dev/null 2>&1; then
		run_network_command \
			"Downloading $LICENSE_ID license" \
			wget --quiet --output-document="$output_file" "$license_url" || return 1
	else
		print_error "curl or wget is required to download the $LICENSE_ID license."
		return 1
	fi

	if ((DRY_RUN)); then
		return
	fi

	if [[ ! -s "$output_file" ]]; then
		print_error "Downloaded license file is empty."
		return 1
	fi
}

write_license() {
	local license_file
	local year
	local owner
	local temporary_license

	if [[ "$LICENSE_ID" == "none" ]]; then
		return
	fi

	license_file="$PROJECT_PATH/LICENSE"

	if [[ -e "$license_file" ]]; then
		print_warning "LICENSE already exists; generated license was skipped."
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s license at %s\n" \
			"$DIM" "$RESET" "$LICENSE_ID" "$license_file"
		return
	fi

	if [[ "$LICENSE_ID" == "mit" ]]; then
		if ! year=$(date '+%Y'); then
			print_error "Unable to determine the current year."
			return 1
		fi

		owner=${GIT_USER_NAME:-$TARGET_OWNER}

		cat >"$license_file" <<EOF
MIT License

Copyright (c) $year $owner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
		return
	fi

	temporary_license="$RUNTIME_DIR/LICENSE.download"

	download_license_file "$temporary_license" || return 1

	if ! mv -- "$temporary_license" "$license_file"; then
		print_error "Unable to install downloaded license file."
		return 1
	fi
}

write_ci_workflow() {
	local workflow_directory
	local workflow_file
	local language_key

	if [[ "$CREATE_CI" != "true" ]]; then
		return
	fi

	workflow_directory="$PROJECT_PATH/.github/workflows"
	workflow_file="$workflow_directory/ci.yml"
	language_key=${LANGUAGE,,}

	if [[ -e "$workflow_file" ]]; then
		print_warning "CI workflow already exists; generation was skipped."
		return
	fi

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s\n" "$DIM" "$RESET" "$workflow_file"
		return
	fi

	if ! mkdir -p -- "$workflow_directory"; then
		print_error "Unable to create GitHub Actions workflow directory."
		return 1
	fi

	case "$language_key" in
	python | py)
		cat >"$workflow_file" <<'YAML'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"
      - name: Validate Python sources
        run: python -m compileall src tests
YAML
		;;
	node | nodejs | javascript | typescript | js | ts)
		cat >"$workflow_file" <<'YAML'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "lts/*"
      - name: Install dependencies
        if: hashFiles('package-lock.json') != ''
        run: npm ci
      - name: Run tests
        if: hashFiles('package.json') != ''
        run: npm test --if-present
YAML
		;;
	rust)
		cat >"$workflow_file" <<'YAML'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check project
        if: hashFiles('Cargo.toml') != ''
        run: cargo check --all-targets
      - name: Run tests
        if: hashFiles('Cargo.toml') != ''
        run: cargo test
YAML
		;;
	go | golang)
		cat >"$workflow_file" <<'YAML'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: stable
      - name: Run tests
        if: hashFiles('go.mod') != ''
        run: go test ./...
YAML
		;;
	*)
		cat >"$workflow_file" <<'YAML'
name: CI

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate repository
        run: |
          git status --short
          test -f README.md
YAML
		;;
	esac
}

create_standard_structure() {
	if ((DRY_RUN)); then
		print_dry_run_command mkdir -p -- \
			"$PROJECT_PATH/src" \
			"$PROJECT_PATH/tests" \
			"$PROJECT_PATH/docs"
	else
		if ! mkdir -p -- \
			"$PROJECT_PATH/src" \
			"$PROJECT_PATH/tests" \
			"$PROJECT_PATH/docs"; then
			print_error "Unable to create project directory structure."
			return 1
		fi
	fi

	write_readme || return 1
	write_editorconfig || return 1
	write_gitignore || return 1
	write_overview || return 1
	write_license || return 1
	write_ci_workflow || return 1

	print_success "Project files generated."
}

initialize_git_repository() {
	if [[ -d "$PROJECT_PATH/.git" ]]; then
		print_info "Using the existing Git repository."
		return
	fi

	run_checked \
		"Unable to initialize the Git repository." \
		git -C "$PROJECT_PATH" init || return 1

	run_checked \
		"Unable to configure the initial branch." \
		git -C "$PROJECT_PATH" symbolic-ref \
		HEAD "refs/heads/$INITIAL_BRANCH" || return 1

	print_success "Git repository initialized."
	log_action "Initialized Git repository in $PROJECT_PATH"
}

apply_local_git_configuration() {
	if ((GIT_IDENTITY_PENDING)); then
		run_checked \
			"Unable to configure repository-local Git user.name." \
			git -C "$PROJECT_PATH" config user.name "$GIT_USER_NAME" || return 1

		run_checked \
			"Unable to configure repository-local Git user.email." \
			git -C "$PROJECT_PATH" config user.email "$GIT_USER_EMAIL" || return 1
	fi

	if [[ -n "$SHARED_REPOSITORY" ]]; then
		run_checked \
			"Unable to configure core.sharedRepository." \
			git -C "$PROJECT_PATH" config \
			core.sharedRepository "$SHARED_REPOSITORY" || return 1
	fi
}

run_post_init_hook() {
	if [[ -z "$POST_INIT" ]]; then
		return
	fi

	print_info "Running post-init hook."

	run_checked \
		"Post-init hook failed." \
		env \
		"PROJECT_NAME=$PROJECT_NAME" \
		"PROJECT_PATH=$PROJECT_PATH" \
		"INITIAL_BRANCH=$INITIAL_BRANCH" \
		"FEATURE_BRANCH=$FEATURE_BRANCH" \
		"LANGUAGE=$LANGUAGE" \
		"GITHUB_REPOSITORY=$REPOSITORY_FULL_NAME" \
		"GITHUB_VISIBILITY=$REPOSITORY_VISIBILITY" \
		"$BASH_PATH" "$POST_INIT" || return 1

	print_success "Post-init hook completed."
}

run_secret_scan() {
	local scanner

	if [[ "$SECRET_SCAN" == "false" ]]; then
		return
	fi

	scanner=""

	if command -v gitleaks >/dev/null 2>&1; then
		scanner="gitleaks"
	elif git -C "$PROJECT_PATH" secrets --help >/dev/null 2>&1; then
		scanner="git-secrets"
	fi

	if [[ -z "$scanner" ]]; then
		if [[ "$SECRET_SCAN" == "true" ]]; then
			print_error "Secret scanning was required, but gitleaks and git-secrets are unavailable."
			return 1
		fi

		print_info "No supported secret scanner detected; scan skipped."
		return
	fi

	case "$scanner" in
	gitleaks)
		run_checked \
			"gitleaks detected a secret or failed." \
			gitleaks detect --source "$PROJECT_PATH" --no-git || return 1
		;;
	git-secrets)
		run_checked \
			"git-secrets detected a secret or failed." \
			git -C "$PROJECT_PATH" secrets --scan -r || return 1
		;;
	esac

	print_success "Secret scan completed."
}

json_escape() {
	local value

	value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\b'/\\b}
	value=${value//$'\f'/\\f}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	value=${value//$'\t'/\\t}

	printf '%s' "$value"
}

write_project_metadata() {
	local metadata_file
	local timestamp
	local escaped_project
	local escaped_path
	local escaped_branch
	local escaped_feature
	local escaped_language
	local escaped_remote
	local escaped_repository
	local escaped_visibility
	local escaped_template

	if ((CREATE_METADATA == 0)); then
		return
	fi

	metadata_file="$PROJECT_PATH/.project.json"

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Create %s\n" "$DIM" "$RESET" "$metadata_file"
		return
	fi

	if ! timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); then
		print_error "Unable to generate project metadata timestamp."
		return 1
	fi

	escaped_project=$(json_escape "$PROJECT_NAME")
	escaped_path=$(json_escape "$PROJECT_PATH")
	escaped_branch=$(json_escape "$INITIAL_BRANCH")
	escaped_feature=$(json_escape "$FEATURE_BRANCH")
	escaped_language=$(json_escape "$LANGUAGE")
	escaped_remote=$(json_escape "$REMOTE_URL")
	escaped_repository=$(json_escape "$REPOSITORY_FULL_NAME")
	escaped_visibility=$(json_escape "$REPOSITORY_VISIBILITY")
	escaped_template=$(json_escape "$TEMPLATE_SOURCE")

	cat >"$metadata_file" <<EOF
{
  "schema_version": 1,
  "created_at": "$timestamp",
  "created_by": "$PROGRAM_NAME $SCRIPT_VERSION",
  "project_name": "$escaped_project",
  "project_path": "$escaped_path",
  "initial_branch": "$escaped_branch",
  "feature_branch": "$escaped_feature",
  "language": "$escaped_language",
  "license": "$LICENSE_ID",
  "remote": {
    "enabled": $([[ "$REMOTE_REQUEST" == "true" ]] && printf true || printf false),
    "repository": "$escaped_repository",
    "url": "$escaped_remote",
    "visibility": "$escaped_visibility"
  },
  "template": "$escaped_template"
}
EOF
}

repository_has_commits() {
	git -C "$PROJECT_PATH" rev-parse --verify HEAD >/dev/null 2>&1
}

create_initial_commit() {
	local -a commit_command

	if repository_has_commits; then
		print_warning "Repository already contains commits; initial commit was skipped."
		return
	fi

	run_checked \
		"Unable to stage project files." \
		git -C "$PROJECT_PATH" add --all || return 1

	if git -C "$PROJECT_PATH" diff --cached --quiet; then
		print_error "No files are available for the initial commit."
		return 1
	fi

	commit_command=(git -C "$PROJECT_PATH" commit)

	if [[ "$SIGN_COMMIT" == "true" ]]; then
		commit_command+=(-S)
	fi

	commit_command+=(-m "initial commit")

	run_checked \
		"Unable to create the initial commit." \
		"${commit_command[@]}" || return 1

	print_success "Initial commit created on $INITIAL_BRANCH."
	log_action "Created initial commit on $INITIAL_BRANCH"
}

add_origin_remote() {
	local existing_origin

	if existing_origin=$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null); then
		if [[ "$existing_origin" == "$REMOTE_URL" ]]; then
			REMOTE_CONFIGURED=1
			return
		fi

		print_error "Remote origin already exists with a different URL: $existing_origin"
		return 1
	fi

	run_checked \
		"Unable to configure origin remote." \
		git -C "$PROJECT_PATH" remote add origin "$REMOTE_URL" || return 1

	REMOTE_CONFIGURED=1
}

github_repository_exists_now() {
	env "GH_HOST=$GITHUB_HOST" \
		gh repo view "$REPOSITORY_FULL_NAME" >/dev/null 2>&1
}

create_github_repository() {
	local attempt
	local delay
	local visibility_option
	local -a create_command

	visibility_option="--$REPOSITORY_VISIBILITY"
	attempt=1
	delay=1

	create_command=(
		env "GH_HOST=$GITHUB_HOST"
		gh repo create "$REPOSITORY_FULL_NAME"
		"--source=$PROJECT_PATH"
		"$visibility_option"
		"--remote=origin"
	)

	if [[ -n "$PROJECT_DESCRIPTION" ]]; then
		create_command+=("--description=$PROJECT_DESCRIPTION")
	fi

	if ((DRY_RUN)); then
		print_dry_run_command "${create_command[@]}"
		REMOTE_CONFIGURED=1
		return
	fi

	while ((attempt <= NETWORK_ATTEMPTS)); do
		if run_captured_with_spinner \
			"Creating GitHub repository (attempt $attempt/$NETWORK_ATTEMPTS)" \
			"${create_command[@]}"; then
			REMOTE_CREATED=1
			REMOTE_CREATION_CERTAIN=1
			REMOTE_CONFIGURED=1

			if ! REMOTE_URL=$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null); then
				print_error "Repository was created, but origin could not be verified."
				return 1
			fi

			print_success "GitHub repository created and connected."
			log_action "Created GitHub repository: $REPOSITORY_FULL_NAME"
			return
		fi

		if github_repository_exists_now; then
			REMOTE_CREATED=1
			REMOTE_CREATION_CERTAIN=0

			print_warning "The repository exists after a failed create command; ownership of the creation is uncertain."

			if ! REMOTE_URL=$(env "GH_HOST=$GITHUB_HOST" \
				gh repo view "$REPOSITORY_FULL_NAME" --json url --jq '.url' 2>/dev/null); then
				print_error "Unable to retrieve the repository URL after creation."
				return 1
			fi

			add_origin_remote || return 1
			return
		fi

		if ((attempt == NETWORK_ATTEMPTS)); then
			report_last_command_failure "Unable to create the GitHub repository."
			return "$LAST_COMMAND_STATUS"
		fi

		print_warning "Repository creation failed; retrying in ${delay}s."
		sleep "$delay"
		delay=$((delay * 2))
		attempt=$((attempt + 1))
	done
}

configure_remote_repository() {
	if [[ "$REMOTE_ACTION" == "none" ]]; then
		return
	fi

	case "$REMOTE_ACTION" in
	adopt)
		add_origin_remote || return 1
		print_success "Existing GitHub repository connected as origin."
		;;
	create)
		create_github_repository || return 1
		;;
	*)
		print_error "Invalid remote action: $REMOTE_ACTION"
		return 1
		;;
	esac
}

push_initial_branch() {
	if ((REMOTE_CONFIGURED == 0)); then
		return
	fi

	if [[ "$REMOTE_ACTION" == "adopt" &&
		$REMOTE_HAS_HISTORY -eq 1 ]]; then
		print_warning "The existing remote contains history; automatic push was skipped."
		print_info "Review the remote history before merging or pushing."
		return
	fi

	run_network_command \
		"Pushing $INITIAL_BRANCH to origin" \
		git -C "$PROJECT_PATH" push -u origin "$INITIAL_BRANCH" || return 1

	print_success "Initial branch pushed to origin."
	log_action "Pushed $INITIAL_BRANCH to origin"
}

create_feature_branch() {
	if [[ -z "$FEATURE_BRANCH" ]]; then
		return
	fi

	if git -C "$PROJECT_PATH" show-ref \
		--verify --quiet "refs/heads/$FEATURE_BRANCH"; then
		run_checked \
			"Unable to switch to the existing feature branch." \
			git -C "$PROJECT_PATH" switch "$FEATURE_BRANCH" || return 1

		print_success "Switched to existing branch: $FEATURE_BRANCH"
	else
		run_checked \
			"Unable to create the feature branch." \
			git -C "$PROJECT_PATH" switch -c "$FEATURE_BRANCH" || return 1

		print_success "Created feature branch: $FEATURE_BRANCH"
	fi

	log_action "Selected feature branch: $FEATURE_BRANCH"
}

print_summary() {
	print_section "Project initialization complete"

	printf "  %-18s %s\n" "Project:" "$PROJECT_NAME"
	printf "  %-18s %s\n" "Local path:" "$PROJECT_PATH"
	printf "  %-18s %s\n" "Initial branch:" "$INITIAL_BRANCH"
	printf "  %-18s %s\n" "Current branch:" "${FEATURE_BRANCH:-$INITIAL_BRANCH}"
	printf "  %-18s %s\n" "License:" "$LICENSE_ID"
	printf "  %-18s %s\n" "Language:" "${LANGUAGE:-unspecified}"

	if ((REMOTE_CONFIGURED)); then
		printf "  %-18s %s\n" "GitHub:" "$REMOTE_URL"
		printf "  %-18s %s\n" "Visibility:" "$REPOSITORY_VISIBILITY"
	else
		printf "  %-18s %s\n" "GitHub:" "not configured"
	fi

	printf "\n%bNext steps%b\n" "$BOLD" "$RESET"
	printf "  cd %q\n" "$PROJECT_PATH"

	if [[ -n "$FEATURE_BRANCH" &&
		$REMOTE_CONFIGURED -eq 1 ]]; then
		printf "  git push -u origin %q\n" "$FEATURE_BRANCH"
	fi

	if [[ "$REMOTE_ACTION" == "adopt" &&
		$REMOTE_HAS_HISTORY -eq 1 ]]; then
		printf "  git fetch origin\n"
		printf "  git log --oneline --graph --decorate --all\n"
	fi
}

resolve_editor_command() {
	local candidate

	if [[ -n "$EDITOR_COMMAND" ]]; then
		if contains_control_characters "$EDITOR_COMMAND"; then
			print_error "Editor command contains invalid control characters."
			return 1
		fi

		if ! candidate=$(command -v "$EDITOR_COMMAND" 2>/dev/null); then
			print_error "Editor command not found: $EDITOR_COMMAND"
			return 1
		fi

		printf '%s' "$candidate"
		return
	fi

	for candidate in code codium idea; do
		if command -v "$candidate" >/dev/null 2>&1; then
			command -v "$candidate"
			return
		fi
	done

	return 1
}

open_project_editor() {
	local editor

	if [[ "$OPEN_EDITOR" == "ask" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			OPEN_EDITOR="false"
		elif resolve_editor_command >/dev/null 2>&1 &&
			prompt_yes_no "Open the project in the detected editor?" "n"; then
			OPEN_EDITOR="true"
		else
			OPEN_EDITOR="false"
		fi
	fi

	if [[ "$OPEN_EDITOR" != "true" ]]; then
		return
	fi

	if ! editor=$(resolve_editor_command); then
		print_warning "No supported editor command was found."
		return
	fi

	if ((DRY_RUN)); then
		print_dry_run_command "$editor" "$PROJECT_PATH"
		return
	fi

	if ! "$editor" "$PROJECT_PATH" >/dev/null 2>&1 & then
		print_warning "Unable to launch editor: $editor"
		return
	fi

	print_success "Editor launched."
}

send_desktop_notification() {
	local message

	if [[ "$SEND_NOTIFICATION" != "true" ]]; then
		return
	fi

	message="Project ready at $PROJECT_PATH"

	if ((DRY_RUN)); then
		printf "%b[DRY RUN]%b Send desktop notification: %s\n" \
			"$DIM" "$RESET" "$message"
		return
	fi

	if command -v notify-send >/dev/null 2>&1; then
		if ! notify-send "Project initialized" "$message" >/dev/null 2>&1; then
			print_warning "Desktop notification failed."
		fi
		return
	fi

	if command -v osascript >/dev/null 2>&1; then
		if ! osascript \
			-e "display notification \"${message//\"/\\\"}\" with title \"Project initialized\"" \
			>/dev/null 2>&1; then
			print_warning "Desktop notification failed."
		fi
		return
	fi

	print_warning "No supported desktop notification command was found."
}

resolve_safe_shell() {
	local candidate
	local fallback

	candidate=${SHELL:-}

	if [[ -n "$candidate" &&
		"$candidate" == /* &&
		-x "$candidate" ]] &&
		! contains_control_characters "$candidate"; then
		if [[ -r /etc/shells ]]; then
			if grep -Fxq -- "$candidate" /etc/shells; then
				printf '%s' "$candidate"
				return
			fi
		else
			case "${candidate##*/}" in
			bash | zsh | ksh | fish)
				printf '%s' "$candidate"
				return
				;;
			esac
		fi
	fi

	for fallback in /bin/bash /usr/bin/bash "$BASH_PATH"; do
		if [[ -n "$fallback" &&
			"$fallback" == /* &&
			-x "$fallback" ]] &&
			! contains_control_characters "$fallback"; then
			printf '%s' "$fallback"
			return
		fi
	done

	print_error "Unable to resolve a safe interactive shell."
	return 1
}

cleanup_runtime_resources() {
	if ((CLEANUP_COMPLETED)); then
		return
	fi

	release_project_lock

	if [[ -n "$RUNTIME_DIR" &&
		-d "$RUNTIME_DIR" ]]; then
		rm -rf -- "$RUNTIME_DIR"
	fi

	CLEANUP_COMPLETED=1
}

open_project_shell() {
	local shell_path

	if [[ "$AUTO_NAVIGATE" == "ask" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			AUTO_NAVIGATE="false"
		elif prompt_yes_no \
			"Open an interactive shell in the new project directory?" \
			"y"; then
			AUTO_NAVIGATE="true"
		else
			AUTO_NAVIGATE="false"
		fi
	fi

	if [[ "$AUTO_NAVIGATE" != "true" ]]; then
		return
	fi

	if ((DRY_RUN)); then
		print_dry_run_command cd "$PROJECT_PATH"
		print_info "An interactive shell would be opened in the project directory."
		return
	fi

	if ! shell_path=$(resolve_safe_shell); then
		return 1
	fi

	if ! cd -- "$PROJECT_PATH"; then
		print_error "Unable to enter project directory: $PROJECT_PATH"
		return 1
	fi

	cleanup_runtime_resources
	trap - EXIT INT TERM HUP

	printf "%bOpening interactive shell in:%b %s\n" \
		"$GREEN" "$RESET" "$PROJECT_PATH"

	exec "$shell_path" -i
}

confirm_rollback_resource() {
	local resource
	resource=$1

	case "$ROLLBACK_MODE" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	ask)
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			return 1
		fi

		prompt_yes_no "Delete $resource as part of rollback?" "n"
		;;
	*)
		return 1
		;;
	esac
}

rollback_remote_repository() {
	if ((REMOTE_CREATED == 0)) ||
		[[ -z "$REPOSITORY_FULL_NAME" ]]; then
		return
	fi

	if ((REMOTE_CREATION_CERTAIN == 0)); then
		print_warning "Remote repository creation is uncertain; automatic deletion is disabled."
		return
	fi

	if ! confirm_rollback_resource \
		"GitHub repository $REPOSITORY_FULL_NAME"; then
		print_info "Preserving GitHub repository: $REPOSITORY_FULL_NAME"
		return
	fi

	print_warning "Deleting GitHub repository created by this run."

	if ! run_network_command \
		"Deleting GitHub repository" \
		env "GH_HOST=$GITHUB_HOST" \
		gh repo delete "$REPOSITORY_FULL_NAME" --yes; then
		print_warning "Unable to delete GitHub repository during rollback."
		return
	fi

	log_action "Rolled back GitHub repository: $REPOSITORY_FULL_NAME"
}

rollback_local_project() {
	if ((PROJECT_DIRECTORY_CREATED == 0)) ||
		((PROJECT_DIRECTORY_ADOPTED)); then
		return
	fi

	if [[ -z "$PROJECT_PATH" ||
		"$PROJECT_PATH" == "/" ||
		! -d "$PROJECT_PATH" ]]; then
		return
	fi

	if ! confirm_rollback_resource \
		"local project directory $PROJECT_PATH"; then
		print_info "Preserving local project directory: $PROJECT_PATH"
		return
	fi

	print_warning "Removing local project directory created by this run."

	if ! rm -rf -- "$PROJECT_PATH"; then
		print_warning "Unable to remove local project directory during rollback."
		return
	fi

	log_action "Rolled back local project directory: $PROJECT_PATH"
}

rollback_after_failure() {
	if ((DRY_RUN)) ||
		((PROJECT_COMPLETE)); then
		return
	fi

	printf "\n%bFailure recovery%b\n" "$BOLD$YELLOW" "$RESET"
	printf "%b----------------------------------------%b\n" "$DIM" "$RESET"

	rollback_remote_repository
	rollback_local_project
}

handle_signal() {
	local signal_name
	signal_name=$1

	FAILURE_CONTEXT="Interrupted by $signal_name"
	print_error "$FAILURE_CONTEXT"
}

on_exit() {
	local status
	status=$1

	set +e

	if ((status != 0)); then
		if [[ -n "$FAILURE_CONTEXT" ]]; then
			print_error "$FAILURE_CONTEXT"
		else
			print_error "Project initialization failed with exit status $status."
		fi

		rollback_after_failure
	fi

	cleanup_runtime_resources
}

trap 'handle_signal SIGINT; exit 130' INT
trap 'handle_signal SIGTERM; exit 143' TERM
trap 'handle_signal SIGHUP; exit 129' HUP
trap 'status=$?; trap - EXIT; on_exit "$status"; exit "$status"' EXIT

main() {
	initialize_environment_values || return 1
	parse_arguments "$@" || return 1

	if ((SHOW_HELP)); then
		print_help
		PROJECT_COMPLETE=1
		return
	fi

	validate_dependencies || return 1
	prepare_base_directory || return 1
	initialize_logging || return 1
	create_runtime_directory || return 1

	collect_project_name || return 1
	collect_optional_project_values || return 1
	collect_remote_request || return 1
	collect_visibility || return 1
	collect_license || return 1
	collect_ci_request || return 1
	resolve_initial_branch

	validate_project_configuration || return 1
	validate_optional_sources || return 1
	inspect_existing_project_path || return 1

	read_git_identity
	collect_missing_git_identity || return 1
	resolve_commit_signing || return 1
	preflight_github_remote || return 1

	print_plan
	confirm_execution || return 1

	if ((RUN_CANCELLED)); then
		return
	fi

	acquire_project_lock || return 1
	create_project_directory || return 1
	apply_project_template || return 1
	create_standard_structure || return 1
	initialize_git_repository || return 1
	apply_local_git_configuration || return 1
	run_post_init_hook || return 1
	run_secret_scan || return 1
	write_project_metadata || return 1
	create_initial_commit || return 1
	configure_remote_repository || return 1
	push_initial_branch || return 1
	create_feature_branch || return 1

	print_summary
	log_action "Project initialized successfully: $PROJECT_NAME"

	PROJECT_COMPLETE=1

	open_project_editor
	send_desktop_notification
	open_project_shell || return 1
}

main "$@"
