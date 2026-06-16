#!/usr/bin/env bash
# install.sh
# BashScripts-WIN bootstrap, maintenance, upgrade, and diagnostics utility.
#
# Responsibilities:
#   install.sh:
#     - Install and upgrade command-line dependencies
#     - Authenticate GitHub CLI
#     - Clone and validate the dotfiles repository
#     - Invoke dotfiles-manager.sh
#
#   dotfiles-manager.sh:
#     - Restore, capture, and check managed configuration
#     - Manage bashrc, Git, WSL, VS Code, and Windows Terminal settings
#     - Install managed VS Code extensions
#     - Create native symlinks or safe copy fallbacks

set -Eeuo pipefail
set -o pipefail
IFS=$'\n\t'
umask 077

# ---------- Immutable configuration ----------
readonly DOTFILES_REPO="git@github.com:soyuz43/dotfiles-WIN.git"
readonly DOTFILES_REPO_HTTPS="https://github.com/soyuz43/dotfiles-WIN.git"
readonly DOTFILES_REPO_SSH_URL="ssh://git@github.com/soyuz43/dotfiles-WIN.git"

readonly -a PACKAGES=(
	"Git|git|Git.Git|git|git"
	"GitHub CLI|gh|GitHub.cli|gh|gh"
	"Visual Studio Code|code|Microsoft.VisualStudioCode|vscode|vscode"
	"Windows Terminal|wt|Microsoft.WindowsTerminal|windows-terminal|microsoft-windows-terminal"
	"fzf|fzf|junegunn.fzf|fzf|fzf"
	"ripgrep|rg|BurntSushi.ripgrep.MSVC|ripgrep|ripgrep"
	"fd|fd|sharkdp.fd|fd|fd"
	"bat|bat|sharkdp.bat|bat|bat"
	"delta|delta|dandavison.delta|delta|delta"
	"jq|jq|jqlang.jq|jq|jq"
	"tree|tree|GnuWin32.Tree|tree|tree"
	"shfmt|shfmt|mvdan.shfmt|shfmt|shfmt"
	"ShellCheck|shellcheck|koalaman.shellcheck|shellcheck|shellcheck"
	"Git LFS|git-lfs|GitHub.GitLFS|git-lfs|git-lfs"
	"Node.js LTS|node|OpenJS.NodeJS.LTS|nodejs-lts|nodejs-lts"
	"Python|python|Python.Python.3.12|python|python"
)

readonly -a REQUIRED_CORE_COMMANDS=(
	"chmod"
	"dirname"
	"find"
	"mktemp"
	"rm"
	"tee"
)

# ---------- Runtime globals ----------
MODE="menu"
SCRIPT_PATH="${BASH_SOURCE[0]}"

REPO_DIR=""
DOTFILES_DIR=""
DOTFILES_MANAGER=""

RUN_TIMESTAMP=""
LOG_FILE=""
TEMP_DIR=""
COMMAND_SEQUENCE=0

WINGET_BIN=""
SCOOP_BIN=""
CHOCO_BIN=""
PYTHON_BIN=""

CURRENT_DISPLAY=""
CURRENT_COMMAND=""
CURRENT_WINGET_PACKAGE=""
CURRENT_SCOOP_PACKAGE=""
CURRENT_CHOCO_PACKAGE=""

CAPTURED_OUTPUT=""
LAST_CAPTURE_INFRA_ERROR=""
LAST_MANAGER_REASON=""
LAST_MANAGER_USED=""

PACKAGE_ALREADY_PRESENT_COUNT=0
PACKAGE_COMPLETED_COUNT=0
PACKAGE_PENDING_PATH_COUNT=0
PACKAGE_SKIPPED_COUNT=0
UPGRADE_CANCELLED=0
BOOTSTRAP_RESTART_REQUIRED=0

declare -a PATH_PENDING_PACKAGES=()
declare -a SKIPPED_PACKAGES=()
declare -a SKIPPED_REASONS=()

# ---------- ANSI ----------
BOLD=""
DIM=""
GREEN=""
YELLOW=""
RED=""
BLUE=""
CYAN=""
RESET=""

initialize_colors() {
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
}

# ---------- Logging ----------
log_stream() {
	local console_fd
	local stream_name
	local line
	local clean
	local timestamp
	local ansi_pattern

	console_fd="$1"
	stream_name="$2"
	line=""
	ansi_pattern=$'\033''\[[0-?]*[ -/]*[@-~]'

	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line" >&"$console_fd"

		clean="${line//$'\r'/}"

		while [[ "$clean" =~ $ansi_pattern ]]; do
			clean="${clean/"${BASH_REMATCH[0]}"/}"
		done

		printf -v timestamp '%(%Y-%m-%dT%H:%M:%S%z)T' -1
		printf '[%s] [%s] %s\n' \
			"$timestamp" \
			"$stream_name" \
			"$clean" >>"$LOG_FILE"

		line=""
	done
}

initialize_logging() {
	if [[ -z "${HOME:-}" || ! -d "$HOME" || ! -w "$HOME" ]]; then
		printf '[ERROR] HOME is unset, missing, or not writable: %s\n' \
			"${HOME:-unset}" >&2
		return 1
	fi

	if has_control_characters "$HOME"; then
		printf '[ERROR] HOME contains unsupported control characters.\n' >&2
		return 1
	fi

	printf -v RUN_TIMESTAMP '%(%Y%m%d_%H%M%S)T' -1
	LOG_FILE="$HOME/bashscripts-install_${RUN_TIMESTAMP}.log"

	if ! : >"$LOG_FILE"; then
		printf '[ERROR] Unable to create log file: %s\n' "$LOG_FILE" >&2
		return 1
	fi

	if ! chmod 600 "$LOG_FILE"; then
		printf '[ERROR] Unable to secure log file permissions: %s\n' \
			"$LOG_FILE" >&2
		return 1
	fi

	exec 3>&1
	exec 4>&2
	exec > >(log_stream 3 "STDOUT") 2> >(log_stream 4 "STDERR")
}

# ---------- UI ----------
info() {
	printf '%b[INFO]%b  %s\n' "$BLUE" "$RESET" "$*"
}

ok() {
	printf '%b[ OK ]%b  %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
	printf '%b[WARN]%b  %s\n' "$YELLOW" "$RESET" "$*"
}

err() {
	printf '%b[FAIL]%b  %s\n' "$RED" "$RESET" "$*" >&2
}

verbose() {
	printf '%b[LOG ]%b  %s\n' "$DIM" "$RESET" "$*"
}

separator() {
	printf '%b%s%b\n' \
		"$DIM" \
		"────────────────────────────────────────────────────────────────────────" \
		"$RESET"
}

section() {
	printf '\n'
	separator
	printf '%b%s%b\n' "$BOLD$CYAN" "$*" "$RESET"
	separator
	printf '\n'
}

usage() {
	printf '%s\n' \
		"Usage:" \
		"  bash install.sh" \
		"  bash install.sh --bootstrap" \
		"  bash install.sh --maintain" \
		"  bash install.sh --upgrade" \
		"  bash install.sh --check" \
		"  bash install.sh --help" \
		"" \
		"Modes:" \
		"  --bootstrap   Install dependencies, authenticate GitHub, clone dotfiles, and restore configuration" \
		"  --maintain    Install missing dependencies, restore managed configuration, and print status" \
		"  --upgrade     Upgrade dependencies, restore managed configuration, and print status" \
		"  --check       Run read-only dependency and configuration diagnostics" \
		"  --help        Show this help"
}

trim_whitespace() {
	local value

	value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"

	printf '%s' "$value"
}

confirm() {
	local prompt
	local answer

	prompt="$1"
	answer=""

	printf '%b%s%b\n' "$YELLOW" "$prompt" "$RESET"
	printf '%bResponse%b [y/N]: ' "$BOLD" "$RESET"

	if [[ ! -t 0 ]]; then
		printf '\n'
		verbose "No interactive input is available; defaulting to No."
		return 1
	fi

	if ! IFS= read -r answer; then
		warn "Unable to read a response; defaulting to No."
		return 1
	fi

	if ! answer="$(trim_whitespace "$answer")"; then
		err "Unable to sanitize the response."
		return 1
	fi

	answer="${answer,,}"

	case "$answer" in
	y | yes)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

