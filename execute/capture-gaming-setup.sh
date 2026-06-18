#!/usr/bin/env bash
# capture-gaming-setup.sh
#
# Allowlisted xemu metadata capture for gaming-setup-WIN.
#
# No arguments opens the interactive menu.
#
# Environment overrides:
#   GAMING_SETUP_REPO
#   GAMING_SETUP_BACKUP_ROOT
#   XEMU_ROOT
#   XEMU_GAMES_DIR
#   XEMU_CONFIG_DIR
#   XEMU_GLOBAL_CONFIG
#   MAX_CONFIG_BYTES

set -Eeuo pipefail
set -o pipefail
IFS=$'\n\t'
umask 077

# ---------- Configuration ----------
MODE="menu"

GAMING_SETUP_REPO="${GAMING_SETUP_REPO:-$HOME/workspace/personal/gaming-setup-WIN}"
GAMING_SETUP_BACKUP_ROOT="${GAMING_SETUP_BACKUP_ROOT:-/e/!BACKUP/gaming-setup-WIN}"

XEMU_ROOT="${XEMU_ROOT:-/e/Video_Games/Emulators/Xbox/xemu}"
XEMU_GAMES_DIR="${XEMU_GAMES_DIR:-$XEMU_ROOT/Games}"
XEMU_CONFIG_DIR="${XEMU_CONFIG_DIR:-$XEMU_ROOT/Configs}"
XEMU_GLOBAL_CONFIG="${XEMU_GLOBAL_CONFIG:-}"

MAX_CONFIG_BYTES="${MAX_CONFIG_BYTES:-5242880}"
MAX_ARCHIVE_FILE_BYTES="${MAX_ARCHIVE_FILE_BYTES:-10485760}"

readonly GAME_HEADER=$'record_id\tdisplay_title\tplatform\temulator_id\tfilename\trelative_path\tformat\tsize_bytes\tmodified_utc\tsha1\tstatus\tconfig_id\treshade_preset\tnotes'
readonly LEGACY_GAME_HEADER=$'title\tplatform\temulator\tmedia_filename\tmedia_sha1\tconfig_id\treshade_preset\tstatus\tnotes'
readonly EMULATOR_HEADER=$'emulator_id\tplatform\tdisplay_name\tinstall_status\tconfig_destination\tnotes'
readonly LOCATION_HEADER=$'location_id\tpath'

# ---------- ANSI ----------
BOLD=""
DIM=""
GREEN=""
YELLOW=""
RED=""
BLUE=""
CYAN=""
RESET=""

# ---------- Runtime ----------
TEMP_DIR=""

GAMES_MANIFEST=""
EMULATORS_MANIFEST=""
LOCATIONS_MANIFEST=""

OLD_GAMES_FILE=""
OLD_EMULATORS_FILE=""
DISCOVERED_GAMES_FILE=""
DISCOVERED_EMULATORS_FILE=""
MERGED_GAMES_FILE=""
MERGED_EMULATORS_FILE=""
LOCATIONS_CANDIDATE_FILE=""

DISCOVERED_GAME_COUNT=0
DISCOVERED_CONFIG_COUNT=0
PLANNED_CHANGE_COUNT=0

declare -a PLAN_LABELS=()
declare -a PLAN_SOURCES=()
declare -a PLAN_DESTINATIONS=()
declare -a PLAN_ACTIONS=()

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

dry_run_message() {
	printf '%b[DRY RUN]%b  %s\n' "$DIM" "$RESET" "$*"
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
		"  bash capture-gaming-setup.sh" \
		"  bash capture-gaming-setup.sh --status" \
		"  bash capture-gaming-setup.sh --capture" \
		"  bash capture-gaming-setup.sh --dry-run" \
		"  bash capture-gaming-setup.sh --archive" \
		"  bash capture-gaming-setup.sh --help" \
		"" \
		"Modes:" \
		"  --status    Report detected media, configs, and proposed changes" \
		"  --capture   Update manifests and approved configuration copies" \
		"  --dry-run   Perform the complete capture plan without writing" \
		"  --archive   Create an allowlisted metadata ZIP" \
		"  --help      Show this help" \
		"" \
		"Scope:" \
		"  Only the explicitly configured xemu Games and Configs paths are read." \
		"  Game media is inventoried but never copied."
}

choose_mode() {
	local choice
	choice=""

	while :; do
		section "Gaming setup capture"

		printf '  %b1%b  %-10s %s\n' \
			"$CYAN" "$RESET" \
			"status" \
			"Inspect xemu and report what would change"

		printf '  %b2%b  %-10s %s\n' \
			"$GREEN" "$RESET" \
			"capture" \
			"Update manifests and approved configurations"

		printf '  %b3%b  %-10s %s\n' \
			"$YELLOW" "$RESET" \
			"dry-run" \
			"Run the complete capture plan without writing"

		printf '  %b4%b  %-10s %s\n' \
			"$BLUE" "$RESET" \
			"archive" \
			"Create an allowlisted metadata ZIP"

		printf '  %bq%b  %-10s %s\n\n' \
			"$RED" "$RESET" \
			"quit" \
			"Exit without changes"

		printf '%bSelection%b [1-4/q]: ' "$BOLD" "$RESET"

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
		1 | status)
			MODE="status"
			return
			;;
		2 | capture)
			MODE="capture"
			return
			;;
		3 | dry-run | dryrun)
			MODE="dry-run"
			return
			;;
		4 | archive)
			MODE="archive"
			return
			;;
		q | quit | exit)
			MODE="quit"
			return
			;;
		*)
			warn "Invalid selection: ${choice:-empty}"
			;;
		esac
	done
}

# ---------- Arguments ----------
parse_args() {
	if (($# > 1)); then
		err "Only one mode may be specified."
		return 2
	fi

	case "${1:-}" in
	"")
		MODE="menu"
		;;
	--status | --check)
		MODE="status"
		;;
	--capture)
		MODE="capture"
		;;
	--dry-run)
		MODE="dry-run"
		;;
	--archive)
		MODE="archive"
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

