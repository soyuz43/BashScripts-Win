#!/usr/bin/env bash
# dotfiles-manager.sh
#
# Single source of truth for user configuration.
#
# install.sh should remain responsible for:
#   - Installing package dependencies
#   - Authenticating GitHub CLI
#   - Cloning the dotfiles repository
#
# This script is responsible for:
#   - Capturing configuration into the dotfiles repository
#   - Restoring configuration from the dotfiles repository
#   - Creating native Windows symlinks when permitted
#   - Falling back to safe file copies when symlinks are unavailable
#   - Capturing and restoring VS Code extensions
#   - Reporting configuration status
#
# Recommended install.sh integration after clone_dotfiles:
#
#   if ! bash "$REPO_DIR/dotfiles-manager.sh" --restore; then
#       err "One or more dotfiles could not be restored"
#       return 1
#   fi
#
# Usage:
#   bash dotfiles-manager.sh
#   bash dotfiles-manager.sh --capture
#   bash dotfiles-manager.sh --restore
#   bash dotfiles-manager.sh --status
#   bash dotfiles-manager.sh --help
#
# Repository layout:
#   ~/dotfiles/
#   ├── bashrc
#   ├── gitconfig
#   ├── wslconfig
#   ├── vscode/
#   │   ├── settings.json
#   │   └── extensions.txt
#   └── windows-terminal/
#       └── settings.json
#
# Optional environment overrides:
#   DOTFILES_DIR
#   VSCODE_SETTINGS_TARGET
#   WINDOWS_TERMINAL_SETTINGS_TARGET

set -Eeuo pipefail
set -o pipefail
IFS=$'\n\t'
umask 077

# ---------- ANSI ----------
BOLD=""
DIM=""
GREEN=""
YELLOW=""
RED=""
BLUE=""
CYAN=""
RESET=""

# ---------- Runtime configuration ----------
MODE="menu"

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
VSCODE_SETTINGS_TARGET_OVERRIDE="${VSCODE_SETTINGS_TARGET:-}"
WINDOWS_TERMINAL_SETTINGS_TARGET_OVERRIDE="${WINDOWS_TERMINAL_SETTINGS_TARGET:-}"

VSCODE_SETTINGS_TARGET=""
WINDOWS_TERMINAL_SETTINGS_TARGET=""

VSCODE_DIR=""
VSCODE_SETTINGS_SOURCE=""
VSCODE_EXTENSIONS_SOURCE=""
WINDOWS_TERMINAL_SETTINGS_SOURCE=""

POWERSHELL_BIN=""
CODE_BIN=""
TEMP_DIR=""
RUN_TIMESTAMP=""

CURRENT_LABEL=""
CURRENT_SOURCE=""
CURRENT_TARGET=""
CURRENT_REQUIRED=""

CAPTURE_SUCCESS_COUNT=0
CAPTURE_SKIPPED_COUNT=0
CAPTURE_FAILED_COUNT=0

RESTORE_SUCCESS_COUNT=0
RESTORE_SKIPPED_COUNT=0
RESTORE_FAILED_COUNT=0

STATUS_MATCH_COUNT=0
STATUS_DIFFERENT_COUNT=0
STATUS_MISSING_COUNT=0

declare -a MANAGED_FILES=()

# ---------- UI ----------
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

section() {
	printf '\n%b%s%b\n' \
		"$DIM" \
		"────────────────────────────────────────────────────────────────────────" \
		"$RESET"

	printf '%b%s%b\n' "$BOLD$CYAN" "$*" "$RESET"

	printf '%b%s%b\n\n' \
		"$DIM" \
		"────────────────────────────────────────────────────────────────────────" \
		"$RESET"
}

usage() {
	printf '%s\n' \
		"Usage:" \
		"  bash dotfiles-manager.sh" \
		"  bash dotfiles-manager.sh --capture" \
		"  bash dotfiles-manager.sh --restore" \
		"  bash dotfiles-manager.sh --status" \
		"  bash dotfiles-manager.sh --help" \
		"" \
		"Modes:" \
		"  --capture   Capture local configuration into the dotfiles repository" \
		"  --restore   Restore configuration from the dotfiles repository" \
		"  --status    Compare local configuration with the repository" \
		"  --help      Show this help" \
		"" \
		"Managed configuration:" \
		"  ~/.bashrc" \
		"  ~/.gitconfig" \
		"  ~/.wslconfig" \
		"  VS Code settings.json" \
		"  VS Code extensions" \
		"  Windows Terminal settings.json"
}

choose_mode() {
	local choice

	choice=""

	while :; do
		section "Dotfiles manager"

		printf '  %b1%b  %-10s %s\n' \
			"$GREEN" "$RESET" \
			"capture" \
			"Save this machine's configuration to the repository"

		printf '  %b2%b  %-10s %s\n' \
			"$BLUE" "$RESET" \
			"restore" \
			"Restore repository configuration to this machine"

		printf '  %b3%b  %-10s %s\n' \
			"$CYAN" "$RESET" \
			"status" \
			"Compare local configuration with the repository"

		printf '  %bq%b  %-10s %s\n\n' \
			"$RED" "$RESET" \
			"quit" \
			"Exit without changes"

		printf '%bSelection%b [1-3/q]: ' "$BOLD" "$RESET"

		if [[ ! -t 0 ]]; then
			err "Interactive mode requires a terminal."
			return 1
		fi

		if ! IFS= read -r choice; then
			err "Unable to read the selected mode."
			return 1
		fi

		choice="${choice#"${choice%%[![:space:]]*}"}"
		choice="${choice%"${choice##*[![:space:]]}"}"
		choice="${choice,,}"

		case "$choice" in
		1 | capture)
			MODE="capture"
			return 0
			;;
		2 | restore)
			MODE="restore"
			return 0
			;;
		3 | status)
			MODE="status"
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

# ---------- Validation ----------
has_control_characters() {
	local value

	value="$1"
	[[ "$value" == *[[:cntrl:]]* ]]
}