pause_notice() {
	local prompt

	prompt="$1"

	printf '%b%s%b\n' "$YELLOW" "$prompt" "$RESET"

	if [[ ! -t 0 ]]; then
		verbose "No interactive input is available; continuing automatically."
		return 0
	fi

	printf '%bPress Enter to continue.%b\n' "$BOLD" "$RESET"

	if ! IFS= read -r; then
		warn "Unable to read input; continuing automatically."
	fi
}

choose_mode() {
	local choice

	choice=""

	while :; do
		printf '\n%bBashScripts-WIN%b\n' "$BOLD$CYAN" "$RESET"
		printf '%bChoose an operation.%b\n\n' "$DIM" "$RESET"

		printf '  %b1%b  %-11s %s\n' \
			"$GREEN" "$RESET" \
			"bootstrap" \
			"First-time setup and managed configuration restore"

		printf '  %b2%b  %-11s %s\n' \
			"$BLUE" "$RESET" \
			"maintain" \
			"Install missing dependencies and restore configuration"

		printf '  %b3%b  %-11s %s\n' \
			"$YELLOW" "$RESET" \
			"upgrade" \
			"Upgrade known dependencies and restore configuration"

		printf '  %b4%b  %-11s %s\n' \
			"$CYAN" "$RESET" \
			"check" \
			"Read-only diagnostics"

		printf '  %bq%b  %-11s %s\n\n' \
			"$RED" "$RESET" \
			"quit" \
			"Exit without changes"

		printf '%bSelection%b [1-4/q]: ' "$BOLD" "$RESET"

		if [[ ! -t 0 ]]; then
			printf '\n'
			err "Interactive mode selection requires a terminal."
			printf '%s\n' \
				"Use one of: --bootstrap, --maintain, --upgrade, or --check" >&2
			return 1
		fi

		if ! IFS= read -r choice; then
			err "Unable to read the selected mode."
			return 1
		fi

		if ! choice="$(trim_whitespace "$choice")"; then
			err "Unable to sanitize the selected mode."
			return 1
		fi

		choice="${choice,,}"

		case "$choice" in
		1 | bootstrap)
			MODE="bootstrap"
			return 0
			;;
		2 | maintain)
			MODE="maintain"
			return 0
			;;
		3 | upgrade)
			MODE="upgrade"
			return 0
			;;
		4 | check)
			MODE="check"
			return 0
			;;
		q | quit | exit)
			MODE="quit"
			return 0
			;;
		*)
			warn "Invalid selection: ${choice:-empty}"
			;;
		esac
	done
}

# ---------- Argument parsing ----------
parse_args() {
	if (($# > 1)); then
		err "Only one mode option may be supplied."
		return 2
	fi

	case "${1:-}" in
	"")
		MODE="menu"
		;;
	--bootstrap)
		MODE="bootstrap"
		;;
	--maintain)
		MODE="maintain"
		;;
	--upgrade)
		MODE="upgrade"
		;;
	--check)
		MODE="check"
		;;
	--help | -h)
		MODE="help"
		;;
	*)
		err "Unknown option: $1"
		return 2
		;;
	esac
}

# ---------- Validation and runtime setup ----------
has_control_characters() {
	local value

	value="$1"
	[[ "$value" == *[[:cntrl:]]* ]]
}

validate_path_value() {
	local name
	local value

	name="$1"
	value="$2"

	if [[ -z "$value" ]]; then
		err "$name is empty."
		return 1
	fi

	if has_control_characters "$value"; then
		err "$name contains unsupported control characters."
		return 1
	fi
}

validate_identifier() {
	local name
	local value

	name="$1"
	value="$2"

	if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+/-]*$ ]]; then
		err "$name contains unsupported characters: $value"
		return 1
	fi
}