# ---------- Validation ----------
has_control_characters() {
	local value
	value=$1

	[[ "$value" == *[[:cntrl:]]* ]]
}

validate_path() {
	local label
	local value

	label=$1
	value=$2

	if [[ -z "$value" ]]; then
		err "$label is empty."
		return 1
	fi

	if has_control_characters "$value"; then
		err "$label contains unsupported control characters."
		return 1
	fi
}

normalize_path() {
	local path
	local component
	local -a components
	local -a resolved
	local IFS

	path=$1

	case "$path" in
	"~")
		path=$HOME
		;;
	"$HOME"*)
		path="$HOME/${path#~/}"
		;;
	esac

	if [[ "$path" != /* ]]; then
		path="$PWD/$path"
	fi

	IFS='/'
	read -r -a components <<<"${path#/}"
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

path_is_within() {
	local child
	local parent

	child=$1
	parent=$2

	[[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

validate_dependencies() {
	local command_name
	local -a required_commands
	local -a missing_commands

	required_commands=(
		awk
		cat
		cmp
		cp
		date
		find
		git
		mkdir
		mktemp
		mv
		rm
		sed
		sha1sum
		sort
		stat
	)

	missing_commands=()

	for command_name in "${required_commands[@]}"; do
		if ! command -v "$command_name" >/dev/null 2>&1; then
			missing_commands+=("$command_name")
		fi
	done

	if ((${#missing_commands[@]} > 0)); then
		printf '%b[FAIL]%b  Missing required command(s): %s\n' \
			"$RED" "$RESET" "${missing_commands[*]}" >&2
		return 1
	fi
}

initialize_paths() {
	if [[ -z "${HOME:-}" ]]; then
		err "HOME is not set."
		return 1
	fi

	if ! validate_path "Gaming repository" "$GAMING_SETUP_REPO" ||
		! validate_path "Backup root" "$GAMING_SETUP_BACKUP_ROOT" ||
		! validate_path "xemu root" "$XEMU_ROOT" ||
		! validate_path "xemu games directory" "$XEMU_GAMES_DIR" ||
		! validate_path "xemu config directory" "$XEMU_CONFIG_DIR"; then
		return 1
	fi

	if ! GAMING_SETUP_REPO=$(normalize_path "$GAMING_SETUP_REPO"); then
		err "Unable to normalize GAMING_SETUP_REPO."
		return 1
	fi

	if ! GAMING_SETUP_BACKUP_ROOT=$(normalize_path "$GAMING_SETUP_BACKUP_ROOT"); then
		err "Unable to normalize GAMING_SETUP_BACKUP_ROOT."
		return 1
	fi

	if ! XEMU_ROOT=$(normalize_path "$XEMU_ROOT"); then
		err "Unable to normalize XEMU_ROOT."
		return 1
	fi

	if ! XEMU_GAMES_DIR=$(normalize_path "$XEMU_GAMES_DIR"); then
		err "Unable to normalize XEMU_GAMES_DIR."
		return 1
	fi

	if ! XEMU_CONFIG_DIR=$(normalize_path "$XEMU_CONFIG_DIR"); then
		err "Unable to normalize XEMU_CONFIG_DIR."
		return 1
	fi

	if [[ -n "$XEMU_GLOBAL_CONFIG" ]]; then
		if ! validate_path "xemu global config" "$XEMU_GLOBAL_CONFIG"; then
			return 1
		fi

		if ! XEMU_GLOBAL_CONFIG=$(normalize_path "$XEMU_GLOBAL_CONFIG"); then
			err "Unable to normalize XEMU_GLOBAL_CONFIG."
			return 1
		fi
	fi

	GAMES_MANIFEST="$GAMING_SETUP_REPO/manifests/games.tsv"
	EMULATORS_MANIFEST="$GAMING_SETUP_REPO/manifests/emulators.tsv"
	LOCATIONS_MANIFEST="$GAMING_SETUP_REPO/manifests/locations.local.tsv"
}

validate_repository() {
	local git_root
	git_root=""

	case "$GAMING_SETUP_REPO" in
	"/" | "/c" | "/d" | "/e" | "$HOME")
		err "Refusing suspiciously broad repository path: $GAMING_SETUP_REPO"
		return 1
		;;
	esac

	if [[ ! -d "$GAMING_SETUP_REPO" ]]; then
		err "Gaming metadata repository does not exist: $GAMING_SETUP_REPO"
		return 1
	fi

	if [[ ! -d "$GAMING_SETUP_REPO/manifests" ||
		! -d "$GAMING_SETUP_REPO/emulators/xemu" ||
		! -f "$GAMING_SETUP_REPO/README.md" ]]; then
		err "Gaming metadata repository markers are missing."
		return 1
	fi

	local configured_root

	if ! configured_root="$(
		cd -- "$GAMING_SETUP_REPO" 2>/dev/null &&
			pwd -P
	)"; then
		err "Unable to resolve the gaming metadata repository path."
		return 1
	fi

	if ! git_root="$(
		git -C "$GAMING_SETUP_REPO" rev-parse --show-toplevel 2>/dev/null
	)"; then
		err "Gaming metadata directory is not a Git repository."
		return 1
	fi

	if ! git_root="$(
		cd -- "$git_root" 2>/dev/null &&
			pwd -P
	)"; then
		err "Unable to resolve the Git repository root."
		return 1
	fi

	if [[ "$git_root" != "$configured_root" ]]; then
		err "GAMING_SETUP_REPO must point to the Git repository root."
		printf '  Configured: %s\n' "$configured_root" >&2
		printf '  Git root:   %s\n' "$git_root" >&2
		return 1
	fi

	GAMING_SETUP_REPO="$configured_root"
	GAMES_MANIFEST="$GAMING_SETUP_REPO/manifests/games.tsv"
	EMULATORS_MANIFEST="$GAMING_SETUP_REPO/manifests/emulators.tsv"
	LOCATIONS_MANIFEST="$GAMING_SETUP_REPO/manifests/locations.local.tsv"

	if ! path_is_within "$XEMU_GAMES_DIR" "$XEMU_ROOT"; then
		err "XEMU_GAMES_DIR must remain inside XEMU_ROOT."
		return 1
	fi

	if ! path_is_within "$XEMU_CONFIG_DIR" "$XEMU_ROOT"; then
		err "XEMU_CONFIG_DIR must remain inside XEMU_ROOT."
		return 1
	fi

	if [[ -L "$XEMU_GAMES_DIR" || -L "$XEMU_CONFIG_DIR" ]]; then
		err "Registered xemu directories may not be symbolic links."
		return 1
	fi

	if [[ ! "$MAX_CONFIG_BYTES" =~ ^[1-9][0-9]*$ ]]; then
		err "MAX_CONFIG_BYTES must be a positive integer."
		return 1
	fi

	if [[ ! "$MAX_ARCHIVE_FILE_BYTES" =~ ^[1-9][0-9]*$ ]]; then
		err "MAX_ARCHIVE_FILE_BYTES must be a positive integer."
		return 1
	fi
}

# ---------- Temporary workspace ----------
initialize_temp_directory() {
	local temp_base
	temp_base="${TMPDIR:-/tmp}"

	if [[ ! -d "$temp_base" || ! -w "$temp_base" ]]; then
		err "Temporary directory base is unavailable: $temp_base"
		return 1
	fi

	if ! TEMP_DIR=$(mktemp -d "$temp_base/capture-gaming-setup.XXXXXXXX"); then
		err "Unable to create the temporary workspace."
		return 1
	fi

	OLD_GAMES_FILE="$TEMP_DIR/games.old.tsv"
	OLD_EMULATORS_FILE="$TEMP_DIR/emulators.old.tsv"
	DISCOVERED_GAMES_FILE="$TEMP_DIR/games.discovered.tsv"
	DISCOVERED_EMULATORS_FILE="$TEMP_DIR/emulators.discovered.tsv"
	MERGED_GAMES_FILE="$TEMP_DIR/games.merged.tsv"
	MERGED_EMULATORS_FILE="$TEMP_DIR/emulators.merged.tsv"
	LOCATIONS_CANDIDATE_FILE="$TEMP_DIR/locations.local.tsv"
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
	signal_name=$1

	err "Interrupted by signal: $signal_name"
}

install_signal_handlers() {
	trap cleanup EXIT
	trap 'handle_signal INT; exit 130' INT
	trap 'handle_signal TERM; exit 143' TERM
	trap 'handle_signal HUP; exit 129' HUP
}

# ---------- Manifest compatibility ----------
manifest_has_rows() {
	local manifest_file
	manifest_file=$1

	awk '
		NR > 1 && $0 !~ /^[[:space:]]*$/ {
			found = 1
			exit
		}
		END {
			exit !found
		}
	' "$manifest_file"
}

sanitize_tsv_value() {
	local value
	value=$1

	value=${value//$'\r'/ }
	value=${value//$'\n'/ }
	value=${value//$'\t'/ }

	printf '%s' "$value"
}

media_format() {
	local filename
	filename=${1,,}

	case "$filename" in
	*.xiso.iso)
		printf 'xiso.iso'
		;;
	*.xiso)
		printf 'xiso'
		;;
	*.iso)
		printf 'iso'
		;;
	*)
		return 1
		;;
	esac
}

display_title() {
	local filename
	local lowercase
	local length

	filename=$1
	lowercase=${filename,,}
	length=${#filename}

	case "$lowercase" in
	*.xiso.iso)
		printf '%s' "${filename:0:length-9}"
		;;
	*.xiso)
		printf '%s' "${filename:0:length-5}"
		;;
	*.iso)
		printf '%s' "${filename:0:length-4}"
		;;
	*)
		printf '%s' "$filename"
		;;
	esac
}

stable_record_id() {
	local emulator_id
	local relative_path
	local digest

	emulator_id=$1
	relative_path=$2

	if ! digest=$(
		printf '%s\0%s' "$emulator_id" "$relative_path" |
			sha1sum |
			awk '{print substr($1, 1, 12)}'
	); then
		err "Unable to generate a stable media record ID."
		return 1
	fi

	if [[ ! "$digest" =~ ^[0-9a-fA-F]{12}$ ]]; then
		err "Invalid stable media record digest."
		return 1
	fi

	printf '%s-%s' "$emulator_id" "${digest,,}"
}

migrate_legacy_games() {
	local input_file
	local output_file
	local body_file
	local title
	local platform
	local emulator
	local filename
	local media_sha1
	local config_id
	local reshade_preset
	local status
	local notes
	local extra
	local relative_path
	local format
	local record_id

	input_file=$1
	output_file=$2
	body_file="$TEMP_DIR/legacy-games.body.tsv"

	if ! sed '1d' "$input_file" >"$body_file"; then
		err "Unable to read the legacy game manifest."
		return 1
	fi

	printf '%s\n' "$GAME_HEADER" >"$output_file"

	while IFS=$'\t' read -r \
		title \
		platform \
		emulator \
		filename \
		media_sha1 \
		config_id \
		reshade_preset \
		status \
		notes \
		extra; do
		if [[ -z "$title$platform$emulator$filename$media_sha1$config_id$reshade_preset$status$notes$extra" ]]; then
			continue
		fi

		if [[ -n "$extra" ]]; then
			err "Legacy games.tsv contains a row with excess columns."
			return 1
		fi

		emulator=${emulator:-xemu}
		platform=${platform:-xbox}
		relative_path=$filename

		if ! format=$(media_format "$filename"); then
			format=""
		fi

		if [[ -z "$title" ]]; then
			if ! title=$(display_title "$filename"); then
				title=$filename
			fi
		fi

		if ! record_id=$(stable_record_id "$emulator" "$relative_path"); then
			return 1
		fi

		title=$(sanitize_tsv_value "$title")
		filename=$(sanitize_tsv_value "$filename")
		relative_path=$(sanitize_tsv_value "$relative_path")
		notes=$(sanitize_tsv_value "$notes")

		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t%s\t%s\t%s\t%s\t%s\n' \
			"$record_id" \
			"$title" \
			"$platform" \
			"$emulator" \
			"$filename" \
			"$relative_path" \
			"$format" \
			"$media_sha1" \
			"$status" \
			"$config_id" \
			"$reshade_preset" \
			"$notes" >>"$output_file"
	done <"$body_file"

	warn "Legacy games.tsv schema will be normalized during capture."
}

prepare_games_manifest() {
	local normalized_file
	local current_header

	normalized_file="$TEMP_DIR/games.normalized.tsv"
	current_header=""

	if [[ ! -s "$GAMES_MANIFEST" ]]; then
		printf '%s\n' "$GAME_HEADER" >"$OLD_GAMES_FILE"
		return
	fi

	if ! sed 's/\r$//' "$GAMES_MANIFEST" >"$normalized_file"; then
		err "Unable to normalize games.tsv line endings."
		return 1
	fi

	if ! IFS= read -r current_header <"$normalized_file"; then
		err "Unable to read games.tsv header."
		return 1
	fi

	case "$current_header" in
	"$GAME_HEADER")
		if ! cp -- "$normalized_file" "$OLD_GAMES_FILE"; then
			err "Unable to prepare games.tsv."
			return 1
		fi
		;;
	"$LEGACY_GAME_HEADER")
		if ! migrate_legacy_games "$normalized_file" "$OLD_GAMES_FILE"; then
			return 1
		fi
		;;
	*)
		if manifest_has_rows "$normalized_file"; then
			err "Unsupported games.tsv schema with existing data."
			printf 'Found:\n%s\n' "$current_header" >&2
			return 1
		fi

		warn "Empty games.tsv uses an older schema; a new header will be proposed."
		printf '%s\n' "$GAME_HEADER" >"$OLD_GAMES_FILE"
		;;
	esac
}

migrate_legacy_emulators() {
	local input_file
	local output_file

	input_file=$1
	output_file=$2

	if ! awk \
		-F '\t' \
		-v OFS='\t' \
		-v header="$EMULATOR_HEADER" '
			NR == 1 {
				for (field = 1; field <= NF; field++)
					column[$field] = field

				id_column = column["emulator_id"]

				if (!id_column)
					id_column = column["emulator"]

				name_column = column["display_name"]

				if (!name_column)
					name_column = column["name"]

				status_column = column["install_status"]

				if (!status_column)
					status_column = column["status"]

				config_column = column["config_destination"]

				if (!config_column)
					config_column = column["config_path"]

				if (!id_column)
					exit 2

				print header
				next
			}
			{
				id = $id_column

				if (id == "")
					next

				platform = column["platform"] ? $(column["platform"]) : ""
				name = name_column ? $name_column : id
				status = status_column ? $status_column : ""
				config = config_column ? $config_column : ""
				notes = column["notes"] ? $(column["notes"]) : ""

				print id, platform, name, status, config, notes
			}
		' "$input_file" >"$output_file"; then
		err "Unable to normalize the existing emulators.tsv schema."
		return 1
	fi

	warn "Legacy emulators.tsv schema will be normalized during capture."
}

prepare_emulators_manifest() {
	local normalized_file
	local current_header

	normalized_file="$TEMP_DIR/emulators.normalized.tsv"
	current_header=""

	if [[ ! -s "$EMULATORS_MANIFEST" ]]; then
		printf '%s\n' "$EMULATOR_HEADER" >"$OLD_EMULATORS_FILE"
		return
	fi

	if ! sed 's/\r$//' "$EMULATORS_MANIFEST" >"$normalized_file"; then
		err "Unable to normalize emulators.tsv line endings."
		return 1
	fi

	if ! IFS= read -r current_header <"$normalized_file"; then
		err "Unable to read emulators.tsv header."
		return 1
	fi

	if [[ "$current_header" == "$EMULATOR_HEADER" ]]; then
		if ! cp -- "$normalized_file" "$OLD_EMULATORS_FILE"; then
			err "Unable to prepare emulators.tsv."
			return 1
		fi

		return
	fi

	if ! manifest_has_rows "$normalized_file"; then
		warn "Empty emulators.tsv uses an older schema; a new header will be proposed."
		printf '%s\n' "$EMULATOR_HEADER" >"$OLD_EMULATORS_FILE"
		return
	fi

	migrate_legacy_emulators "$normalized_file" "$OLD_EMULATORS_FILE"
}

validate_manifest() {
	local manifest_file
	local expected_fields

	manifest_file=$1
	expected_fields=$2

	if ! awk \
		-F '\t' \
		-v expected="$expected_fields" '
			NR == 1 {
				next
			}
			NF != expected || $1 == "" || seen[$1]++ {
				exit 1
			}
		' "$manifest_file"; then
		err "Manifest contains malformed or duplicate rows: $manifest_file"
		return 1
	fi
}

# ---------- Discovery ----------
format_modification_time() {
	local epoch
	epoch=$1

	date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
}

discover_games() {
	local unsorted_file
	local sorted_file
	local media_file
	local filename
	local relative_path
	local title
	local format
	local record_id
	local size_bytes
	local modified_epoch
	local modified_utc

	printf '%s\n' "$GAME_HEADER" >"$DISCOVERED_GAMES_FILE"

	if [[ ! -d "$XEMU_GAMES_DIR" ]]; then
		warn "xemu games directory was not found: $XEMU_GAMES_DIR"
		return
	fi

	unsorted_file="$TEMP_DIR/media.unsorted"
	sorted_file="$TEMP_DIR/media.sorted"

	if ! find -P "$XEMU_GAMES_DIR" \
		-type f \
		\( -iname '*.iso' -o -iname '*.xiso' \) \
		-print0 >"$unsorted_file"; then
		err "Unable to inspect the xemu games directory."
		return 1
	fi

	if ! LC_ALL=C sort -z -- "$unsorted_file" >"$sorted_file"; then
		err "Unable to sort discovered media."
		return 1
	fi

	while IFS= read -r -d '' media_file; do
		if [[ "$media_file" != "$XEMU_GAMES_DIR/"* ]]; then
			err "Discovered media escaped the registered games directory."
			return 1
		fi

		filename=${media_file##*/}
		relative_path=${media_file#"$XEMU_GAMES_DIR/"}

		if ! format=$(media_format "$filename"); then
			continue
		fi

		if ! title=$(display_title "$filename"); then
			err "Unable to derive a display title: $filename"
			return 1
		fi

		if ! size_bytes=$(stat -c '%s' -- "$media_file"); then
			warn "Unable to read media size; skipping: $media_file"
			continue
		fi

		if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
			warn "Invalid media size; skipping: $media_file"
			continue
		fi

		if ! modified_epoch=$(stat -c '%Y' -- "$media_file"); then
			warn "Unable to read media modification time; skipping: $media_file"
			continue
		fi

		if ! modified_utc=$(format_modification_time "$modified_epoch"); then
			warn "Unable to format media modification time; skipping: $media_file"
			continue
		fi

		if ! record_id=$(stable_record_id "xemu" "$relative_path"); then
			return 1
		fi

		filename=$(sanitize_tsv_value "$filename")
		relative_path=$(sanitize_tsv_value "$relative_path")
		title=$(sanitize_tsv_value "$title")

		printf '%s\t%s\txbox\txemu\t%s\t%s\t%s\t%s\t%s\t\t\t\t\t\n' \
			"$record_id" \
			"$title" \
			"$filename" \
			"$relative_path" \
			"$format" \
			"$size_bytes" \
			"$modified_utc" >>"$DISCOVERED_GAMES_FILE"

		DISCOVERED_GAME_COUNT=$((DISCOVERED_GAME_COUNT + 1))
	done <"$sorted_file"
}

merge_games() {
	local body_file
	local sorted_file

	body_file="$TEMP_DIR/games.body.tsv"
	sorted_file="$TEMP_DIR/games.body.sorted.tsv"

	if ! awk \
		-F '\t' \
		-v OFS='\t' '
			NR == FNR {
				if (FNR == 1)
					next

				old_row[$1] = $0
				old_sha1[$1] = $10
				old_status[$1] = $11
				old_config[$1] = $12
				old_reshade[$1] = $13
				old_notes[$1] = $14
				next
			}
			FNR == 1 {
				next
			}
			{
				if ($1 in old_row) {
					$10 = old_sha1[$1]
					$11 = old_status[$1]
					$12 = old_config[$1]
					$13 = old_reshade[$1]
					$14 = old_notes[$1]
				}

				seen[$1] = 1
				print
			}
			END {
				for (id in old_row) {
					if (!(id in seen))
						print old_row[id]
				}
			}
		' "$OLD_GAMES_FILE" "$DISCOVERED_GAMES_FILE" >"$body_file"; then
		err "Unable to merge games.tsv."
		return 1
	fi

	if ! LC_ALL=C sort -t $'\t' -k1,1 -- "$body_file" >"$sorted_file"; then
		err "Unable to sort games.tsv."
		return 1
	fi

	{
		printf '%s\n' "$GAME_HEADER"
		cat "$sorted_file"
	} >"$MERGED_GAMES_FILE"

	validate_manifest "$MERGED_GAMES_FILE" 14
}

build_emulator_record() {
	local install_status

	if [[ -d "$XEMU_ROOT" ]]; then
		install_status="installed"
	else
		install_status="missing"
	fi

	{
		printf '%s\n' "$EMULATOR_HEADER"
		printf 'xemu\txbox\txemu\t%s\temulators/xemu/configs\t\n' \
			"$install_status"
	} >"$DISCOVERED_EMULATORS_FILE"
}

merge_emulators() {
	local body_file
	local sorted_file

	body_file="$TEMP_DIR/emulators.body.tsv"
	sorted_file="$TEMP_DIR/emulators.body.sorted.tsv"

	if ! awk \
		-F '\t' \
		-v OFS='\t' '
			NR == FNR {
				if (FNR == 1)
					next

				old_row[$1] = $0
				old_notes[$1] = $6
				next
			}
			FNR == 1 {
				next
			}
			{
				if ($1 in old_row)
					$6 = old_notes[$1]

				seen[$1] = 1
				print
			}
			END {
				for (id in old_row) {
					if (!(id in seen))
						print old_row[id]
				}
			}
		' "$OLD_EMULATORS_FILE" "$DISCOVERED_EMULATORS_FILE" >"$body_file"; then
		err "Unable to merge emulators.tsv."
		return 1
	fi

	if ! LC_ALL=C sort -t $'\t' -k1,1 -- "$body_file" >"$sorted_file"; then
		err "Unable to sort emulators.tsv."
		return 1
	fi

	{
		printf '%s\n' "$EMULATOR_HEADER"
		cat "$sorted_file"
	} >"$MERGED_EMULATORS_FILE"

	validate_manifest "$MERGED_EMULATORS_FILE" 6
}

build_locations_manifest() {
	{
		printf '%s\n' "$LOCATION_HEADER"
		printf 'gaming.archive\t%s\n' "$GAMING_SETUP_BACKUP_ROOT"
		printf 'gaming.repository\t%s\n' "$GAMING_SETUP_REPO"
		printf 'xemu.configs\t%s\n' "$XEMU_CONFIG_DIR"
		printf 'xemu.games\t%s\n' "$XEMU_GAMES_DIR"
		printf 'xemu.root\t%s\n' "$XEMU_ROOT"

		if [[ -n "$XEMU_GLOBAL_CONFIG" ]]; then
			printf 'xemu.global_config\t%s\n' "$XEMU_GLOBAL_CONFIG"
		fi
	} >"$LOCATIONS_CANDIDATE_FILE"
}

# ---------- Configuration capture ----------
approved_config_extension() {
	local file_path
	file_path=${1,,}

	case "$file_path" in
	*.toml | *.ini | *.cfg | *.conf | *.json | *.yaml | *.yml)
		return
		;;
	esac

	return 1
}