validate_path() {
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

	if [[ "$value" == *"|"* ]]; then
		err "$name contains the reserved record delimiter: |"
		return 1
	fi
}

validate_required_value() {
	local value

	value="$1"
	[[ "$value" == "required" || "$value" == "optional" ]]
}

validate_extension_id() {
	local extension_id

	extension_id="$1"
	[[ "$extension_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

parse_args() {
	if (($# > 1)); then
		err "Only one mode may be specified."
		return 2
	fi

	case "${1:-}" in
	"")
		MODE="menu"
		;;
	--capture)
		MODE="capture"
		;;
	--restore | --bootstrap)
		MODE="restore"
		;;
	--status | --check)
		MODE="status"
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

# ---------- Path conversion ----------
to_unix_path() {
	local path
	local drive
	local remainder

	path="$1"

	if ! validate_path "Windows path" "$path"; then
		return 1
	fi

	if command -v cygpath >/dev/null 2>&1; then
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

to_windows_path() {
	local path
	local drive
	local remainder

	path="$1"

	if ! validate_path "Unix path" "$path"; then
		return 1
	fi

	if command -v cygpath >/dev/null 2>&1; then
		cygpath -w -- "$path"
		return
	fi

	if [[ "$path" =~ ^/([A-Za-z])/(.*)$ ]]; then
		drive="${BASH_REMATCH[1]^^}"
		remainder="${BASH_REMATCH[2]//\//\\}"
		printf '%s:\\%s' "$drive" "$remainder"
		return 0
	fi

	printf '%s' "$path"
}

# ---------- Target detection ----------
detect_vscode_settings_target() {
	local app_data
	local app_data_unix
	local candidate

	app_data="${APPDATA:-}"
	app_data_unix=""
	candidate=""

	if [[ -n "$VSCODE_SETTINGS_TARGET_OVERRIDE" ]]; then
		printf '%s' "$VSCODE_SETTINGS_TARGET_OVERRIDE"
		return 0
	fi

	if [[ -e "$HOME/.vscode/settings.json" ]]; then
		printf '%s' "$HOME/.vscode/settings.json"
		return 0
	fi

	if [[ -n "$app_data" ]] &&
		! has_control_characters "$app_data" &&
		app_data_unix="$(to_unix_path "$app_data")"; then

		for candidate in \
			"$app_data_unix/Code/User/settings.json" \
			"$app_data_unix/Code - Insiders/User/settings.json"; do
			if [[ -e "$candidate" || -d "${candidate%/*}" ]]; then
				printf '%s' "$candidate"
				return 0
			fi
		done

		printf '%s' "$app_data_unix/Code/User/settings.json"
		return 0
	fi

	printf '%s' "$HOME/.vscode/settings.json"
}

detect_windows_terminal_settings_target() {
	local local_app_data
	local local_app_data_unix
	local candidate

	local_app_data="${LOCALAPPDATA:-}"
	local_app_data_unix=""
	candidate=""

	if [[ -n "$WINDOWS_TERMINAL_SETTINGS_TARGET_OVERRIDE" ]]; then
		printf '%s' "$WINDOWS_TERMINAL_SETTINGS_TARGET_OVERRIDE"
		return 0
	fi

	if [[ -z "$local_app_data" ]] ||
		has_control_characters "$local_app_data"; then
		return 1
	fi

	if ! local_app_data_unix="$(to_unix_path "$local_app_data")"; then
		return 1
	fi

	for candidate in \
		"$local_app_data_unix/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" \
		"$local_app_data_unix/Packages/Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe/LocalState/settings.json" \
		"$local_app_data_unix/Microsoft/Windows Terminal/settings.json"; do
		if [[ -e "$candidate" || -d "${candidate%/*}" ]]; then
			printf '%s' "$candidate"
			return 0
		fi
	done

	printf '%s' \
		"$local_app_data_unix/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
}

# ---------- Runtime initialization ----------
initialize_paths() {
	if [[ -z "${HOME:-}" ]]; then
		err "HOME is not set."
		return 1
	fi

	if ! validate_path "HOME" "$HOME"; then
		return 1
	fi

	if ! validate_path "Dotfiles directory" "$DOTFILES_DIR"; then
		return 1
	fi

	if ! VSCODE_SETTINGS_TARGET="$(detect_vscode_settings_target)"; then
		err "Unable to determine the VS Code settings target."
		return 1
	fi

	if ! validate_path "VS Code settings target" "$VSCODE_SETTINGS_TARGET"; then
		return 1
	fi

	if ! WINDOWS_TERMINAL_SETTINGS_TARGET="$(
		detect_windows_terminal_settings_target
	)"; then
		WINDOWS_TERMINAL_SETTINGS_TARGET=""
	fi

	if [[ -n "$WINDOWS_TERMINAL_SETTINGS_TARGET" ]] &&
		! validate_path \
			"Windows Terminal settings target" \
			"$WINDOWS_TERMINAL_SETTINGS_TARGET"; then
		return 1
	fi

	VSCODE_DIR="$DOTFILES_DIR/vscode"
	VSCODE_SETTINGS_SOURCE="$VSCODE_DIR/settings.json"
	VSCODE_EXTENSIONS_SOURCE="$VSCODE_DIR/extensions.txt"
	WINDOWS_TERMINAL_SETTINGS_SOURCE="$DOTFILES_DIR/windows-terminal/settings.json"

	MANAGED_FILES=(
		"Bash configuration|$DOTFILES_DIR/bashrc|$HOME/.bashrc|required"
		"PowerShell profile|$DOTFILES_DIR/powershell/profile.ps1|$HOME/Documents/PowerShell/profile.ps1|optional"
		"Git configuration|$DOTFILES_DIR/gitconfig|$HOME/.gitconfig|optional"
		"WSL configuration|$DOTFILES_DIR/wslconfig|$HOME/.wslconfig|optional"
		"VS Code settings|$VSCODE_SETTINGS_SOURCE|$VSCODE_SETTINGS_TARGET|optional"
	)

	if [[ -n "$WINDOWS_TERMINAL_SETTINGS_TARGET" ]]; then
		MANAGED_FILES+=(
			"Windows Terminal settings|$WINDOWS_TERMINAL_SETTINGS_SOURCE|$WINDOWS_TERMINAL_SETTINGS_TARGET|optional"
		)
	fi
}

initialize_temp_directory() {
	local temp_base

	temp_base="${TMPDIR:-/tmp}"

	if ! validate_path "Temporary directory base" "$temp_base"; then
		return 1
	fi

	if [[ ! -d "$temp_base" || ! -w "$temp_base" ]]; then
		err "Temporary directory base is unavailable: $temp_base"
		return 1
	fi

	if ! TEMP_DIR="$(mktemp -d "$temp_base/dotfiles-manager.XXXXXXXX")"; then
		err "Unable to create the temporary workspace."
		return 1
	fi
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

parse_file_record() {
	local record
	local extra
	local IFS

	record="$1"
	extra=""
	IFS='|'

	CURRENT_LABEL=""
	CURRENT_SOURCE=""
	CURRENT_TARGET=""
	CURRENT_REQUIRED=""

	read -r \
		CURRENT_LABEL \
		CURRENT_SOURCE \
		CURRENT_TARGET \
		CURRENT_REQUIRED \
		extra <<<"$record"

	if [[ -n "$extra" ]]; then
		err "Managed-file record contains excess fields: $record"
		return 1
	fi

	if [[ -z "$CURRENT_LABEL" ]]; then
		err "Managed-file record has an empty label."
		return 1
	fi

	if ! validate_path "$CURRENT_LABEL source" "$CURRENT_SOURCE"; then
		return 1
	fi

	if ! validate_path "$CURRENT_LABEL target" "$CURRENT_TARGET"; then
		return 1
	fi

	if ! validate_required_value "$CURRENT_REQUIRED"; then
		err "Invalid requirement value for $CURRENT_LABEL: $CURRENT_REQUIRED"
		return 1
	fi
}

# ---------- Command discovery ----------
resolve_command() {
	local candidate
	local command_path

	command_path=""

	for candidate in "$@"; do
		if command_path="$(command -v "$candidate" 2>/dev/null)"; then
			command_path="${command_path//$'\r'/}"

			if [[ -n "${command_path//[[:space:]]/}" ]] &&
				! has_control_characters "$command_path"; then
				printf '%s' "$command_path"
				return 0
			fi
		fi
	done

	return 1
}

resolve_powershell() {
	if ! POWERSHELL_BIN="$(
		resolve_command powershell.exe pwsh.exe powershell pwsh
	)"; then
		POWERSHELL_BIN=""
	fi
}

resolve_code_cli() {
	local local_app_data
	local local_app_data_unix
	local candidate

	CODE_BIN=""

	if CODE_BIN="$(
		resolve_command code code.cmd code.exe code-insiders code-insiders.cmd
	)"; then
		return 0
	fi

	local_app_data="${LOCALAPPDATA:-}"
	local_app_data_unix=""

	if [[ -n "$local_app_data" ]] &&
		! has_control_characters "$local_app_data" &&
		local_app_data_unix="$(to_unix_path "$local_app_data")"; then

		for candidate in \
			"$local_app_data_unix/Programs/Microsoft VS Code/bin/code" \
			"$local_app_data_unix/Programs/Microsoft VS Code/bin/code.cmd" \
			"$local_app_data_unix/Programs/Microsoft VS Code Insiders/bin/code-insiders" \
			"$local_app_data_unix/Programs/Microsoft VS Code Insiders/bin/code-insiders.cmd"; do
			if [[ -f "$candidate" && -x "$candidate" ]]; then
				CODE_BIN="$candidate"
				return 0
			fi
		done
	fi

	for candidate in \
		"/c/Program Files/Microsoft VS Code/bin/code" \
		"/c/Program Files/Microsoft VS Code/bin/code.cmd" \
		"/c/Program Files/Microsoft VS Code Insiders/bin/code-insiders" \
		"/c/Program Files/Microsoft VS Code Insiders/bin/code-insiders.cmd"; do
		if [[ -f "$candidate" && -x "$candidate" ]]; then
			CODE_BIN="$candidate"
			return 0
		fi
	done

	return 1
}

# ---------- Backup handling ----------
next_backup_path() {
	local target
	local candidate
	local suffix

	target="$1"
	suffix=0

	printf -v RUN_TIMESTAMP '%(%Y%m%d_%H%M%S)T' -1
	candidate="$target.local-backup.$RUN_TIMESTAMP"

	while [[ -e "$candidate" || -L "$candidate" ]]; do
		suffix=$((suffix + 1))
		candidate="$target.local-backup.${RUN_TIMESTAMP}_$suffix"
	done

	printf '%s' "$candidate"
}

backup_existing_target() {
	local target
	local backup

	target="$1"
	backup=""

	if [[ ! -e "$target" && ! -L "$target" ]]; then
		return 0
	fi

	if [[ -d "$target" && ! -L "$target" ]]; then
		err "Refusing to replace a directory with a managed file: $target"
		return 1
	fi

	if ! backup="$(next_backup_path "$target")"; then
		err "Unable to determine a backup path for: $target"
		return 1
	fi

	if ! mv -- "$target" "$backup"; then
		err "Unable to back up: $target"
		return 1
	fi

	ok "Backup created: $backup"
}

# ---------- Native symlink and copy fallback ----------
create_native_windows_symlink() {
	local source
	local target
	local source_windows
	local target_windows

	source="$1"
	target="$2"
	source_windows=""
	target_windows=""

	if [[ -z "$POWERSHELL_BIN" ]]; then
		return 1
	fi

	if ! source_windows="$(to_windows_path "$source")"; then
		err "Unable to convert the symlink source to a Windows path."
		return 1
	fi

	if ! target_windows="$(to_windows_path "$target")"; then
		err "Unable to convert the symlink target to a Windows path."
		return 1
	fi

	# PowerShell variables are intentionally protected from Bash expansion.
	# shellcheck disable=SC2016
	if ! DOTFILES_SYMLINK_SOURCE="$source_windows" \
		DOTFILES_SYMLINK_TARGET="$target_windows" \
		"$POWERSHELL_BIN" \
		-NoLogo \
		-NoProfile \
		-NonInteractive \
		-Command '
			$ErrorActionPreference = "Stop"

			$source = [Environment]::GetEnvironmentVariable(
				"DOTFILES_SYMLINK_SOURCE",
				"Process"
			)

			$target = [Environment]::GetEnvironmentVariable(
				"DOTFILES_SYMLINK_TARGET",
				"Process"
			)

			if (
				[string]::IsNullOrWhiteSpace($source) -or
				[string]::IsNullOrWhiteSpace($target)
			) {
				throw "Symlink source or target is empty."
			}

			New-Item `
				-ItemType SymbolicLink `
				-Path $target `
				-Target $source `
				-Force |
				Out-Null
		'; then
		return 1
	fi

	if [[ ! -e "$target" && ! -L "$target" ]]; then
		return 1
	fi

	cmp -s -- "$source" "$target"
}

remove_failed_target() {
	local target

	target="$1"

	if [[ ! -e "$target" && ! -L "$target" ]]; then
		return 0
	fi

	if [[ -d "$target" && ! -L "$target" ]]; then
		err "Refusing to remove an unexpected directory: $target"
		return 1
	fi

	if ! rm -f -- "$target"; then
		err "Unable to remove the failed target: $target"
		return 1
	fi
}

create_copy_fallback() {
	local source
	local target
	local target_directory
	local temporary_file

	source="$1"
	target="$2"
	target_directory="${target%/*}"
	temporary_file=""

	if ! mkdir -p -- "$target_directory"; then
		err "Unable to create target directory: $target_directory"
		return 1
	fi

	if ! temporary_file="$(
		mktemp "$target_directory/.dotfiles-copy.XXXXXXXX"
	)"; then
		err "Unable to create a temporary fallback file."
		return 1
	fi

	if ! cp -L -- "$source" "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to stage the copy fallback."
		return 1
	fi

	if ! chmod 600 "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to secure the copy fallback."
		return 1
	fi

	if ! mv -f -- "$temporary_file" "$target"; then
		rm -f -- "$temporary_file"
		err "Unable to create the copy fallback: $target"
		return 1
	fi

	ok "Copy fallback created: $target"
}