validate_command_name() {
	local value

	value="$1"
	[[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

resolve_first_command() {
	local candidate
	local path

	for candidate in "$@"; do
		if ! validate_command_name "$candidate"; then
			continue
		fi

		path=""

		if path="$(command -v "$candidate" 2>/dev/null)"; then
			path="${path//$'\r'/}"

			if [[ -n "${path//[[:space:]]/}" ]] &&
				! has_control_characters "$path"; then
				printf '%s' "$path"
				return 0
			fi
		fi
	done

	return 1
}

has_cmd() {
	local command_name

	command_name="$1"

	if ! validate_command_name "$command_name"; then
		return 1
	fi

	command -v "$command_name" >/dev/null 2>&1
}

initialize_paths() {
	local script_dir

	script_dir=""

	if ! validate_path_value "Script path" "$SCRIPT_PATH"; then
		return 1
	fi

	if ! script_dir="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)"; then
		err "Unable to resolve the script directory."
		return 1
	fi

	if ! validate_path_value "Repository directory" "$script_dir"; then
		return 1
	fi

	REPO_DIR="$script_dir"
	DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
	DOTFILES_MANAGER="${DOTFILES_MANAGER:-$REPO_DIR/dotfiles-manager.sh}"

	if ! validate_path_value "Dotfiles directory" "$DOTFILES_DIR"; then
		return 1
	fi

	if ! validate_path_value "Dotfiles manager path" "$DOTFILES_MANAGER"; then
		return 1
	fi
}

validate_core_dependencies() {
	local command_name
	local missing_count

	missing_count=0

	for command_name in "${REQUIRED_CORE_COMMANDS[@]}"; do
		if ! has_cmd "$command_name"; then
			err "Required core command is unavailable: $command_name"
			missing_count=$((missing_count + 1))
		fi
	done

	if ((missing_count > 0)); then
		err "$missing_count required core command(s) are unavailable."
		return 1
	fi
}

initialize_temp_directory() {
	local temp_base

	temp_base="${TMPDIR:-/tmp}"

	if ! validate_path_value "Temporary directory base" "$temp_base"; then
		return 1
	fi

	if [[ ! -d "$temp_base" || ! -w "$temp_base" ]]; then
		err "Temporary directory base is missing or not writable: $temp_base"
		return 1
	fi

	if ! TEMP_DIR="$(mktemp -d "$temp_base/bashscripts-install.XXXXXXXX")"; then
		err "Unable to create a private temporary directory."
		return 1
	fi

	if ! validate_path_value "Temporary directory" "$TEMP_DIR"; then
		return 1
	fi

	verbose "Temporary workspace: $TEMP_DIR"
}

cleanup() {
	if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
		if ! rm -rf -- "$TEMP_DIR"; then
			printf '[WARN] Unable to remove temporary directory: %s\n' \
				"$TEMP_DIR" >&2
		fi
	fi
}

handle_signal() {
	local signal_name

	signal_name="$1"
	err "Interrupted by signal: $signal_name"

	trap - "$signal_name"

	if ! kill -s "$signal_name" "$$"; then
		return 130
	fi
}

install_signal_handlers() {
	trap cleanup EXIT
	trap 'handle_signal INT' INT
	trap 'handle_signal TERM' TERM
	trap 'handle_signal HUP' HUP
}

# ---------- Path handling ----------
to_unix_path() {
	local path
	local drive
	local remainder

	path="$1"

	if ! validate_path_value "Path conversion input" "$path"; then
		return 1
	fi

	if has_cmd cygpath; then
		cygpath -u -- "$path"
		return
	fi

	if [[ "$path" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
		drive="${BASH_REMATCH[1],,}"
		remainder="${BASH_REMATCH[2]//\\//}"
		printf '/%s/%s' "$drive" "$remainder"
		return 0
	fi

	printf '%s' "${path//\\//}"
}

prepend_path_directory() {
	local directory

	directory="$1"

	if [[ -z "$directory" || ! -d "$directory" ]]; then
		return 0
	fi

	if has_control_characters "$directory" || [[ "$directory" == *:* ]]; then
		warn "Ignoring unsafe PATH candidate: $directory"
		return 0
	fi

	case ":$PATH:" in
	*":$directory:"*)
		return 0
		;;
	esac

	PATH="$directory:$PATH"
	export PATH
}

augment_package_paths() {
	local app_data
	local app_data_unix
	local candidate
	local chocolatey_root
	local converted
	local local_app_data
	local local_app_data_unix
	local program_files
	local program_files_unix
	local scoop_root

	app_data="${APPDATA:-}"
	app_data_unix=""
	chocolatey_root="${ChocolateyInstall:-/c/ProgramData/chocolatey}"
	converted=""
	local_app_data="${LOCALAPPDATA:-}"
	local_app_data_unix=""
	program_files="${ProgramFiles:-${PROGRAMFILES:-${ProgramW6432:-}}}"
	program_files_unix=""
	scoop_root="${SCOOP:-$HOME/scoop}"

	if converted="$(to_unix_path "$scoop_root")"; then
		scoop_root="$converted"
	fi

	if converted="$(to_unix_path "$chocolatey_root")"; then
		chocolatey_root="$converted"
	fi

	prepend_path_directory "$scoop_root/shims"
	prepend_path_directory "$chocolatey_root/bin"
	prepend_path_directory "$HOME/.local/bin"

	if [[ -n "${PIPX_BIN_DIR:-}" ]] &&
		converted="$(to_unix_path "$PIPX_BIN_DIR")"; then
		prepend_path_directory "$converted"
	fi

	if [[ -n "$program_files" ]] &&
		! has_control_characters "$program_files" &&
		program_files_unix="$(to_unix_path "$program_files")"; then
		prepend_path_directory "$program_files_unix/GitHub CLI"
		prepend_path_directory "$program_files_unix/Git/cmd"
		prepend_path_directory "$program_files_unix/Git/bin"
	fi

	if [[ -n "$local_app_data" ]] &&
		! has_control_characters "$local_app_data" &&
		local_app_data_unix="$(to_unix_path "$local_app_data")"; then
		prepend_path_directory "$local_app_data_unix/Microsoft/WinGet/Links"
		prepend_path_directory "$local_app_data_unix/Microsoft/WindowsApps"
		prepend_path_directory "$local_app_data_unix/Programs/Microsoft VS Code/bin"

		for candidate in \
			"$local_app_data_unix"/Programs/Python/Python* \
			"$local_app_data_unix"/Programs/Python/Python*/Scripts; do
			prepend_path_directory "$candidate"
		done
	fi

	if [[ -n "$app_data" ]] &&
		! has_control_characters "$app_data" &&
		app_data_unix="$(to_unix_path "$app_data")"; then
		for candidate in "$app_data_unix"/Python/Python*/Scripts; do
			prepend_path_directory "$candidate"
		done
	fi

	if ! hash -r 2>/dev/null; then
		verbose "The shell command cache could not be refreshed."
	fi
}

resolve_package_managers() {
	WINGET_BIN=""
	SCOOP_BIN=""
	CHOCO_BIN=""

	if ! WINGET_BIN="$(resolve_first_command winget winget.exe)"; then
		WINGET_BIN=""
	fi

	if ! SCOOP_BIN="$(resolve_first_command scoop scoop.cmd scoop.ps1)"; then
		SCOOP_BIN=""
	fi

	if ! CHOCO_BIN="$(resolve_first_command choco choco.exe)"; then
		CHOCO_BIN=""
	fi
}

resolve_python() {
	PYTHON_BIN=""

	if ! PYTHON_BIN="$(
		resolve_first_command python python.exe py py.exe python3
	)"; then
		PYTHON_BIN=""
		return 1
	fi
}

augment_python_user_paths() {
	local converted
	local scripts_path

	converted=""
	scripts_path=""

	if ! resolve_python; then
		return 0
	fi

	if scripts_path="$(
		"$PYTHON_BIN" -c '
import sys
import sysconfig

scheme = "nt_user" if sys.platform == "win32" else sysconfig.get_preferred_scheme("user")
print(sysconfig.get_path("scripts", scheme=scheme))
' 2>/dev/null
	)"; then
		scripts_path="${scripts_path//$'\r'/}"

		if [[ -n "$scripts_path" ]] &&
			converted="$(to_unix_path "$scripts_path")"; then
			prepend_path_directory "$converted"
		fi
	fi

	prepend_path_directory "$HOME/.local/bin"

	if [[ -n "${PIPX_BIN_DIR:-}" ]] &&
		converted="$(to_unix_path "$PIPX_BIN_DIR")"; then
		prepend_path_directory "$converted"
	fi

	if ! hash -r 2>/dev/null; then
		verbose "The shell command cache could not be refreshed."
	fi
}

# ---------- Command logging ----------
render_command() {
	local argument
	local rendered
	local quoted

	rendered=""

	for argument in "$@"; do
		printf -v quoted '%q' "$argument"
		rendered+="${rendered:+ }$quoted"
	done

	printf '%s' "$rendered"
}

run_logged_capture() {
	local output_file
	local rendered
	local -a pipeline_status

	CAPTURED_OUTPUT=""
	LAST_CAPTURE_INFRA_ERROR=""
	rendered=""

	if (($# == 0)); then
		err "run_logged_capture received no command."
		LAST_CAPTURE_INFRA_ERROR="No command was supplied."
		return 1
	fi

	COMMAND_SEQUENCE=$((COMMAND_SEQUENCE + 1))
	output_file="$TEMP_DIR/command_${COMMAND_SEQUENCE}.log"

	if ! : >"$output_file"; then
		err "Unable to create command capture file: $output_file"
		LAST_CAPTURE_INFRA_ERROR="Unable to create the command capture file."
		return 1
	fi

	if ! rendered="$(render_command "$@")"; then
		err "Unable to render the command for logging."
		LAST_CAPTURE_INFRA_ERROR="Unable to render the command for logging."
		return 1
	fi

	if [[ -z "${rendered//[[:space:]]/}" ]]; then
		err "Rendered command is unexpectedly empty."
		LAST_CAPTURE_INFRA_ERROR="Rendered command was unexpectedly empty."
		return 1
	fi

	verbose "Executing: $rendered"

	if "$@" 2>&1 | tee "$output_file"; then
		CAPTURED_OUTPUT="$(<"$output_file")"
		CAPTURED_OUTPUT="${CAPTURED_OUTPUT//$'\r'/}"
		verbose "Command completed successfully."
		return 0
	fi

	pipeline_status=("${PIPESTATUS[@]}")
	CAPTURED_OUTPUT="$(<"$output_file")"
	CAPTURED_OUTPUT="${CAPTURED_OUTPUT//$'\r'/}"

	verbose \
		"Command failed: command_status=${pipeline_status[0]:-unknown}, tee_status=${pipeline_status[1]:-unknown}"

	if [[ "${pipeline_status[1]:-1}" != "0" ]]; then
		LAST_CAPTURE_INFRA_ERROR="The output logger failed while capturing the package-manager command."
	fi

	return 1
}

sanitize_inline() {
	local value
	local ansi_pattern

	value="$1"
	ansi_pattern=$'\033''\[[0-?]*[ -/]*[@-~]'

	value="${value//$'\r'/ }"
	value="${value//$'\n'/ }"
	value="${value//$'\t'/ }"

	while [[ "$value" =~ $ansi_pattern ]]; do
		value="${value/"${BASH_REMATCH[0]}"/}"
	done

	while [[ "$value" == *"  "* ]]; do
		value="${value//  / }"
	done

	if ! value="$(trim_whitespace "$value")"; then
		return 1
	fi

	if ((${#value} > 280)); then
		value="${value:0:277}..."
	fi

	printf '%s' "$value"
}

last_nonempty_line() {
	local text
	local line
	local sanitized
	local last

	text="$1"
	line=""
	sanitized=""
	last=""

	while IFS= read -r line; do
		if ! sanitized="$(sanitize_inline "$line")"; then
			continue
		fi

		if [[ -n "${sanitized//[[:space:]]/}" ]]; then
			last="$sanitized"
		fi
	done <<<"$text"

	if [[ -z "$last" ]]; then
		return 1
	fi

	printf '%s' "$last"
}

# ---------- Package metadata ----------
parse_package_record() {
	local record
	local extra
	local IFS

	record="$1"
	extra=""
	IFS='|'

	CURRENT_DISPLAY=""
	CURRENT_COMMAND=""
	CURRENT_WINGET_PACKAGE=""
	CURRENT_SCOOP_PACKAGE=""
	CURRENT_CHOCO_PACKAGE=""

	read -r \
		CURRENT_DISPLAY \
		CURRENT_COMMAND \
		CURRENT_WINGET_PACKAGE \
		CURRENT_SCOOP_PACKAGE \
		CURRENT_CHOCO_PACKAGE \
		extra <<<"$record"

	if [[ -n "$extra" ]]; then
		err "Invalid package record with excess fields: $record"
		return 1
	fi

	if [[ ! "$CURRENT_DISPLAY" =~ ^[[:alnum:]][[:alnum:][:space:].+_()-]*$ ]]; then
		err "Invalid package display name: $CURRENT_DISPLAY"
		return 1
	fi

	if ! validate_command_name "$CURRENT_COMMAND"; then
		err "Invalid package command name: $CURRENT_COMMAND"
		return 1
	fi

	if ! validate_identifier \
		"Winget package identifier" \
		"$CURRENT_WINGET_PACKAGE"; then
		return 1
	fi

	if ! validate_identifier \
		"Scoop package identifier" \
		"$CURRENT_SCOOP_PACKAGE"; then
		return 1
	fi

	if ! validate_identifier \
		"Chocolatey package identifier" \
		"$CURRENT_CHOCO_PACKAGE"; then
		return 1
	fi
}

manager_display_name() {
	case "$1" in
	winget)
		printf '%s' "Winget"
		;;
	scoop)
		printf '%s' "Scoop"
		;;
	chocolatey)
		printf '%s' "Chocolatey"
		;;
	*)
		printf '%s' "Unknown manager"
		return 1
		;;
	esac
}

operation_reported_no_change() {
	local action
	local output

	action="$1"
	output="${CAPTURED_OUTPUT,,}"

	case "$action" in
	install)
		[[ "$output" == *"already installed"* ||
			"$output" == *"package is already installed"* ||
			"$output" == *"is already installed"* ]]
		;;
	upgrade)
		[[ "$output" == *"no available upgrade found"* ||
			"$output" == *"no applicable upgrade found"* ||
			"$output" == *"no newer package versions are available"* ||
			"$output" == *"latest version is already installed"* ||
			"$output" == *"the latest version"* ||
			"$output" == *"0 packages upgraded"* ]]
		;;
	*)
		return 1
		;;
	esac
}