add_plan() {
	local label
	local source
	local destination
	local action

	label=$1
	source=$2
	destination=$3

	if [[ ! -f "$destination" ]]; then
		action="create"
	elif cmp -s -- "$source" "$destination"; then
		action="unchanged"
	else
		action="update"
	fi

	PLAN_LABELS+=("$label")
	PLAN_SOURCES+=("$source")
	PLAN_DESTINATIONS+=("$destination")
	PLAN_ACTIONS+=("$action")

	if [[ "$action" != "unchanged" ]]; then
		PLANNED_CHANGE_COUNT=$((PLANNED_CHANGE_COUNT + 1))
	fi
}

add_config_plan() {
	local source
	local destination
	local size_bytes

	source=$1
	destination=$2

	if [[ ! -f "$source" || -L "$source" ]]; then
		return
	fi

	if ! approved_config_extension "$source"; then
		return
	fi

	if ! size_bytes=$(stat -c '%s' -- "$source"); then
		warn "Unable to inspect configuration file: $source"
		return
	fi

	if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
		warn "Invalid configuration size: $source"
		return
	fi

	if ((size_bytes > MAX_CONFIG_BYTES)); then
		warn "Skipping oversized configuration file: $source"
		return
	fi

	add_plan "configuration" "$source" "$destination"
	DISCOVERED_CONFIG_COUNT=$((DISCOVERED_CONFIG_COUNT + 1))
}