# ---------- File comparison ----------
managed_file_matches() {
	local source
	local target

	source="$1"
	target="$2"

	if [[ ! -f "$source" || ! -f "$target" ]]; then
		return 1
	fi

	cmp -s -- "$source" "$target"
}

target_is_link() {
	local target

	target="$1"
	[[ -L "$target" ]]
}

# ---------- Capture ----------
atomic_copy_to_repository() {
	local source
	local destination
	local destination_directory
	local temporary_file

	source="$1"
	destination="$2"
	destination_directory="${destination%/*}"
	temporary_file=""

	if [[ ! -f "$source" ]]; then
		return 2
	fi

	if [[ ! -r "$source" ]]; then
		err "Local source file is not readable: $source"
		return 1
	fi

	if ! mkdir -p -- "$destination_directory"; then
		err "Unable to create repository directory: $destination_directory"
		return 1
	fi

	if ! temporary_file="$(
		mktemp "$destination_directory/.capture.XXXXXXXX"
	)"; then
		err "Unable to create a temporary repository file."
		return 1
	fi

	if ! cp -L -- "$source" "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to capture: $source"
		return 1
	fi

	if ! chmod 600 "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to secure the captured file."
		return 1
	fi

	if [[ -f "$destination" ]] &&
		cmp -s -- "$temporary_file" "$destination"; then
		rm -f -- "$temporary_file"
		ok "Repository copy is already current: $destination"
		return 0
	fi

	if ! mv -f -- "$temporary_file" "$destination"; then
		rm -f -- "$temporary_file"
		err "Unable to update repository file: $destination"
		return 1
	fi

	ok "Captured: $source -> $destination"
}