classify_manager_failure() {
	local manager
	local manager_name
	local action
	local package_name
	local normalized
	local diagnostic

	manager="$1"
	action="$2"
	package_name="$3"
	manager_name=""
	normalized="${CAPTURED_OUTPUT,,}"
	diagnostic=""

	if ! manager_name="$(manager_display_name "$manager")"; then
		manager_name="$manager"
	fi

	if [[ -n "$LAST_CAPTURE_INFRA_ERROR" ]]; then
		LAST_MANAGER_REASON="$LAST_CAPTURE_INFRA_ERROR"
		return 0
	fi

	if ! diagnostic="$(last_nonempty_line "$CAPTURED_OUTPUT")"; then
		diagnostic="No diagnostic output was returned."
	fi

	if [[ "$normalized" =~ (network|internet|connection|connectivity|proxy|timed[[:space:]-]?out|timeout|tls|ssl|certificate|0x8a15000f|source.*(failed|unavailable|missing|unreachable)|unable[[:space:]]to[[:space:]]reach) ]]; then
		LAST_MANAGER_REASON="$manager_name could not reach or validate its package source while attempting to $action '$package_name'. Diagnostic: $diagnostic"
		return 0
	fi

	if [[ "$normalized" =~ (no[[:space:]]package[[:space:]]found|couldn.t[[:space:]]find|not[[:space:]]found|unable[[:space:]]to[[:space:]]find|manifest.*not.*found|package.*does[[:space:]]not[[:space:]]exist) ]]; then
		LAST_MANAGER_REASON="$manager_name could not locate package '$package_name'. Diagnostic: $diagnostic"
		return 0
	fi

	if [[ "$normalized" =~ (access[[:space:]]is[[:space:]]denied|permission[[:space:]]denied|administrator|elevat|unauthorized|0x80070005) ]]; then
		LAST_MANAGER_REASON="$manager_name was denied permission while attempting to $action '$package_name'. Diagnostic: $diagnostic"
		return 0
	fi

	if [[ "$normalized" =~ (checksum|hash[[:space:]]mismatch|verification[[:space:]]failed|signature.*invalid) ]]; then
		LAST_MANAGER_REASON="$manager_name rejected package '$package_name' during integrity verification. Diagnostic: $diagnostic"
		return 0
	fi

	LAST_MANAGER_REASON="$manager_name failed to $action package '$package_name'. Diagnostic: $diagnostic"
}

attempt_package_operation() {
	local manager
	local action
	local binary
	local package_name
	local manager_name

	manager="$1"
	action="$2"
	binary=""
	package_name=""
	manager_name=""
	LAST_MANAGER_REASON=""
	LAST_MANAGER_USED=""

	case "$manager" in
	winget)
		binary="$WINGET_BIN"
		package_name="$CURRENT_WINGET_PACKAGE"
		;;
	scoop)
		binary="$SCOOP_BIN"
		package_name="$CURRENT_SCOOP_PACKAGE"
		;;
	chocolatey)
		binary="$CHOCO_BIN"
		package_name="$CURRENT_CHOCO_PACKAGE"
		;;
	*)
		LAST_MANAGER_REASON="Unsupported package manager: $manager"
		return 1
		;;
	esac

	if ! manager_name="$(manager_display_name "$manager")"; then
		LAST_MANAGER_REASON="Unable to resolve the package-manager display name."
		return 1
	fi

	if [[ -z "$binary" ]]; then
		LAST_MANAGER_REASON="$manager_name executable was not found on PATH."
		return 1
	fi

	if ! validate_path_value "$manager_name executable path" "$binary"; then
		LAST_MANAGER_REASON="$manager_name executable path failed validation."
		return 1
	fi

	if ! validate_identifier \
		"$manager_name package identifier" \
		"$package_name"; then
		LAST_MANAGER_REASON="$manager_name package identifier failed validation."
		return 1
	fi

	info "$manager_name: attempting to $action $CURRENT_DISPLAY"

	case "$manager:$action" in
	winget:install)
		if run_logged_capture \
			"$binary" install \
			--id "$package_name" \
			--exact \
			--source winget \
			--accept-package-agreements \
			--accept-source-agreements \
			--disable-interactivity; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	winget:upgrade)
		if run_logged_capture \
			"$binary" upgrade \
			--id "$package_name" \
			--exact \
			--source winget \
			--accept-package-agreements \
			--accept-source-agreements \
			--disable-interactivity; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	scoop:install)
		if run_logged_capture "$binary" install "$package_name"; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	scoop:upgrade)
		if run_logged_capture "$binary" update "$package_name"; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	chocolatey:install)
		if run_logged_capture \
			"$binary" install "$package_name" \
			--yes \
			--no-progress; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	chocolatey:upgrade)
		if run_logged_capture \
			"$binary" upgrade "$package_name" \
			--yes \
			--no-progress; then
			LAST_MANAGER_USED="$manager_name"
			return 0
		fi
		;;
	*)
		LAST_MANAGER_REASON="Unsupported package operation: $manager:$action"
		return 1
		;;
	esac

	if operation_reported_no_change "$action"; then
		LAST_MANAGER_USED="$manager_name"
		ok "$CURRENT_DISPLAY requires no $action action according to $manager_name."
		return 0
	fi

	classify_manager_failure "$manager" "$action" "$package_name"
	return 1
}

record_named_pending_path_package() {
	local display_name

	display_name="$1"
	PATH_PENDING_PACKAGES+=("$display_name")
	PACKAGE_PENDING_PATH_COUNT=$((PACKAGE_PENDING_PATH_COUNT + 1))
}

record_pending_path_package() {
	record_named_pending_path_package "$CURRENT_DISPLAY"
}

record_named_skipped_package() {
	local display_name
	local reason
	local summary

	display_name="$1"
	shift
	summary=""

	for reason in "$@"; do
		summary+="${summary:+; }$reason"
	done

	SKIPPED_PACKAGES+=("$display_name")
	SKIPPED_REASONS+=("$summary")
	PACKAGE_SKIPPED_COUNT=$((PACKAGE_SKIPPED_COUNT + 1))
}

record_skipped_package() {
	shift
	record_named_skipped_package "$CURRENT_DISPLAY" "$@"
}

prompt_package_skip() {
	local action
	local reason

	action="$1"
	shift

	section "Package skipped: $CURRENT_DISPLAY"

	err "No configured package manager could complete the $action operation for $CURRENT_DISPLAY."

	printf '%bFailure details:%b\n' "$BOLD" "$RESET"

	for reason in "$@"; do
		printf '  • %s\n' "$reason"
	done

	printf '\n'
	warn "$CURRENT_DISPLAY will be skipped; processing will continue with the next package."
	pause_notice "Review the package-manager failures above."
}