discover_configs() {
	local unsorted_file
	local sorted_file
	local source_file
	local relative_path
	local destination

	if [[ -n "$XEMU_GLOBAL_CONFIG" ]]; then
		if [[ ! -f "$XEMU_GLOBAL_CONFIG" ]]; then
			warn "Configured global xemu config was not found: $XEMU_GLOBAL_CONFIG"
		elif [[ "${XEMU_GLOBAL_CONFIG,,}" != *.toml ]]; then
			warn "Configured global xemu config is not TOML: $XEMU_GLOBAL_CONFIG"
		else
			add_config_plan \
				"$XEMU_GLOBAL_CONFIG" \
				"$GAMING_SETUP_REPO/emulators/xemu/configs/global/${XEMU_GLOBAL_CONFIG##*/}"
		fi
	fi

	if [[ ! -d "$XEMU_CONFIG_DIR" ]]; then
		info "xemu config directory was not found: $XEMU_CONFIG_DIR"
		return
	fi

	unsorted_file="$TEMP_DIR/configs.unsorted"
	sorted_file="$TEMP_DIR/configs.sorted"

	if ! find -P "$XEMU_CONFIG_DIR" \
		-type f \
		\( \
		-iname '*.toml' -o \
		-iname '*.ini' -o \
		-iname '*.cfg' -o \
		-iname '*.conf' -o \
		-iname '*.json' -o \
		-iname '*.yaml' -o \
		-iname '*.yml' \
		\) \
		-print0 >"$unsorted_file"; then
		err "Unable to inspect the xemu config directory."
		return 1
	fi

	if ! LC_ALL=C sort -z -- "$unsorted_file" >"$sorted_file"; then
		err "Unable to sort configuration files."
		return 1
	fi

	while IFS= read -r -d '' source_file; do
		if [[ "$source_file" != "$XEMU_CONFIG_DIR/"* ]]; then
			err "Configuration file escaped the registered config directory."
			return 1
		fi

		relative_path=${source_file#"$XEMU_CONFIG_DIR/"}
		destination="$GAMING_SETUP_REPO/emulators/xemu/configs/$relative_path"

		add_config_plan "$source_file" "$destination"
	done <"$sorted_file"
}

# ---------- Capture plan ----------
prepare_capture_plan() {
	PLAN_LABELS=()
	PLAN_SOURCES=()
	PLAN_DESTINATIONS=()
	PLAN_ACTIONS=()

	DISCOVERED_GAME_COUNT=0
	DISCOVERED_CONFIG_COUNT=0
	PLANNED_CHANGE_COUNT=0

	if ! prepare_games_manifest ||
		! prepare_emulators_manifest ||
		! validate_manifest "$OLD_GAMES_FILE" 14 ||
		! validate_manifest "$OLD_EMULATORS_FILE" 6 ||
		! discover_games ||
		! merge_games ||
		! build_emulator_record ||
		! merge_emulators ||
		! build_locations_manifest ||
		! discover_configs; then
		return 1
	fi

	add_plan "games manifest" "$MERGED_GAMES_FILE" "$GAMES_MANIFEST"
	add_plan "emulator manifest" "$MERGED_EMULATORS_FILE" "$EMULATORS_MANIFEST"
	add_plan "local locations" "$LOCATIONS_CANDIDATE_FILE" "$LOCATIONS_MANIFEST"
}

print_capture_plan() {
	local index

	section "Capture plan"

	printf '  %-23s %s\n' "Repository:" "$GAMING_SETUP_REPO"
	printf '  %-23s %s\n' "Registered emulator:" "xemu"
	printf '  %-23s %s\n' "xemu installation:" \
		"$([[ -d "$XEMU_ROOT" ]] && printf detected || printf missing)"
	printf '  %-23s %s\n' "Games directory:" "$XEMU_GAMES_DIR"
	printf '  %-23s %d\n' "Media discovered:" "$DISCOVERED_GAME_COUNT"
	printf '  %-23s %d\n' "Configs discovered:" "$DISCOVERED_CONFIG_COUNT"
	printf '  %-23s %d\n' "Planned changes:" "$PLANNED_CHANGE_COUNT"

	printf '\n%b%-12s %s%b\n' "$BOLD" "Action" "Destination" "$RESET"
	printf '%-12s %s\n' \
		"────────────" \
		"────────────────────────────────────────────────────────"

	for index in "${!PLAN_LABELS[@]}"; do
		printf '%-12s %s\n' \
			"${PLAN_ACTIONS[$index]^^}" \
			"${PLAN_DESTINATIONS[$index]}"
	done
}

# ---------- Writes ----------
atomic_copy() {
	local source
	local destination
	local destination_directory
	local temporary_file

	source=$1
	destination=$2
	destination_directory=${destination%/*}
	temporary_file=""

	if ! path_is_within "$destination" "$GAMING_SETUP_REPO"; then
		err "Refusing to write outside the gaming metadata repository."
		return 1
	fi

	if ! mkdir -p -- "$destination_directory"; then
		err "Unable to create destination directory: $destination_directory"
		return 1
	fi

	if ! temporary_file=$(
		mktemp "$destination_directory/.gamecapture.XXXXXXXX"
	); then
		err "Unable to create a temporary destination file."
		return 1
	fi

	if ! cp -- "$source" "$temporary_file"; then
		rm -f -- "$temporary_file"
		err "Unable to stage update: $destination"
		return 1
	fi

	if [[ -f "$destination" ]] &&
		cmp -s -- "$temporary_file" "$destination"; then
		rm -f -- "$temporary_file"
		return
	fi

	if ! mv -f -- "$temporary_file" "$destination"; then
		rm -f -- "$temporary_file"
		err "Unable to install update: $destination"
		return 1
	fi
}

apply_capture_plan() {
	local index
	local action
	local changed_count

	changed_count=0

	section "Capture"

	for index in "${!PLAN_LABELS[@]}"; do
		action=${PLAN_ACTIONS[$index]}

		if [[ "$action" == "unchanged" ]]; then
			ok "Current: ${PLAN_DESTINATIONS[$index]}"
			continue
		fi

		if ! atomic_copy \
			"${PLAN_SOURCES[$index]}" \
			"${PLAN_DESTINATIONS[$index]}"; then
			return 1
		fi

		ok "${action^}: ${PLAN_DESTINATIONS[$index]}"
		changed_count=$((changed_count + 1))
	done

	if ((changed_count == 0)); then
		info "Capture completed with no repository changes."
	else
		ok "Capture completed with $changed_count file change(s)."
	fi
}

print_dry_run_plan() {
	local index
	local action

	section "Dry-run"

	for index in "${!PLAN_LABELS[@]}"; do
		action=${PLAN_ACTIONS[$index]}

		case "$action" in
		create)
			dry_run_message "Create ${PLAN_DESTINATIONS[$index]}"
			;;
		update)
			dry_run_message "Update ${PLAN_DESTINATIONS[$index]}"
			;;
		unchanged)
			dry_run_message "Leave unchanged ${PLAN_DESTINATIONS[$index]}"
			;;
		esac
	done

	ok "Dry-run completed without persistent changes."
}

# ---------- Status ----------
print_git_status() {
	local status_output

	if ! status_output=$(
		git -C "$GAMING_SETUP_REPO" status --short --untracked-files=all
	); then
		err "Unable to read repository Git status."
		return 1
	fi

	section "Repository Git status"

	if [[ -z "$status_output" ]]; then
		ok "Working tree is clean."
	else
		printf '%s\n' "$status_output"
	fi

	if ! git -C "$GAMING_SETUP_REPO" \
		check-ignore -q manifests/locations.local.tsv; then
		warn "manifests/locations.local.tsv is not currently ignored by Git."
	fi
}

mode_status() {
	if ! prepare_capture_plan; then
		return 1
	fi

	print_capture_plan

	if ! print_git_status; then
		return 1
	fi

	if ((PLANNED_CHANGE_COUNT == 0)); then
		ok "Captured metadata and approved configs are current."
	else
		warn "$PLANNED_CHANGE_COUNT file change(s) would be made by capture."
	fi
}

mode_capture() {
	if ! prepare_capture_plan; then
		return 1
	fi

	print_capture_plan
	apply_capture_plan
}

mode_dry_run() {
	if ! prepare_capture_plan; then
		return 1
	fi

	print_capture_plan
	print_dry_run_plan
}

# ---------- Archive ----------
archive_path_allowed() {
	local relative_path
	local lowercase

	relative_path=$1
	lowercase=${relative_path,,}

	case "/$lowercase/" in
	*/.git/* | */bios/* | */mcpx/* | */firmware/* | */hdd/* | \
		*/cache/* | */caches/* | */save/* | */saves/* | \
		*/screenshot/* | */screenshots/* | */archives/*)
		return 1
		;;
	esac

	case "$lowercase" in
	*.exe | *.dll | *.iso | *.xiso | *.xbe | *.xex | *.chd | \
		*.rom | *.img | *.bin | *.vhd | *.vhdx | *.log | *.zip | \
		*.7z | *.rar | *.tar | *.gz | *.bz2 | *.xz)
		return 1
		;;
	esac

	case "$relative_path" in
	README.md | \
		docs/* | \
		manifests/* | \
		templates/* | \
		emulators/README.md | \
		emulators/xemu/README.md | \
		emulators/xemu/configs/* | \
		emulators/xemu/titles/* | \
		reshade/README.md | \
		reshade/presets/*) ;;
	*)
		return 1
		;;
	esac

	case "$lowercase" in
	*.md | *.txt | *.tsv | *.json | *.toml | *.ini | *.cfg | \
		*.conf | *.yaml | *.yml | *.fx | *.fxh)
		return
		;;
	esac

	return 1
}

stage_archive_file() {
	local source
	local relative_path
	local staging_root
	local destination
	local size_bytes

	source=$1
	relative_path=$2
	staging_root=$3

	if ! archive_path_allowed "$relative_path"; then
		return
	fi

	if [[ ! -f "$source" || -L "$source" ]]; then
		return
	fi

	if ! size_bytes=$(stat -c '%s' -- "$source"); then
		warn "Unable to inspect archive candidate: $relative_path"
		return
	fi

	if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
		warn "Invalid archive candidate size: $relative_path"
		return
	fi

	if ((size_bytes > MAX_ARCHIVE_FILE_BYTES)); then
		warn "Skipping oversized archive candidate: $relative_path"
		return
	fi

	destination="$staging_root/$relative_path"

	if ! mkdir -p -- "${destination%/*}"; then
		err "Unable to create archive staging directory."
		return 1
	fi

	if ! cp -- "$source" "$destination"; then
		err "Unable to stage archive file: $relative_path"
		return 1
	fi
}

build_archive_staging_tree() {
	local staging_root
	local source_root
	local source_file
	local relative_path
	local paths_file
	local sorted_file
	local -a source_roots

	staging_root=$1
	paths_file="$TEMP_DIR/archive.unsorted"
	sorted_file="$TEMP_DIR/archive.sorted"

	if [[ -f "$GAMING_SETUP_REPO/README.md" ]]; then
		if ! stage_archive_file \
			"$GAMING_SETUP_REPO/README.md" \
			"README.md" \
			"$staging_root"; then
			return 1
		fi
	fi

	source_roots=(
		"$GAMING_SETUP_REPO/docs"
		"$GAMING_SETUP_REPO/manifests"
		"$GAMING_SETUP_REPO/templates"
		"$GAMING_SETUP_REPO/emulators"
		"$GAMING_SETUP_REPO/reshade"
	)

	: >"$paths_file"

	for source_root in "${source_roots[@]}"; do
		[[ -d "$source_root" ]] || continue

		if ! find -P "$source_root" -type f -print0 >>"$paths_file"; then
			err "Unable to inspect archive source: $source_root"
			return 1
		fi
	done

	if ! LC_ALL=C sort -z -- "$paths_file" >"$sorted_file"; then
		err "Unable to sort archive candidates."
		return 1
	fi

	while IFS= read -r -d '' source_file; do
		if [[ "$source_file" != "$GAMING_SETUP_REPO/"* ]]; then
			err "Archive candidate escaped the repository root."
			return 1
		fi

		relative_path=${source_file#"$GAMING_SETUP_REPO/"}

		if ! stage_archive_file \
			"$source_file" \
			"$relative_path" \
			"$staging_root"; then
			return 1
		fi
	done <"$sorted_file"
}

create_zip_archive() {
	local staging_root
	local archive_file
	local staging_windows
	local archive_windows
	local output
	local status

	staging_root=$1
	archive_file=$2

	if command -v zip >/dev/null 2>&1; then
		if output=$(
			cd -- "$staging_root" &&
				zip -q -r "$archive_file" . 2>&1
		); then
			return
		else
			status=$?
		fi

		err "zip failed with exit status $status."

		if [[ -n "$output" ]]; then
			printf '%s\n' "$output" >&2
		fi

		return "$status"
	fi

	if ! command -v powershell.exe >/dev/null 2>&1 ||
		! command -v cygpath >/dev/null 2>&1; then
		err "Neither zip nor the PowerShell archive fallback is available."
		return 1
	fi

	if ! staging_windows=$(cygpath -w -- "$staging_root"); then
		err "Unable to convert the staging path for PowerShell."
		return 1
	fi

	if ! archive_windows=$(cygpath -w -- "$archive_file"); then
		err "Unable to convert the archive path for PowerShell."
		return 1
	fi

	# PowerShell variables are intentionally protected from Bash expansion.
	# shellcheck disable=SC2016
	if output=$(
		powershell.exe \
			-NoLogo \
			-NoProfile \
			-NonInteractive \
			-Command \
			'$source = Join-Path $args[0] "*"; Compress-Archive -Path $source -DestinationPath $args[1] -CompressionLevel Optimal -Force' \
			"$staging_windows" \
			"$archive_windows" 2>&1
	); then
		return
	else
		status=$?
	fi

	err "PowerShell Compress-Archive failed with exit status $status."

	if [[ -n "$output" ]]; then
		printf '%s\n' "$output" >&2
	fi

	return "$status"
}

mode_archive() {
	local archive_directory
	local staging_root
	local timestamp
	local final_archive
	local temporary_archive
	local suffix

	archive_directory="$GAMING_SETUP_BACKUP_ROOT/archives"
	staging_root="$TEMP_DIR/archive-staging"
	suffix=0

	if ! timestamp=$(date -u '+%Y%m%d_%H%M%S'); then
		err "Unable to generate the archive timestamp."
		return 1
	fi

	final_archive="$archive_directory/gaming-setup-WIN_${timestamp}.zip"

	while [[ -e "$final_archive" ]]; do
		suffix=$((suffix + 1))
		final_archive="$archive_directory/gaming-setup-WIN_${timestamp}_$suffix.zip"
	done

	section "Archive"

	info "Repository: $GAMING_SETUP_REPO"
	info "Destination: $final_archive"

	if ! mkdir -p -- "$staging_root"; then
		err "Unable to create archive staging directory."
		return 1
	fi

	if ! build_archive_staging_tree "$staging_root"; then
		return 1
	fi

	if ! mkdir -p -- "$archive_directory"; then
		err "Unable to create archive directory: $archive_directory"
		return 1
	fi

	if ! temporary_archive=$(
		mktemp "$archive_directory/.gaming-setup-WIN.XXXXXXXX.zip"
	); then
		err "Unable to create a temporary archive path."
		return 1
	fi

	if ! rm -f -- "$temporary_archive"; then
		err "Unable to prepare the temporary archive path."
		return 1
	fi

	if ! create_zip_archive "$staging_root" "$temporary_archive"; then
		rm -f -- "$temporary_archive"
		return 1
	fi

	if [[ ! -s "$temporary_archive" ]]; then
		rm -f -- "$temporary_archive"
		err "The generated archive is empty."
		return 1
	fi

	if ! mv -- "$temporary_archive" "$final_archive"; then
		rm -f -- "$temporary_archive"
		err "Unable to install the completed archive."
		return 1
	fi

	ok "Archive created: $final_archive"
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
		return
	fi

	if ! validate_dependencies ||
		! initialize_paths ||
		! validate_repository ||
		! initialize_temp_directory; then
		return 1
	fi

	install_signal_handlers

	if [[ "$MODE" == "menu" ]]; then
		if ! choose_mode; then
			return 1
		fi
	fi

	section "Gaming setup"

	info "Mode: $MODE"
	info "Repository: $GAMING_SETUP_REPO"
	info "xemu root: $XEMU_ROOT"

	case "$MODE" in
	status)
		if ! mode_status; then
			return 1
		fi
		;;
	capture)
		if ! mode_capture; then
			return 1
		fi
		;;
	dry-run)
		if ! mode_dry_run; then
			return 1
		fi
		;;
	archive)
		if ! mode_archive; then
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