capture_managed_file() {
	local label
	local source
	local target
	local required
	local copy_status

	label="$1"
	source="$2"
	target="$3"
	required="$4"
	copy_status=0

	info "Capturing $label"

	if atomic_copy_to_repository "$target" "$source"; then
		CAPTURE_SUCCESS_COUNT=$((CAPTURE_SUCCESS_COUNT + 1))
		return 0
	else
		copy_status=$?
	fi

	if ((copy_status == 2)); then
		if [[ "$required" == "required" ]]; then
			err "$label is required but does not exist locally: $target"
			CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
			return 1
		fi

		warn "$label does not exist locally; skipping capture: $target"
		CAPTURE_SKIPPED_COUNT=$((CAPTURE_SKIPPED_COUNT + 1))
		return 0
	fi

	CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
	return 1
}

capture_managed_files() {
	local record
	local failed

	failed=0

	section "Capture configuration files"

	for record in "${MANAGED_FILES[@]}"; do
		if ! parse_file_record "$record"; then
			return 1
		fi

		if ! capture_managed_file \
			"$CURRENT_LABEL" \
			"$CURRENT_SOURCE" \
			"$CURRENT_TARGET" \
			"$CURRENT_REQUIRED"; then
			failed=$((failed + 1))
		fi
	done

	if ((failed > 0)); then
		err "$failed managed configuration file(s) could not be captured."
		return 1
	fi
}