run_package_action() {
	local requested_action
	local effective_action
	local reason
	local -a failure_reasons

	requested_action="$1"
	effective_action="$requested_action"
	failure_reasons=()

	if [[ "$requested_action" != "install" &&
		"$requested_action" != "upgrade" ]]; then
		err "Unsupported package action: $requested_action"
		return 1
	fi

	section "$CURRENT_DISPLAY"

	if [[ "$requested_action" == "install" ]] &&
		has_cmd "$CURRENT_COMMAND"; then
		ok "$CURRENT_DISPLAY is already available."
		PACKAGE_ALREADY_PRESENT_COUNT=$((PACKAGE_ALREADY_PRESENT_COUNT + 1))
		return 0
	fi

	if [[ "$requested_action" == "upgrade" ]] &&
		! has_cmd "$CURRENT_COMMAND"; then
		warn "$CURRENT_DISPLAY is missing; switching this package from upgrade to install."
		effective_action="install"
	fi

	if attempt_package_operation "winget" "$effective_action"; then
		augment_package_paths
		PACKAGE_COMPLETED_COUNT=$((PACKAGE_COMPLETED_COUNT + 1))

		if has_cmd "$CURRENT_COMMAND"; then
			ok "$CURRENT_DISPLAY completed through $LAST_MANAGER_USED."
		else
			warn "$LAST_MANAGER_USED reported success, but '$CURRENT_COMMAND' is not visible in this shell."
			warn "A new terminal session may be required before the command appears on PATH."
			record_pending_path_package
		fi

		return 0
	fi

	reason="Winget: $LAST_MANAGER_REASON"
	failure_reasons+=("$reason")

	warn "Winget could not complete the current $CURRENT_DISPLAY operation."
	info "Trying per-package fallback managers for $CURRENT_DISPLAY only."

	if attempt_package_operation "scoop" "$effective_action"; then
		augment_package_paths
		PACKAGE_COMPLETED_COUNT=$((PACKAGE_COMPLETED_COUNT + 1))

		if has_cmd "$CURRENT_COMMAND"; then
			ok "$CURRENT_DISPLAY completed through $LAST_MANAGER_USED."
		else
			warn "$LAST_MANAGER_USED reported success, but '$CURRENT_COMMAND' is not visible in this shell."
			warn "A new terminal session may be required before the command appears on PATH."
			record_pending_path_package
		fi

		return 0
	fi

	reason="Scoop: $LAST_MANAGER_REASON"
	failure_reasons+=("$reason")

	if attempt_package_operation "chocolatey" "$effective_action"; then
		augment_package_paths
		PACKAGE_COMPLETED_COUNT=$((PACKAGE_COMPLETED_COUNT + 1))

		if has_cmd "$CURRENT_COMMAND"; then
			ok "$CURRENT_DISPLAY completed through $LAST_MANAGER_USED."
		else
			warn "$LAST_MANAGER_USED reported success, but '$CURRENT_COMMAND' is not visible in this shell."
			warn "A new terminal session may be required before the command appears on PATH."
			record_pending_path_package
		fi

		return 0
	fi

	reason="Chocolatey: $LAST_MANAGER_REASON"
	failure_reasons+=("$reason")

	record_skipped_package "$effective_action" "${failure_reasons[@]}"
	prompt_package_skip "$effective_action" "${failure_reasons[@]}"
}

reset_package_outcomes() {
	PACKAGE_ALREADY_PRESENT_COUNT=0
	PACKAGE_COMPLETED_COUNT=0
	PACKAGE_PENDING_PATH_COUNT=0
	PACKAGE_SKIPPED_COUNT=0

	PATH_PENDING_PACKAGES=()
	SKIPPED_PACKAGES=()
	SKIPPED_REASONS=()
}

# ---------- Python-managed dependencies ----------
python_pipx_module_available() {
	if [[ -z "$PYTHON_BIN" ]] && ! resolve_python; then
		return 1
	fi

	"$PYTHON_BIN" -m pipx --version >/dev/null 2>&1
}

record_pipx_failure() {
	local reason

	reason="$1"
	err "$reason"
	record_named_skipped_package "pipx" "$reason"
}

ensure_pipx() {
	local action
	local diagnostic
	local install_required

	action="$1"
	diagnostic=""
	install_required=0

	case "$action" in
	install | upgrade) ;;
	*)
		err "Unsupported pipx action: $action"
		return 1
		;;
	esac

	section "pipx"
	augment_package_paths
	augment_python_user_paths

	if ! resolve_python; then
		if package_waiting_for_path_refresh "Python"; then
			warn "Python was installed but is not visible in this Git Bash session."
			warn "pipx installation is deferred until the next run."
			record_named_pending_path_package "pipx"
			return 0
		fi

		record_pipx_failure "Python is unavailable; pipx cannot be installed."
		return 0
	fi

	if [[ "$action" == "install" ]] && has_cmd pipx; then
		ok "pipx is already available."
		PACKAGE_ALREADY_PRESENT_COUNT=$((PACKAGE_ALREADY_PRESENT_COUNT + 1))
		return 0
	fi

	if python_pipx_module_available; then
		if [[ "$action" == "upgrade" ]]; then
			install_required=1
		fi
	else
		if has_cmd pipx; then
			ok "pipx is available through an external package manager; leaving it unchanged."
			PACKAGE_ALREADY_PRESENT_COUNT=$((PACKAGE_ALREADY_PRESENT_COUNT + 1))
			return 0
		fi

		install_required=1
	fi

	if ((install_required != 0)); then
		if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
			info "Python pip is unavailable; attempting to initialize it with ensurepip."

			if ! run_logged_capture "$PYTHON_BIN" -m ensurepip --upgrade; then
				if ! diagnostic="$(last_nonempty_line "$CAPTURED_OUTPUT")"; then
					diagnostic="No diagnostic output was returned."
				fi

				record_pipx_failure "Unable to initialize pip. Diagnostic: $diagnostic"
				return 0
			fi
		fi

		info "Installing pipx through the active Python interpreter."

		if ! run_logged_capture \
			"$PYTHON_BIN" -m pip install --user --upgrade pipx; then
			if ! diagnostic="$(last_nonempty_line "$CAPTURED_OUTPUT")"; then
				diagnostic="No diagnostic output was returned."
			fi

			record_pipx_failure "Python could not install pipx. Diagnostic: $diagnostic"
			return 0
		fi
	fi

	if ! run_logged_capture "$PYTHON_BIN" -m pipx ensurepath; then
		warn "pipx is installed, but its persistent PATH update could not be confirmed."
		record_named_pending_path_package "pipx"
	else
		augment_python_user_paths
	fi

	PACKAGE_COMPLETED_COUNT=$((PACKAGE_COMPLETED_COUNT + 1))

	if has_cmd pipx; then
		ok "pipx is available in this Git Bash session."
		return 0
	fi

	if python_pipx_module_available; then
		warn "pipx is installed, but the 'pipx' command is not visible in this shell yet."
		warn "A new Git Bash session may be required."

		if ! package_waiting_for_path_refresh "pipx"; then
			record_named_pending_path_package "pipx"
		fi

		return 0
	fi

	record_pipx_failure "pipx installation completed without producing a usable module or command."
}

# ---------- Winget availability ----------
prompt_missing_winget() {
	section "Winget is not installed"

	warn "The Winget command was not found on PATH."

	printf '%s\n' \
		"To install or repair Winget from an elevated PowerShell window:" \
		"" \
		"  1. Open the Start menu and type: PowerShell" \
		"  2. Right-click Windows PowerShell and select: Run as administrator" \
		"  3. Run these commands:" \
		"" \
		"     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force" \
		"     Install-PackageProvider -Name NuGet -Force" \
		"     Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force" \
		"     Import-Module Microsoft.WinGet.Client" \
		"     Repair-WinGetPackageManager -AllUsers" \
		"" \
		"  4. Close and reopen Git Bash, then rerun this script." \
		"" \
		"This run will continue. Scoop and Chocolatey will be considered only as" \
		"per-package fallbacks, and only for the package currently being processed."

	pause_notice "Winget installation instructions have been displayed."
}

prepare_package_management() {
	resolve_package_managers

	if [[ -n "$WINGET_BIN" ]]; then
		ok "Winget detected: $WINGET_BIN"
		return 0
	fi

	prompt_missing_winget
}

# ---------- Versions and dependency status ----------
first_nonempty_line() {
	local text
	local line
	local sanitized

	text="$1"
	line=""
	sanitized=""

	while IFS= read -r line; do
		if ! sanitized="$(sanitize_inline "$line")"; then
			continue
		fi

		if [[ -n "${sanitized//[[:space:]]/}" ]]; then
			printf '%s' "$sanitized"
			return 0
		fi
	done <<<"$text"

	return 1
}

cmd_path() {
	local command_name
	local path

	command_name="$1"
	path=""

	if ! validate_command_name "$command_name"; then
		return 1
	fi

	if ! path="$(command -v "$command_name" 2>/dev/null)"; then
		return 1
	fi

	path="${path//$'\r'/}"

	if [[ -z "${path//[[:space:]]/}" ]] ||
		has_control_characters "$path"; then
		return 1
	fi

	printf '%s' "$path"
}

cmd_version() {
	local command_name
	local output
	local line
	local version

	command_name="$1"
	output=""
	line=""
	version=""

	if ! validate_command_name "$command_name"; then
		return 1
	fi

	case "$command_name" in
	tree | wt)
		printf '%s command available' "$command_name"
		return 0
		;;
	shellcheck)
		if ! output="$("$command_name" --version 2>/dev/null)"; then
			return 1
		fi

		while IFS= read -r line; do
			line="${line//$'\r'/}"

			if [[ "$line" =~ ^version:[[:space:]]*(.+)$ ]]; then
				version="${BASH_REMATCH[1]}"
				break
			fi
		done <<<"$output"

		if [[ -z "$version" ]]; then
			return 1
		fi

		printf 'ShellCheck %s' "$version"
		;;
	*)
		if ! output="$("$command_name" --version 2>/dev/null)"; then
			return 1
		fi

		if ! version="$(first_nonempty_line "$output")"; then
			return 1
		fi

		printf '%s' "$version"
		;;
	esac
}

print_pipx_status() {
	local path
	local version

	path=""
	version=""

	augment_python_user_paths

	if has_cmd pipx; then
		if ! path="$(cmd_path pipx)"; then
			path="path unavailable"
		fi

		if ! version="$(cmd_version pipx)"; then
			version="version unavailable"
		fi

		printf '%-16s %b%-10s%b %s | %s\n' \
			"pipx" \
			"$GREEN" \
			"AVAILABLE" \
			"$RESET" \
			"$path" \
			"$version"
		return 0
	fi

	if resolve_python && python_pipx_module_available; then
		if ! version="$("$PYTHON_BIN" -m pipx --version 2>/dev/null)"; then
			version="version unavailable"
		fi

		if ! version="$(sanitize_inline "$version")"; then
			version="version unavailable"
		fi

		printf '%-16s %b%-10s%b %s | %s\n' \
			"pipx" \
			"$YELLOW" \
			"MODULE" \
			"$RESET" \
			"$PYTHON_BIN -m pipx" \
			"$version"
		return 0
	fi

	printf '%-16s %b%-10s%b %s\n' \
		"pipx" \
		"$YELLOW" \
		"MISSING" \
		"$RESET" \
		"Installed through Python pip during maintenance or bootstrap"
}

print_dependency_status() {
	local record
	local path
	local version
	local details

	printf '%b%-16s %-10s %s%b\n' \
		"$BOLD" \
		"Command" \
		"Status" \
		"Details" \
		"$RESET"

	printf '%-16s %-10s %s\n' \
		"────────────────" \
		"──────────" \
		"────────────────────────────────────────"

	for record in "${PACKAGES[@]}"; do
		if ! parse_package_record "$record"; then
			return 1
		fi

		path=""
		version=""
		details=""

		if has_cmd "$CURRENT_COMMAND"; then
			if ! path="$(cmd_path "$CURRENT_COMMAND")"; then
				path="path unavailable"
			fi

			if ! version="$(cmd_version "$CURRENT_COMMAND")"; then
				version="version unavailable"
			fi

			details="$path | $version"

			printf '%-16s %b%-10s%b %s\n' \
				"$CURRENT_COMMAND" \
				"$GREEN" \
				"AVAILABLE" \
				"$RESET" \
				"$details"
		else
			printf '%-16s %b%-10s%b Winget ID: %s\n' \
				"$CURRENT_COMMAND" \
				"$YELLOW" \
				"MISSING" \
				"$RESET" \
				"$CURRENT_WINGET_PACKAGE"
		fi
	done

	if ! print_pipx_status; then
		return 1
	fi

	if [[ -n "$WINGET_BIN" ]]; then
		version=""

		if ! version="$("$WINGET_BIN" --version 2>/dev/null)"; then
			version="version unavailable"
		fi

		if ! version="$(sanitize_inline "$version")"; then
			version="version unavailable"
		fi

		printf '%-16s %b%-10s%b %s | %s\n' \
			"winget" \
			"$GREEN" \
			"AVAILABLE" \
			"$RESET" \
			"$WINGET_BIN" \
			"$version"
	else
		printf '%-16s %b%-10s%b %s\n' \
			"winget" \
			"$YELLOW" \
			"MISSING" \
			"$RESET" \
			"Not found on PATH"
	fi
}

# ---------- Package workflows ----------
run_install_missing() {
	local record

	section "Install missing dependencies"
	reset_package_outcomes

	for record in "${PACKAGES[@]}"; do
		if ! parse_package_record "$record"; then
			return 1
		fi

		if ! run_package_action "install"; then
			err "Unexpected package-processing failure: $CURRENT_DISPLAY"
			return 1
		fi
	done

	if ! ensure_pipx "install"; then
		return 1
	fi
}

run_upgrade_known() {
	local record

	section "Upgrade workflow dependencies"
	warn "Only dependencies declared by BashScripts-WIN will be upgraded."

	if ! confirm "Continue with the dependency upgrade workflow?"; then
		warn "Upgrade workflow cancelled."
		UPGRADE_CANCELLED=1
		return 0
	fi

	reset_package_outcomes

	for record in "${PACKAGES[@]}"; do
		if ! parse_package_record "$record"; then
			return 1
		fi

		if ! run_package_action "upgrade"; then
			err "Unexpected package-processing failure: $CURRENT_DISPLAY"
			return 1
		fi
	done

	if ! ensure_pipx "upgrade"; then
		return 1
	fi
}

print_package_outcome_summary() {
	local index

	section "Package operation summary"

	printf '  Already available:   %d\n' "$PACKAGE_ALREADY_PRESENT_COUNT"
	printf '  Operations completed:%4d\n' "$PACKAGE_COMPLETED_COUNT"
	printf '  PATH refresh needed: %d\n' "$PACKAGE_PENDING_PATH_COUNT"
	printf '  Skipped:             %d\n' "$PACKAGE_SKIPPED_COUNT"

	if ((PACKAGE_PENDING_PATH_COUNT > 0)); then
		printf '\n%bCommands requiring a new terminal session:%b\n' \
			"$YELLOW" \
			"$RESET"

		for index in "${!PATH_PENDING_PACKAGES[@]}"; do
			printf '  • %s\n' "${PATH_PENDING_PACKAGES[$index]}"
		done
	fi

	if ((PACKAGE_SKIPPED_COUNT > 0)); then
		printf '\n%bSkipped package details:%b\n' "$RED" "$RESET"

		for index in "${!SKIPPED_PACKAGES[@]}"; do
			printf '  • %s\n' "${SKIPPED_PACKAGES[$index]}"
			printf '    %s\n' "${SKIPPED_REASONS[$index]}"
		done
	fi
}

# ---------- Script permissions ----------
chmod_scripts() {
	local file
	local first_line
	local failed
	local file_list

	failed=0
	file_list="$TEMP_DIR/chmod-script-files.list"

	info "Updating executable permissions for repository scripts."

	if ! find "$REPO_DIR" \
		-maxdepth 1 \
		-type f \
		-print0 >"$file_list"; then
		err "Unable to enumerate repository scripts."
		return 1
	fi

	while IFS= read -r -d '' file; do
		first_line=""

		if ! IFS= read -r first_line <"$file" &&
			[[ -z "$first_line" ]]; then
			continue
		fi

		if [[ "$first_line" != '#!'* ]]; then
			continue
		fi

		if ! chmod +x -- "$file"; then
			err "Unable to make script executable: $file"
			failed=$((failed + 1))
		fi
	done <"$file_list"

	if ((failed > 0)); then
		err "$failed script permission update(s) failed."
		return 1
	fi

	ok "Script permissions updated."
}