# ---------- Restore ----------
restore_managed_file() {
	local label
	local source
	local target
	local required
	local target_directory

	label="$1"
	source="$2"
	target="$3"
	required="$4"
	target_directory="${target%/*}"

	info "Restoring $label"

	if [[ ! -f "$source" ]]; then
		if [[ "$required" == "required" ]]; then
			err "$label is required but missing from the repository: $source"
			RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
			return 1
		fi

		warn "$label is not present in the repository; skipping: $source"
		RESTORE_SKIPPED_COUNT=$((RESTORE_SKIPPED_COUNT + 1))
		return 0
	fi

	if [[ ! -r "$source" ]]; then
		err "$label source is not readable: $source"
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	if managed_file_matches "$source" "$target"; then
		if target_is_link "$target"; then
			ok "$label is already linked and current."
		else
			ok "$label already matches the repository copy."
		fi

		RESTORE_SUCCESS_COUNT=$((RESTORE_SUCCESS_COUNT + 1))
		return 0
	fi

	if ! mkdir -p -- "$target_directory"; then
		err "Unable to create target directory: $target_directory"
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	if ! backup_existing_target "$target"; then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	if create_native_windows_symlink "$source" "$target"; then
		ok "$label linked: $target -> $source"
		RESTORE_SUCCESS_COUNT=$((RESTORE_SUCCESS_COUNT + 1))
		return 0
	fi

	warn "A native Windows symlink could not be created for $label."
	warn "Using a file copy fallback."

	if ! remove_failed_target "$target"; then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	if ! create_copy_fallback "$source" "$target"; then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	RESTORE_SUCCESS_COUNT=$((RESTORE_SUCCESS_COUNT + 1))
}

restore_managed_files() {
	local record
	local failed

	failed=0

	section "Restore configuration files"

	for record in "${MANAGED_FILES[@]}"; do
		if ! parse_file_record "$record"; then
			return 1
		fi

		if ! restore_managed_file \
			"$CURRENT_LABEL" \
			"$CURRENT_SOURCE" \
			"$CURRENT_TARGET" \
			"$CURRENT_REQUIRED"; then
			failed=$((failed + 1))
		fi
	done

	if ((failed > 0)); then
		err "$failed managed configuration file(s) could not be restored."
		return 1
	fi
}