# ---------- GitHub authentication ----------
package_waiting_for_path_refresh() {
	local expected_package
	local pending_package

	expected_package="$1"

	for pending_package in "${PATH_PENDING_PACKAGES[@]}"; do
		if [[ "$pending_package" == "$expected_package" ]]; then
			return 0
		fi
	done

	return 1
}

print_bootstrap_resume_notice() {
	local repository_command
	local resume_command

	if has_cmd make && [[ -f "$REPO_DIR/Makefile" ]]; then
		resume_command="make new"
	else
		resume_command="bash install.sh --bootstrap"
	fi

	printf -v repository_command 'cd %q' "$REPO_DIR"

	section "Bootstrap phase 1 completed"

	if ! has_cmd gh &&
		package_waiting_for_path_refresh "GitHub CLI"; then
		printf '%bGitHub CLI was installed, but this Git Bash session cannot see it yet.%b\n' \
			"$YELLOW" \
			"$RESET"
	fi

	if ! has_cmd git &&
		package_waiting_for_path_refresh "Git"; then
		printf '%bGit was installed, but this Git Bash session cannot see it yet.%b\n' \
			"$YELLOW" \
			"$RESET"
	fi

	printf '\n'
	printf '%s\n' \
		"1. Close this Git Bash window." \
		"2. Open Git Bash again." \
		"3. Return to the BashScripts repository:" \
		"   $repository_command" \
		"4. Run:" \
		"   $resume_command" \
		"" \
		"Already completed steps will be detected and skipped."

	if [[ "$resume_command" != "make new" ]]; then
		printf '\n%bNote:%b GNU Make is not currently available, so the direct bootstrap command is shown.\n' \
			"$DIM" \
			"$RESET"
	fi

	printf '\n%bLog saved to:%b %s\n' \
		"$BOLD" \
		"$RESET" \
		"$LOG_FILE"
}

require_bootstrap_commands() {
	local command_name
	local display_name
	local missing_count
	local pending_count

	missing_count=0
	pending_count=0
	BOOTSTRAP_RESTART_REQUIRED=0

	for command_name in git gh; do
		if has_cmd "$command_name"; then
			continue
		fi

		case "$command_name" in
		git)
			display_name="Git"
			;;
		gh)
			display_name="GitHub CLI"
			;;
		esac

		missing_count=$((missing_count + 1))

		if package_waiting_for_path_refresh "$display_name"; then
			pending_count=$((pending_count + 1))
			warn "$display_name was installed but is not visible in this Git Bash session."
		else
			err "Bootstrap requires '$command_name', but it remains unavailable."
		fi
	done

	if ((missing_count == 0)); then
		return 0
	fi

	if ((pending_count == missing_count)); then
		BOOTSTRAP_RESTART_REQUIRED=1
		return 2
	fi

	err "Bootstrap cannot continue because one or more required commands are unavailable."
	return 1
}

configure_github_git_credentials() {
	if ! has_cmd gh; then
		err "GitHub CLI is unavailable; Git credential integration cannot be configured."
		return 1
	fi

	verbose "Configuring Git to use GitHub CLI credentials."

	if ! gh auth setup-git; then
		err "GitHub CLI could not configure Git credential integration."
		return 1
	fi

	ok "GitHub Git credential integration is configured."
}

ensure_github_auth() {
	if ! has_cmd gh; then
		err "GitHub CLI is unavailable; authentication cannot continue."
		return 1
	fi

	verbose "Checking GitHub CLI authentication status."

	if gh auth status >/dev/null 2>&1; then
		ok "GitHub CLI is authenticated."

		if ! configure_github_git_credentials; then
			return 1
		fi

		return 0
	fi

	warn "GitHub CLI is not authenticated."

	printf '%b%s%b\n' \
		"$DIM" \
		"GitHub CLI will open its browser-based authentication flow. A security key can be used if GitHub requests it." \
		"$RESET"

	if ! confirm "Authenticate GitHub CLI now?"; then
		err "Bootstrap stopped before GitHub authentication."
		return 1
	fi

	verbose "Executing GitHub browser authentication flow."

	if ! gh auth login \
		--hostname github.com \
		--git-protocol ssh \
		--web; then
		err "GitHub CLI authentication command failed."
		return 1
	fi

	if ! gh auth status >/dev/null 2>&1; then
		err "GitHub CLI still reports an unauthenticated state."
		return 1
	fi

	ok "GitHub CLI authentication completed."

	if ! configure_github_git_credentials; then
		return 1
	fi
}

print_github_status() {
	if ! has_cmd gh; then
		warn "GitHub CLI is missing; authentication status is unavailable."
		return 0
	fi

	if gh auth status >/dev/null 2>&1; then
		ok "GitHub CLI is authenticated."
	else
		warn "GitHub CLI is not authenticated."
	fi
}

# ---------- Dotfiles repository ----------
is_expected_dotfiles_remote() {
	local actual

	actual="$1"
	actual="${actual%/}"
	actual="${actual%.git}"

	case "$actual" in
	"${DOTFILES_REPO%.git}" | "${DOTFILES_REPO_HTTPS%.git}" | "${DOTFILES_REPO_SSH_URL%.git}")
		return 0
		;;
	*)
		return 1
		;;
	esac
}

dotfiles_remote_ok() {
	local actual

	actual=""

	if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
		err "Dotfiles directory is not a Git repository: $DOTFILES_DIR"
		return 1
	fi

	if ! actual="$(
		git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null
	)"; then
		actual=""
	fi

	actual="${actual//$'\r'/}"

	if [[ -n "$actual" ]] && is_expected_dotfiles_remote "$actual"; then
		ok "Dotfiles origin is valid: $actual"
		return 0
	fi

	warn "The existing dotfiles repository has an unexpected origin."
	printf '  Expected: %s\n' "$DOTFILES_REPO"
	printf '  Actual:   %s\n' "${actual:-none}"

	if confirm "Continue using the existing dotfiles repository?"; then
		return 0
	fi

	err "Bootstrap stopped because the dotfiles origin was not accepted."
	return 1
}

clone_dotfiles_via_ssh() {
	info "Cloning dotfiles repository through SSH."

	if git clone -- "$DOTFILES_REPO" "$DOTFILES_DIR"; then
		return 0
	fi

	warn "The SSH clone attempt failed."
	return 1
}

clone_dotfiles_via_https() {
	info "Trying the authenticated HTTPS clone as a fallback."

	if git clone -- "$DOTFILES_REPO_HTTPS" "$DOTFILES_DIR"; then
		return 0
	fi

	err "The authenticated HTTPS clone attempt also failed."
	return 1
}

clone_dotfiles() {
	if [[ -d "$DOTFILES_DIR/.git" ]]; then
		ok "Dotfiles repository already exists: $DOTFILES_DIR"

		if ! dotfiles_remote_ok; then
			return 1
		fi

		return 0
	fi

	if [[ -e "$DOTFILES_DIR" ]]; then
		err "Refusing to overwrite an existing non-repository path: $DOTFILES_DIR"
		return 1
	fi

	if ! has_cmd git; then
		err "Git is unavailable; dotfiles cannot be cloned."
		return 1
	fi

	if clone_dotfiles_via_ssh; then
		ok "Dotfiles cloned to: $DOTFILES_DIR"
	else
		if [[ -e "$DOTFILES_DIR" ]]; then
			if [[ -d "$DOTFILES_DIR/.git" ]]; then
				err "The failed SSH clone left a partial Git repository: $DOTFILES_DIR"
				return 1
			fi

			if ! rm -rf -- "$DOTFILES_DIR"; then
				err "Unable to remove the failed SSH clone directory: $DOTFILES_DIR"
				return 1
			fi
		fi

		if ! clone_dotfiles_via_https; then
			return 1
		fi

		ok "Dotfiles cloned to: $DOTFILES_DIR"
	fi

	if ! dotfiles_remote_ok; then
		return 1
	fi
}