# ---------- VS Code extension inventory ----------
normalize_extension_inventory() {
	local input_file
	local output_file
	local normalized_file
	local line
	local extension_id

	input_file="$1"
	output_file="$2"
	normalized_file="$TEMP_DIR/extensions-normalized.txt"

	if ! : >"$normalized_file"; then
		err "Unable to initialize the normalized extension inventory."
		return 1
	fi

	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line//$'\r'/}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"

		if [[ -z "$line" || "$line" == \#* ]]; then
			continue
		fi

		extension_id="${line%%@*}"
		extension_id="${extension_id,,}"

		if ! validate_extension_id "$extension_id"; then
			err "Invalid VS Code extension identifier: $line"
			return 1
		fi

		printf '%s\n' "$extension_id" >>"$normalized_file"
	done <"$input_file"

	if ! LC_ALL=C sort -u -- "$normalized_file" >"$output_file"; then
		err "Unable to sort the VS Code extension inventory."
		return 1
	fi
}

capture_vscode_extensions() {
	local raw_file
	local normalized_file
	local destination_directory
	local temporary_file

	raw_file="$TEMP_DIR/vscode-extensions-raw.txt"
	normalized_file="$TEMP_DIR/vscode-extensions-normalized.txt"
	destination_directory="${VSCODE_EXTENSIONS_SOURCE%/*}"
	temporary_file=""

	section "Capture VS Code extensions"

	if ! resolve_code_cli; then
		warn "VS Code CLI was not found; extension capture was skipped."
		CAPTURE_SKIPPED_COUNT=$((CAPTURE_SKIPPED_COUNT + 1))
		return 0
	fi

	info "VS Code CLI: $CODE_BIN"

	if ! "$CODE_BIN" --list-extensions >"$raw_file"; then
		err "Unable to retrieve the installed VS Code extension list."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if ! normalize_extension_inventory "$raw_file" "$normalized_file"; then
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if ! mkdir -p -- "$destination_directory"; then
		err "Unable to create the VS Code dotfiles directory."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if ! temporary_file="$(
		mktemp "$destination_directory/.extensions.XXXXXXXX"
	)"; then
		err "Unable to create the temporary extension inventory."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if ! cp -- "$normalized_file" "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to stage the extension inventory."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if ! chmod 600 "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to secure the extension inventory."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	if [[ -f "$VSCODE_EXTENSIONS_SOURCE" ]] &&
		cmp -s -- "$temporary_file" "$VSCODE_EXTENSIONS_SOURCE"; then
		rm -f -- "$temporary_file"
		ok "VS Code extension inventory is already current."
		CAPTURE_SUCCESS_COUNT=$((CAPTURE_SUCCESS_COUNT + 1))
		return 0
	fi

	if ! mv -f -- "$temporary_file" "$VSCODE_EXTENSIONS_SOURCE"; then
		rm -f -- "$temporary_file"
		err "Unable to update the VS Code extension inventory."
		CAPTURE_FAILED_COUNT=$((CAPTURE_FAILED_COUNT + 1))
		return 1
	fi

	ok "Extension inventory saved: $VSCODE_EXTENSIONS_SOURCE"
	CAPTURE_SUCCESS_COUNT=$((CAPTURE_SUCCESS_COUNT + 1))
}

load_installed_extensions() {
	local raw_file
	local normalized_file

	raw_file="$1"
	normalized_file="$TEMP_DIR/installed-extensions-normalized.txt"

	if ! "$CODE_BIN" --list-extensions >"$raw_file"; then
		err "Unable to retrieve currently installed VS Code extensions."
		return 1
	fi

	if ! normalize_extension_inventory "$raw_file" "$normalized_file"; then
		return 1
	fi

	if ! mv -f -- "$normalized_file" "$raw_file"; then
		err "Unable to finalize the installed-extension inventory."
		return 1
	fi
}

install_vscode_extensions() {
	local desired_file
	local installed_file
	local extension_id
	local installed_now
	local already_installed
	local failed
	declare -A installed_extensions

	desired_file="$TEMP_DIR/desired-extensions.txt"
	installed_file="$TEMP_DIR/installed-extensions.txt"
	installed_now=0
	already_installed=0
	failed=0

	section "Restore VS Code extensions"

	if [[ ! -f "$VSCODE_EXTENSIONS_SOURCE" ]]; then
		warn "VS Code extension inventory is missing; skipping extension restore."
		RESTORE_SKIPPED_COUNT=$((RESTORE_SKIPPED_COUNT + 1))
		return 0
	fi

	if ! resolve_code_cli; then
		warn "VS Code CLI was not found; extension restore was skipped."
		warn "Install VS Code or add its 'code' command to PATH, then rerun restore."
		RESTORE_SKIPPED_COUNT=$((RESTORE_SKIPPED_COUNT + 1))
		return 0
	fi

	info "VS Code CLI: $CODE_BIN"

	if ! normalize_extension_inventory \
		"$VSCODE_EXTENSIONS_SOURCE" \
		"$desired_file"; then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	if ! load_installed_extensions "$installed_file"; then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	installed_extensions=()

	while IFS= read -r extension_id || [[ -n "$extension_id" ]]; do
		if [[ -n "$extension_id" ]]; then
			installed_extensions["${extension_id,,}"]=1
		fi
	done <"$installed_file"

	while IFS= read -r extension_id || [[ -n "$extension_id" ]]; do
		if [[ -z "$extension_id" ]]; then
			continue
		fi

		if [[ -n "${installed_extensions[${extension_id,,}]:-}" ]]; then
			ok "Already installed: $extension_id"
			already_installed=$((already_installed + 1))
			continue
		fi

		info "Installing VS Code extension: $extension_id"

		if "$CODE_BIN" --install-extension "$extension_id"; then
			ok "Installed: $extension_id"
			installed_extensions["${extension_id,,}"]=1
			installed_now=$((installed_now + 1))
		else
			err "Failed to install VS Code extension: $extension_id"
			failed=$((failed + 1))
		fi
	done <"$desired_file"

	printf '\n'
	printf '  Installed now:     %d\n' "$installed_now"
	printf '  Already installed: %d\n' "$already_installed"
	printf '  Failed:            %d\n' "$failed"

	if ((failed > 0)); then
		RESTORE_FAILED_COUNT=$((RESTORE_FAILED_COUNT + 1))
		return 1
	fi

	RESTORE_SUCCESS_COUNT=$((RESTORE_SUCCESS_COUNT + 1))
}

# ---------- Status ----------
print_managed_file_status() {
	local label
	local source
	local target
	local required

	label="$1"
	source="$2"
	target="$3"
	required="$4"

	printf '%-28s ' "$label"

	if [[ ! -f "$source" ]]; then
		if [[ "$required" == "required" ]]; then
			printf '%b%-14s%b %s\n' \
				"$RED" "NO SOURCE" "$RESET" \
				"$source"

			STATUS_MISSING_COUNT=$((STATUS_MISSING_COUNT + 1))
			return 0
		fi

		printf '%b%-14s%b %s\n' \
			"$YELLOW" "NOT MANAGED" "$RESET" \
			"$source"

		STATUS_MISSING_COUNT=$((STATUS_MISSING_COUNT + 1))
		return 0
	fi

	if [[ ! -e "$target" && ! -L "$target" ]]; then
		printf '%b%-14s%b %s\n' \
			"$RED" "MISSING" "$RESET" \
			"$target"

		STATUS_MISSING_COUNT=$((STATUS_MISSING_COUNT + 1))
		return 0
	fi

	if managed_file_matches "$source" "$target"; then
		if target_is_link "$target"; then
			printf '%b%-14s%b %s\n' \
				"$GREEN" "LINKED MATCH" "$RESET" \
				"$target"
		else
			printf '%b%-14s%b %s\n' \
				"$YELLOW" "COPY MATCH" "$RESET" \
				"$target"
		fi

		STATUS_MATCH_COUNT=$((STATUS_MATCH_COUNT + 1))
		return 0
	fi

	printf '%b%-14s%b %s\n' \
		"$YELLOW" "DIFFERENT" "$RESET" \
		"$target"

	STATUS_DIFFERENT_COUNT=$((STATUS_DIFFERENT_COUNT + 1))
}

print_extension_status() {
	local desired_file
	local installed_file
	local extension_id
	local desired_count
	local installed_match_count
	local missing_count
	declare -A installed_extensions

	desired_file="$TEMP_DIR/status-desired-extensions.txt"
	installed_file="$TEMP_DIR/status-installed-extensions.txt"
	desired_count=0
	installed_match_count=0
	missing_count=0

	section "VS Code extension status"

	if [[ ! -f "$VSCODE_EXTENSIONS_SOURCE" ]]; then
		warn "Extension inventory is not managed: $VSCODE_EXTENSIONS_SOURCE"
		return 0
	fi

	if ! resolve_code_cli; then
		warn "VS Code CLI is unavailable; installed extensions cannot be checked."
		return 0
	fi

	if ! normalize_extension_inventory \
		"$VSCODE_EXTENSIONS_SOURCE" \
		"$desired_file"; then
		return 1
	fi

	if ! load_installed_extensions "$installed_file"; then
		return 1
	fi

	installed_extensions=()

	while IFS= read -r extension_id || [[ -n "$extension_id" ]]; do
		if [[ -n "$extension_id" ]]; then
			installed_extensions["${extension_id,,}"]=1
		fi
	done <"$installed_file"

	while IFS= read -r extension_id || [[ -n "$extension_id" ]]; do
		if [[ -z "$extension_id" ]]; then
			continue
		fi

		desired_count=$((desired_count + 1))

		if [[ -n "${installed_extensions[${extension_id,,}]:-}" ]]; then
			installed_match_count=$((installed_match_count + 1))
		else
			printf '  %bMISSING%b  %s\n' \
				"$YELLOW" "$RESET" "$extension_id"

			missing_count=$((missing_count + 1))
		fi
	done <"$desired_file"

	printf '\n'
	printf '  Repository extensions: %d\n' "$desired_count"
	printf '  Installed matches:     %d\n' "$installed_match_count"
	printf '  Missing locally:       %d\n' "$missing_count"

	if ((missing_count == 0)); then
		ok "All managed VS Code extensions are installed."
	else
		warn "$missing_count managed VS Code extension(s) are not installed."
	fi
}

run_status() {
	local record

	STATUS_MATCH_COUNT=0
	STATUS_DIFFERENT_COUNT=0
	STATUS_MISSING_COUNT=0

	section "Managed-file status"

	printf '%b%-28s %-14s %s%b\n' \
		"$BOLD" \
		"Configuration" \
		"Status" \
		"Location" \
		"$RESET"

	printf '%-28s %-14s %s\n' \
		"────────────────────────────" \
		"──────────────" \
		"────────────────────────────────────────"

	for record in "${MANAGED_FILES[@]}"; do
		if ! parse_file_record "$record"; then
			return 1
		fi

		print_managed_file_status \
			"$CURRENT_LABEL" \
			"$CURRENT_SOURCE" \
			"$CURRENT_TARGET" \
			"$CURRENT_REQUIRED"
	done

	if ! print_extension_status; then
		return 1
	fi

	section "Status summary"

	printf '  Matching:  %d\n' "$STATUS_MATCH_COUNT"
	printf '  Different: %d\n' "$STATUS_DIFFERENT_COUNT"
	printf '  Missing:   %d\n' "$STATUS_MISSING_COUNT"
}

# ---------- Summaries ----------
print_capture_summary() {
	section "Capture summary"

	printf '  Captured or current: %d\n' "$CAPTURE_SUCCESS_COUNT"
	printf '  Skipped:             %d\n' "$CAPTURE_SKIPPED_COUNT"
	printf '  Failed:              %d\n' "$CAPTURE_FAILED_COUNT"
}

print_restore_summary() {
	section "Restore summary"

	printf '  Restored or current: %d\n' "$RESTORE_SUCCESS_COUNT"
	printf '  Skipped:             %d\n' "$RESTORE_SKIPPED_COUNT"
	printf '  Failed:              %d\n' "$RESTORE_FAILED_COUNT"
}
# ------ Inventory Capture ----------

capture_inventory() {
	local inventory_dir
	local failed

	inventory_dir="$DOTFILES_DIR/inventory"
	failed=0

	section "Capture lightweight machine inventory"

	if ! mkdir -p -- "$inventory_dir/browsers"; then
		err "Unable to create inventory directory: $inventory_dir"
		return 1
	fi

	if ! capture_package_list "$inventory_dir/packages.txt"; then
		failed=$((failed + 1))
	fi

	if ! capture_wsl_summary "$inventory_dir/wsl.txt"; then
		failed=$((failed + 1))
	fi

	if ! capture_windows_summary "$inventory_dir/windows.txt"; then
		failed=$((failed + 1))
	fi

	if ! capture_browser_summary "$inventory_dir/browsers"; then
		failed=$((failed + 1))
	fi

	if ((failed > 0)); then
		err "$failed lightweight inventory capture group(s) failed."
		return 1
	fi

	ok "Lightweight machine inventory captured."
}

capture_package_list() {
	local output_file

	output_file="$1"

	{
		printf '## winget\n'
		if command -v winget >/dev/null 2>&1; then
			winget list 2>/dev/null || true
		else
			printf 'winget unavailable\n'
		fi

		printf '\n## scoop\n'
		if command -v scoop >/dev/null 2>&1; then
			scoop list 2>/dev/null || true
		else
			printf 'scoop unavailable\n'
		fi

		printf '\n## chocolatey\n'
		if command -v choco >/dev/null 2>&1; then
			choco list 2>/dev/null || true
		else
			printf 'chocolatey unavailable\n'
		fi
	} >"$output_file"
}

capture_wsl_summary() {
	local output_file

	output_file="$1"

	{
		printf '## wsl --list --verbose\n'
		if command -v wsl.exe >/dev/null 2>&1; then
			wsl.exe --list --verbose 2>/dev/null || true

			printf '\n## wsl --status\n'
			wsl.exe --status 2>/dev/null || true
		else
			printf 'wsl.exe unavailable\n'
		fi
	} >"$output_file"
}

capture_windows_summary() {
	local output_file

	output_file="$1"

	{
		printf '## systeminfo\n'
		if command -v systeminfo >/dev/null 2>&1; then
			systeminfo 2>/dev/null || true
		else
			printf 'systeminfo unavailable\n'
		fi

		printf '\n## user environment\n'
		if command -v powershell.exe >/dev/null 2>&1; then
			powershell.exe -NoProfile -Command \
				"[Environment]::GetEnvironmentVariables('User').GetEnumerator() | Sort-Object Name | Format-Table -AutoSize" \
				2>/dev/null || true
		else
			printf 'powershell.exe unavailable\n'
		fi
	} >"$output_file"
}

capture_browser_summary() {
	local browser_dir
	local failed

	browser_dir="$1"
	failed=0

	if ! capture_firefox_dev_summary "$browser_dir/firefox-dev-edition.txt"; then
		failed=$((failed + 1))
	fi

	if ! capture_ungoogled_chromium_summary "$browser_dir/ungoogled-chromium.txt"; then
		failed=$((failed + 1))
	fi

	if ((failed > 0)); then
		return 1
	fi
}

capture_firefox_dev_summary() {
	local output_file
	local firefox_root
	local firefox_root_unix

	output_file="$1"
	firefox_root=""
	firefox_root_unix=""

	if [[ -n "${APPDATA:-}" ]] && ! has_control_characters "$APPDATA"; then
		if firefox_root_unix="$(to_unix_path "$APPDATA")"; then
			firefox_root="$firefox_root_unix/Mozilla/Firefox"
		fi
	fi

	{
		printf '## Firefox Developer Edition\n'

		if [[ -z "$firefox_root" || ! -d "$firefox_root" ]]; then
			printf 'Firefox profile root not found\n'
			return 0
		fi

		printf '\n## profile root\n%s\n' "$firefox_root"

		printf '\n## profile metadata files\n'
		find "$firefox_root" -maxdepth 1 -type f \
			\( -name 'profiles.ini' -o -name 'installs.ini' \) \
			-print 2>/dev/null || true

		printf '\n## profiles\n'
		find "$firefox_root" -maxdepth 1 -type d \
			\( -name '*.dev-edition-default*' -o -name '*.default-release*' -o -name '*.default*' \) \
			-printf '%f\n' 2>/dev/null | sort || true

		printf '\n## extension files/directories\n'
		find "$firefox_root" -maxdepth 3 \
			\( -path '*/extensions/*' -o -path '*/extensions.json' \) \
			-print 2>/dev/null | sort || true
	} >"$output_file"
}

capture_ungoogled_chromium_summary() {
	local output_file
	local chromium_root
	local localappdata_unix

	output_file="$1"
	chromium_root=""
	localappdata_unix=""

	if [[ -n "${LOCALAPPDATA:-}" ]] && ! has_control_characters "$LOCALAPPDATA"; then
		if localappdata_unix="$(to_unix_path "$LOCALAPPDATA")"; then
			chromium_root="$localappdata_unix/Chromium/User Data"
		fi
	fi

	{
		printf '## Ungoogled Chromium\n'

		if [[ -z "$chromium_root" || ! -d "$chromium_root" ]]; then
			printf 'Chromium profile root not found\n'
			return 0
		fi

		printf '\n## profile root\n%s\n' "$chromium_root"

		printf '\n## profiles\n'
		find "$chromium_root" -maxdepth 1 -type d \
			\( -name 'Default' -o -name 'Profile *' \) \
			-printf '%f\n' 2>/dev/null | sort || true

		printf '\n## extension ids\n'
		find "$chromium_root" -maxdepth 3 -type d -path '*/Extensions/*' \
			-printf '%f\n' 2>/dev/null | sort -u || true

		printf '\n## local state\n'
		if [[ -f "$chromium_root/Local State" ]]; then
			printf 'Local State exists\n'
		else
			printf 'Local State not found\n'
		fi
	} >"$output_file"
}

# ---------- Modes ----------
mode_capture() {
	local failed

	failed=0

	CAPTURE_SUCCESS_COUNT=0
	CAPTURE_SKIPPED_COUNT=0
	CAPTURE_FAILED_COUNT=0

	if ! mkdir -p \
		-- \
		"$DOTFILES_DIR" \
		"$VSCODE_DIR" \
		"${WINDOWS_TERMINAL_SETTINGS_SOURCE%/*}" \
		"$DOTFILES_DIR/inventory" \
		"$DOTFILES_DIR/inventory/browsers"; then
		err "Unable to create the required dotfiles directories."
		return 1
	fi

	if ! capture_managed_files; then
		failed=$((failed + 1))
	fi

	if ! capture_vscode_extensions; then
		failed=$((failed + 1))
	fi

	if ! capture_inventory; then
		failed=$((failed + 1))
	fi

	print_capture_summary

	if ((failed > 0 || CAPTURE_FAILED_COUNT > 0)); then
		err "Capture completed with failures."
		return 1
	fi

	ok "Dotfiles capture complete."
	section "Repository files"

	if command -v tree >/dev/null 2>&1 &&
		tree --version 2>&1 | grep -q '^tree v'; then
		tree -a -I '.git' --noreport "$DOTFILES_DIR"
	else
		warn "GNU tree is unavailable; using find instead."

		find "$DOTFILES_DIR" \
			-path "$DOTFILES_DIR/.git" -prune -o \
			-type f -printf '  %P\n' |
			LC_ALL=C sort
	fi
}

mode_restore() {
	local failed

	failed=0

	RESTORE_SUCCESS_COUNT=0
	RESTORE_SKIPPED_COUNT=0
	RESTORE_FAILED_COUNT=0

	if [[ ! -d "$DOTFILES_DIR" ]]; then
		err "Dotfiles repository does not exist: $DOTFILES_DIR"
		return 1
	fi

	if ! restore_managed_files; then
		failed=$((failed + 1))
	fi

	if ! install_vscode_extensions; then
		failed=$((failed + 1))
	fi

	print_restore_summary

	if ((failed > 0 || RESTORE_FAILED_COUNT > 0)); then
		err "Dotfiles restore completed with failures."
		return 1
	fi

	ok "Dotfiles restore complete."

	if ((RESTORE_SKIPPED_COUNT > 0)); then
		warn "Some optional configuration was skipped."
	fi
}

mode_status() {
	if ! run_status; then
		return 1
	fi

	ok "Dotfiles status check complete."
}

# ---------- Main ----------
main() {
	initialize_colors

	if ! parse_args "$@"; then
		usage
		return 2
	fi

	if [[ "$MODE" == "help" ]]; then
		usage
		return 0
	fi

	if ! initialize_paths; then
		return 1
	fi

	if ! initialize_temp_directory; then
		return 1
	fi

	install_signal_handlers
	resolve_powershell

	if [[ "$MODE" == "menu" ]]; then
		if ! choose_mode; then
			return 1
		fi
	fi

	section "Dotfiles configuration"

	info "Mode: $MODE"
	info "Repository: $DOTFILES_DIR"
	info "VS Code settings target: $VSCODE_SETTINGS_TARGET"

	if [[ -n "$WINDOWS_TERMINAL_SETTINGS_TARGET" ]]; then
		info "Windows Terminal target: $WINDOWS_TERMINAL_SETTINGS_TARGET"
	else
		warn "Windows Terminal target could not be determined."
	fi

	case "$MODE" in
	capture)
		if ! mode_capture; then
			return 1
		fi
		;;
	restore)
		if ! mode_restore; then
			return 1
		fi
		;;
	status)
		if ! mode_status; then
			return 1
		fi
		;;
	quit)
		info "No changes were made."
		;;
	*)
		err "Unhandled mode: $MODE"
		return 1
		;;
	esac
}

main "$@"