print_dotfiles_repository_status() {
	local actual

	actual=""

	if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
		warn "Dotfiles repository was not found: $DOTFILES_DIR"
		return 0
	fi

	ok "Dotfiles repository exists: $DOTFILES_DIR"

	if ! has_cmd git; then
		warn "Git is unavailable; the dotfiles origin cannot be checked."
		return 0
	fi

	if ! actual="$(
		git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null
	)"; then
		warn "Dotfiles origin could not be read."
		return 0
	fi

	actual="${actual//$'\r'/}"

	if is_expected_dotfiles_remote "$actual"; then
		ok "Dotfiles origin is valid: $actual"
	else
		warn "Dotfiles origin differs from the configured repository: ${actual:-none}"
	fi
}

# ---------- Dotfiles manager integration ----------
validate_dotfiles_manager() {
	if [[ -z "$DOTFILES_MANAGER" ]]; then
		err "Dotfiles manager path is empty."
		return 1
	fi

	if has_control_characters "$DOTFILES_MANAGER"; then
		err "Dotfiles manager path contains unsupported control characters."
		return 1
	fi

	if [[ ! -f "$DOTFILES_MANAGER" ]]; then
		err "Dotfiles manager was not found: $DOTFILES_MANAGER"
		return 1
	fi

	if [[ ! -r "$DOTFILES_MANAGER" ]]; then
		err "Dotfiles manager is not readable: $DOTFILES_MANAGER"
		return 1
	fi

	if ! bash -n "$DOTFILES_MANAGER"; then
		err "Dotfiles manager contains a Bash syntax error: $DOTFILES_MANAGER"
		return 1
	fi
}

run_dotfiles_manager() {
	local manager_mode

	manager_mode="$1"

	case "$manager_mode" in
	--restore | --status) ;;
	*)
		err "Unsupported dotfiles-manager mode: $manager_mode"
		return 1
		;;
	esac

	if ! validate_dotfiles_manager; then
		return 1
	fi

	verbose "Executing dotfiles manager: $DOTFILES_MANAGER $manager_mode"

	if ! DOTFILES_DIR="$DOTFILES_DIR" \
		bash "$DOTFILES_MANAGER" "$manager_mode"; then
		err "Dotfiles manager failed in mode: $manager_mode"
		return 1
	fi
}

restore_managed_dotfiles() {
	section "Managed configuration restore"

	if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
		err "Managed configuration cannot be restored because the dotfiles repository is unavailable."
		return 1
	fi

	if ! run_dotfiles_manager --restore; then
		err "One or more managed configuration items could not be restored."
		return 1
	fi

	ok "Managed configuration restore completed."
}

restore_managed_dotfiles_if_available() {
	if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
		warn "Dotfiles repository is unavailable; managed configuration restore was skipped."
		return 0
	fi

	if ! restore_managed_dotfiles; then
		return 1
	fi
}

print_managed_dotfiles_status() {
	if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
		warn "Dotfiles repository is unavailable; managed configuration status was skipped."
		return 0
	fi

	if ! run_dotfiles_manager --status; then
		err "Managed configuration status check failed."
		return 1
	fi
}

# ---------- Diagnostics ----------
print_restart_note() {
	printf '\n%bNext step:%b open a new Git Bash session to refresh Windows-installed command paths.\n' \
		"$BOLD" \
		"$RESET"

	printf '%s\n' \
		"To load the restored Bash configuration in this session only, run:"
	printf '  source %q\n' "$HOME/.bashrc"
}

run_status() {
	section "Dependency status"

	if ! print_dependency_status; then
		return 1
	fi

	section "GitHub authentication"
	print_github_status

	section "Dotfiles repository"
	print_dotfiles_repository_status

	section "Managed configuration status"

	if ! print_managed_dotfiles_status; then
		return 1
	fi
}

# ---------- Modes ----------
mode_bootstrap() {
	local bootstrap_command_status

	bootstrap_command_status=0

	section "Bootstrap"

	printf '%b%s%b\n' \
		"$DIM" \
		"First-time setup: dependencies, GitHub authentication, dotfiles clone, and managed configuration restore." \
		"$RESET"

	if ! prepare_package_management; then
		return 1
	fi

	if ! run_install_missing; then
		return 1
	fi

	if require_bootstrap_commands; then
		:
	else
		bootstrap_command_status=$?

		print_package_outcome_summary

		if ((bootstrap_command_status == 2)) &&
			((BOOTSTRAP_RESTART_REQUIRED != 0)) &&
			((PACKAGE_SKIPPED_COUNT == 0)); then
			print_bootstrap_resume_notice
		else
			err "Bootstrap phase 1 could not be completed. Review: $LOG_FILE"
		fi

		return 1
	fi

	section "Script permissions"

	if ! chmod_scripts; then
		return 1
	fi

	section "GitHub authentication"

	if ! ensure_github_auth; then
		return 1
	fi

	section "Dotfiles clone"

	if ! clone_dotfiles; then
		return 1
	fi

	if ! restore_managed_dotfiles; then
		return 1
	fi

	if ! run_status; then
		return 1
	fi

	print_package_outcome_summary
	print_restart_note

	if ((PACKAGE_SKIPPED_COUNT > 0)); then
		err "Bootstrap completed with skipped packages. Review: $LOG_FILE"
		return 1
	fi

	ok "Bootstrap complete."
}

mode_maintain() {
	if ! prepare_package_management; then
		return 1
	fi

	if ! run_install_missing; then
		return 1
	fi

	section "Script permissions"

	if ! chmod_scripts; then
		return 1
	fi

	if ! restore_managed_dotfiles_if_available; then
		return 1
	fi

	if ! run_status; then
		return 1
	fi

	print_package_outcome_summary

	if ((PACKAGE_SKIPPED_COUNT > 0)); then
		err "Maintenance completed with skipped packages. Review: $LOG_FILE"
		return 1
	fi

	ok "Maintenance complete."
}

mode_upgrade() {
	UPGRADE_CANCELLED=0

	if ! prepare_package_management; then
		return 1
	fi

	if ! run_upgrade_known; then
		return 1
	fi

	section "Script permissions"

	if ! chmod_scripts; then
		return 1
	fi

	if ! restore_managed_dotfiles_if_available; then
		return 1
	fi

	if ! run_status; then
		return 1
	fi

	if ((UPGRADE_CANCELLED == 0)); then
		print_package_outcome_summary
	fi

	if ((PACKAGE_SKIPPED_COUNT > 0)); then
		err "Upgrade completed with skipped packages. Review: $LOG_FILE"
		return 1
	fi

	if ((UPGRADE_CANCELLED != 0)); then
		warn "Upgrade was cancelled; diagnostics, permissions, and managed configuration maintenance completed."
		return 0
	fi

	ok "Upgrade complete."
}

mode_check() {
	if ! run_status; then
		return 1
	fi

	ok "Diagnostics complete."
}

# ---------- Main ----------
main() {
	initialize_colors

	if ! initialize_logging; then
		return 1
	fi

	if ! initialize_paths; then
		return 1
	fi

	if ! validate_core_dependencies; then
		return 1
	fi

	if ! initialize_temp_directory; then
		return 1
	fi

	install_signal_handlers
	augment_package_paths
	resolve_package_managers

	if ! parse_args "$@"; then
		usage
		return 2
	fi

	if [[ "$MODE" == "help" ]]; then
		usage
		return 0
	fi

	if [[ "$MODE" == "menu" ]]; then
		if ! choose_mode; then
			return 1
		fi
	fi

	if [[ "$MODE" == "quit" ]]; then
		info "No changes were made."
		return 0
	fi

	section "BashScripts-WIN"

	info "Mode: $MODE"
	info "Repository: $REPO_DIR"
	info "Dotfiles repository: $DOTFILES_DIR"
	info "Dotfiles manager: $DOTFILES_MANAGER"
	info "Verbose log: $LOG_FILE"

	case "$MODE" in
	bootstrap)
		if ! mode_bootstrap; then
			return 1
		fi
		;;
	maintain)
		if ! mode_maintain; then
			return 1
		fi
		;;
	upgrade)
		if ! mode_upgrade; then
			return 1
		fi
		;;
	check)
		if ! mode_check; then
			return 1
		fi
		;;
	*)
		err "Unhandled mode: $MODE"
		return 1
		;;
	esac

	printf '\n'
	ok "Log saved to: $LOG_FILE"
}

main "$@"
