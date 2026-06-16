#!/usr/bin/env bash
# install.sh
# BashScripts-WIN bootstrap, maintenance, and environment checker.

set -euo pipefail

# ---------- ANSI ----------
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

# ---------- Config ----------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_REPO="git@github.com:soyuz43/dotfiles-WIN.git"
DOTFILES_DIR="$HOME/dotfiles"
WINDOWS_TERMINAL_SETTINGS_SRC="$DOTFILES_DIR/windows-terminal/settings.json"

MODE="menu"

PACKAGES=(
	"Git.Git:git"
	"GitHub.cli:gh"
	"junegunn.fzf:fzf"
	"mvdan.shfmt:shfmt"
	"koalaman.shellcheck:shellcheck"
)

# ---------- UI ----------
info() { printf "%b[INFO]%b %s\n" "$BLUE" "$RESET" "$*"; }
ok() { printf "%b[OK]%b   %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$*"; }
err() { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$*" >&2; }

section() {
	printf "\n%b==>%b %s\n" "$BOLD$CYAN" "$RESET" "$*"
}

usage() {
	cat <<USAGE
Usage:
  bash install.sh
  bash install.sh --bootstrap
  bash install.sh --maintain
  bash install.sh --upgrade
  bash install.sh --check
  bash install.sh --help

Modes:
  --bootstrap   First-time setup: install deps, auth GitHub, clone dotfiles, configure bashrc
  --maintain    Install missing deps, chmod scripts, print status
  --upgrade     Upgrade known deps, install missing deps, chmod scripts, print status
  --check       Read-only diagnostics
  --help        Show this help
USAGE
}

confirm() {
	local prompt="$1"
	local answer

	printf "%b%s%b [y/N] " "$YELLOW" "$prompt" "$RESET"
	read -r answer

	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	*) return 1 ;;
	esac
}

choose_mode() {
	local choice

	printf "\n%bBashScripts-WIN%b\n" "$BOLD" "$RESET"
	printf "%b%s%b\n\n" "$DIM" "Select an install mode." "$RESET"

	printf "  %b1%b  bootstrap  %bFirst-time setup: auth GitHub, clone dotfiles, configure bashrc%b\n" "$GREEN" "$RESET" "$DIM" "$RESET"
	printf "  %b2%b  maintain   %bInstall missing deps, chmod scripts, print status%b\n" "$BLUE" "$RESET" "$DIM" "$RESET"
	printf "  %b3%b  upgrade    %bUpgrade known deps, install missing deps, print status%b\n" "$YELLOW" "$RESET" "$DIM" "$RESET"
	printf "  %b4%b  check      %bRead-only diagnostics%b\n" "$CYAN" "$RESET" "$DIM" "$RESET"
	printf "  %bq%b  quit\n\n" "$RED" "$RESET"

	printf "%bChoice:%b " "$BOLD" "$RESET"
	read -r choice

	case "$choice" in
	1 | bootstrap) MODE="bootstrap" ;;
	2 | maintain) MODE="maintain" ;;
	3 | upgrade) MODE="upgrade" ;;
	4 | check) MODE="check" ;;
	q | Q | quit | exit) exit 0 ;;
	*)
		err "Invalid choice: $choice"
		exit 1
		;;
	esac
}

# ---------- Args ----------
parse_args() {
	case "${1:-}" in
	"") MODE="menu" ;;
	--bootstrap) MODE="bootstrap" ;;
	--maintain) MODE="maintain" ;;
	--upgrade) MODE="upgrade" ;;
	--check) MODE="check" ;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		err "Unknown option: $1"
		usage
		exit 1
		;;
	esac
}

# ---------- Helpers ----------
has_cmd() {
	command -v "$1" >/dev/null 2>&1
}

cmd_path() {
	command -v "$1" 2>/dev/null || true
}

cmd_version() {
	local cmd="$1"

	case "$cmd" in
	git) git --version 2>/dev/null || true ;;
	gh) gh --version 2>/dev/null | head -n1 || true ;;
	fzf) fzf --version 2>/dev/null || true ;;
	shfmt) shfmt --version 2>/dev/null || true ;;
	shellcheck) shellcheck --version 2>/dev/null | awk -F': ' '/version:/ {print "ShellCheck " $2}' || true ;;
	winget) winget --version 2>/dev/null || true ;;
	*) "$cmd" --version 2>/dev/null | head -n1 || true ;;
	esac
}

to_windows_path() {
	local path="$1"

	if has_cmd cygpath; then
		cygpath -w "$path"
	else
		printf "%s" "$path"
	fi
}

to_unix_path() {
	local path="$1"

	if has_cmd cygpath; then
		cygpath -u "$path"
	else
		printf "%s" "$path"
	fi
}

windows_terminal_settings_dst() {
	if [[ -z "${LOCALAPPDATA:-}" ]]; then
		return 1
	fi

	printf "%s/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json" "$(to_unix_path "$LOCALAPPDATA")"
}

install_package() {
	local id="$1"
	local cmd="$2"

	if has_cmd "$cmd"; then
		ok "$cmd already installed"
		return 0
	fi

	if ! has_cmd winget; then
		warn "$cmd missing; winget unavailable"
		return 1
	fi

	info "Installing $cmd via winget"
	winget install --id "$id" -e \
		--accept-package-agreements \
		--accept-source-agreements
}

upgrade_package() {
	local id="$1"
	local cmd="$2"

	if ! has_cmd winget; then
		warn "winget unavailable; cannot upgrade $cmd"
		return 1
	fi

	if has_cmd "$cmd"; then
		info "Upgrading $cmd via winget"
		winget upgrade --id "$id" -e \
			--accept-package-agreements \
			--accept-source-agreements || warn "$cmd may already be current or unmanaged by winget"
	else
		warn "$cmd missing; installing instead"
		install_package "$id" "$cmd"
	fi
}

chmod_scripts() {
	info "Making shell scripts executable"
	find "$REPO_DIR" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
	ok "Script permissions updated"
}

print_dependency_status() {
	local pair id cmd path version

	printf "%b%-14s %-9s %s%b\n" "$BOLD" "Command" "Status" "Details" "$RESET"
	printf "%-14s %-9s %s\n" "-------" "------" "-------"

	for pair in "${PACKAGES[@]}" "Microsoft.WinGet.Client:winget"; do
		id="${pair%%:*}"
		cmd="${pair##*:}"

		if has_cmd "$cmd"; then
			path="$(cmd_path "$cmd")"
			version="$(cmd_version "$cmd")"
			printf "%-14s %b%-9s%b %s%s%s\n" "$cmd" "$GREEN" "OK" "$RESET" "$path" "${version:+ | }" "$version"
		else
			printf "%-14s %b%-9s%b winget id: %s\n" "$cmd" "$YELLOW" "MISSING" "$RESET" "$id"
		fi
	done
}

ensure_github_auth() {
	if ! has_cmd gh; then
		err "GitHub CLI is missing; cannot authenticate"
		return 1
	fi

	if gh auth status >/dev/null 2>&1; then
		ok "GitHub CLI is authenticated"
		return 0
	fi

	warn "GitHub CLI is not authenticated"
	printf "%b%s%b\n" "$DIM" "This opens GitHub's browser/device flow. Your security key can be used there if GitHub prompts for it." "$RESET"

	if ! confirm "Authenticate GitHub CLI now?"; then
		err "Bootstrap stopped before cloning dotfiles"
		return 1
	fi

	gh auth login

	if gh auth status >/dev/null 2>&1; then
		ok "GitHub CLI authentication complete"
	else
		err "GitHub CLI still not authenticated"
		return 1
	fi
}

dotfiles_remote_ok() {
	local expected="$DOTFILES_REPO"
	local actual=""

	[[ -d "$DOTFILES_DIR/.git" ]] || return 0

	actual="$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)"

	if [[ "$actual" == "$expected" ]]; then
		ok "dotfiles remote matches: $actual"
		return 0
	fi

	warn "dotfiles repo exists, but origin differs"
	printf "  Expected: %s\n" "$expected"
	printf "  Actual:   %s\n" "${actual:-none}"

	if confirm "Continue using existing dotfiles repo?"; then
		return 0
	fi

	err "Bootstrap stopped because dotfiles remote did not match"
	return 1
}

clone_dotfiles() {
	if [[ -d "$DOTFILES_DIR/.git" ]]; then
		ok "dotfiles repo already exists: $DOTFILES_DIR"
		dotfiles_remote_ok
		return 0
	fi

	if [[ -e "$DOTFILES_DIR" ]]; then
		err "Refusing to overwrite existing non-repo path: $DOTFILES_DIR"
		return 1
	fi

	info "Cloning dotfiles"
	git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
	ok "dotfiles cloned: $DOTFILES_DIR"

	dotfiles_remote_ok
}

restore_windows_terminal_settings() {
	local src="$WINDOWS_TERMINAL_SETTINGS_SRC"
	local dst
	local dst_dir
	local backup

	if ! dst="$(windows_terminal_settings_dst)"; then
		warn "LOCALAPPDATA is not set; skipping Windows Terminal settings restore"
		return 0
	fi

	dst_dir="$(dirname "$dst")"

	if [[ ! -f "$src" ]]; then
		warn "Windows Terminal settings backup not found: $src"
		printf "%b%s%b\n" "$DIM" "Expected dotfiles path: dotfiles-WIN/windows-terminal/settings.json" "$RESET"
		return 0
	fi

	if [[ ! -d "$dst_dir" ]]; then
		warn "Windows Terminal settings directory not found: $dst_dir"
		printf "%b%s%b\n" "$DIM" "Install or open Windows Terminal once, then rerun bootstrap." "$RESET"
		return 0
	fi

	if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
		ok "Windows Terminal settings already match dotfiles backup"
		return 0
	fi

	if [[ -f "$dst" ]]; then
		backup="$dst.local-backup.$(date +%Y%m%d-%H%M%S)"
		warn "Backing up existing Windows Terminal settings"
		cp "$dst" "$backup"
		ok "Backup created: $backup"
	fi

	cp "$src" "$dst"
	ok "Windows Terminal settings restored from dotfiles"
}

create_real_bashrc_symlink() {
	local target="$1"
	local link="$2"
	local target_win
	local link_win

	target_win="$(to_windows_path "$target")"
	link_win="$(to_windows_path "$link")"

	if has_cmd powershell.exe; then
		# shellcheck disable=SC2016
		powershell.exe -NoProfile -Command '
			param($Target, $Link)
			New-Item -ItemType SymbolicLink -Path $Link -Target $Target -Force | Out-Null
		' "$target_win" "$link_win"
	else
		ln -s "$target" "$link"
	fi

	[[ -L "$link" ]]
}

copy_bashrc_fallback() {
	local target="$1"
	local link="$2"

	warn "Real symlink creation failed"
	printf "%b%s%b\n" "$DIM" "Windows usually requires Administrator Git Bash or Developer Mode to create true symlinks." "$RESET"
	printf "  True symlink target: %s\n" "$target"
	printf "  Fallback action:     copy %s -> %s\n" "$target" "$link"
	printf "\n"
	printf "To create a true symlink later:\n"
	printf "  1. Enable Windows Developer Mode, or run Git Bash as Administrator\n"
	printf "  2. Run: bash install.sh --bootstrap\n"
	printf "\n"

	cp "$target" "$link"
	ok "$HOME/.bashrc copied from dotfiles bashrc fallback"
}

configure_bashrc_from_dotfiles() {
	local target="$1"
	local link="$2"

	if create_real_bashrc_symlink "$target" "$link"; then
		ok "$link symlink -> $(readlink "$link")"
		return 0
	fi

	copy_bashrc_fallback "$target" "$link"
}

link_bashrc() {
	local target
	local link
	local backup

	target="$DOTFILES_DIR/bashrc"
	link="$HOME/.bashrc"
	backup="$HOME/.bashrc.local-backup.$(date +%Y%m%d-%H%M%S)"

	if [[ ! -f "$target" ]]; then
		err "dotfiles bashrc not found: $target"
		return 1
	fi

	if [[ -L "$link" ]]; then
		local current_target

		if ! current_target="$(readlink "$link")"; then
			err "Failed to read existing bashrc symlink: $link"
			return 1
		fi

		if [[ "$current_target" == "$target" ]]; then
			ok "$HOME/.bashrc already linked correctly"
			return 0
		fi

		warn "$HOME/.bashrc is a symlink to: $current_target"
		printf "  New target: %s\n" "$target"

		if ! confirm "Replace existing symlink?"; then
			err "Bootstrap stopped before relinking bashrc"
			return 1
		fi

		rm "$link"
	elif [[ -f "$link" ]]; then
		if cmp -s "$link" "$target"; then
			warn "$HOME/.bashrc is a regular file matching dotfiles bashrc"
			printf "%b%s%b\n" "$DIM" "This is usable, but it is not a true symlink. Bootstrap can try to replace it with a symlink." "$RESET"
		else
			warn "$HOME/.bashrc exists as a regular file"
		fi

		printf "  Backup: %s\n" "$backup"
		printf "  Source: %s\n" "$target"
		printf "  Target: %s\n" "$link"

		if ! confirm "Backup existing bashrc and configure from dotfiles?"; then
			err "Bootstrap stopped before changing bashrc"
			return 1
		fi

		mv "$link" "$backup"
		ok "Backup created: $backup"
	elif [[ -e "$link" ]]; then
		err "$HOME/.bashrc exists but is not a regular file or symlink"
		return 1
	fi

	configure_bashrc_from_dotfiles "$target" "$link"
}

print_github_status() {
	if ! has_cmd gh; then
		warn "gh missing; cannot check GitHub auth"
		return 0
	fi

	if gh auth status >/dev/null 2>&1; then
		ok "GitHub CLI is authenticated"
	else
		warn "GitHub CLI is not authenticated"
	fi
}

print_dotfiles_status() {
	if [[ -d "$DOTFILES_DIR/.git" ]]; then
		ok "dotfiles repo exists: $DOTFILES_DIR"
		dotfiles_remote_ok
	else
		warn "dotfiles repo not found: $DOTFILES_DIR"
	fi

	if [[ -L "$HOME/.bashrc" ]]; then
		ok "$HOME/.bashrc symlink -> $(readlink "$HOME/.bashrc")"
	elif [[ -f "$HOME/.bashrc" ]]; then
		if [[ -f "$DOTFILES_DIR/bashrc" ]] && cmp -s "$HOME/.bashrc" "$DOTFILES_DIR/bashrc"; then
			warn "$HOME/.bashrc is a regular file copy of dotfiles bashrc"
			printf "%b%s%b\n" "$DIM" "Usable fallback. For a true symlink, enable Developer Mode or run Git Bash as Administrator, then run bootstrap again." "$RESET"
		else
			warn "$HOME/.bashrc exists but is not a symlink"
		fi
	else
		warn "$HOME/.bashrc does not exist"
	fi
}

print_windows_terminal_status() {
	local dst

	if ! dst="$(windows_terminal_settings_dst)"; then
		warn "LOCALAPPDATA is not set; cannot check Windows Terminal settings"
		return 0
	fi

	if [[ ! -f "$WINDOWS_TERMINAL_SETTINGS_SRC" ]]; then
		warn "Windows Terminal settings backup missing: $WINDOWS_TERMINAL_SETTINGS_SRC"
		return 0
	fi

	if [[ ! -f "$dst" ]]; then
		warn "Windows Terminal settings file not found: $dst"
		return 0
	fi

	if cmp -s "$WINDOWS_TERMINAL_SETTINGS_SRC" "$dst"; then
		ok "Windows Terminal settings match dotfiles backup"
	else
		warn "Windows Terminal settings differ from dotfiles backup"
	fi
}

print_restart_note() {
	printf "\n%bNext:%b restart Git Bash or run:\n" "$BOLD" "$RESET"
	printf "  source %s/.bashrc\n" "$HOME"
}

run_status() {
	section "Dependency status"
	print_dependency_status

	section "GitHub auth"
	print_github_status

	section "Dotfiles status"
	print_dotfiles_status

	section "Windows Terminal status"
	print_windows_terminal_status
}

run_install_missing() {
	section "Install missing dependencies"

	local failed=0
	local pair

	for pair in "${PACKAGES[@]}"; do
		if ! install_package "${pair%%:*}" "${pair##*:}"; then
			failed=1
		fi
	done

	if ((failed != 0)); then
		err "One or more dependencies could not be installed"
		return 1
	fi
}

run_upgrade_known() {
	section "Upgrade workflow dependencies"
	warn "Only known BashScripts-WIN dependencies will be upgraded."

	if ! confirm "Continue with upgrades?"; then
		warn "Upgrade cancelled"
		return 0
	fi

	local failed=0
	local pair

	for pair in "${PACKAGES[@]}"; do
		if ! upgrade_package "${pair%%:*}" "${pair##*:}"; then
			failed=1
		fi
	done

	if ((failed != 0)); then
		err "One or more dependencies could not be upgraded"
		return 1
	fi
}

# ---------- Modes ----------
mode_bootstrap() {
	section "Bootstrap"
	printf "%b%s%b\n" "$DIM" "First-time setup: dependencies, GitHub auth, dotfiles clone, terminal settings, bashrc symlink/copy fallback." "$RESET"

	run_install_missing

	section "Script permissions"
	chmod_scripts

	section "GitHub auth"
	ensure_github_auth

	section "Dotfiles clone"
	clone_dotfiles

	section "Windows Terminal settings"
	restore_windows_terminal_settings

	section "Bashrc configuration"
	link_bashrc

	run_status
	print_restart_note

	ok "Bootstrap complete"
}

mode_maintain() {
	run_install_missing

	section "Script permissions"
	chmod_scripts

	run_status

	ok "Maintain complete"
}

mode_upgrade() {
	run_upgrade_known

	section "Script permissions"
	chmod_scripts

	run_status

	ok "Upgrade complete"
}

mode_check() {
	run_status
	ok "Check complete"
}

# ---------- Main ----------
main() {
	parse_args "$@"

	if [[ "$MODE" == "menu" ]]; then
		choose_mode
	fi

	section "BashScripts-WIN"
	info "Mode: $MODE"
	info "Repo: $REPO_DIR"

	case "$MODE" in
	bootstrap) mode_bootstrap ;;
	maintain) mode_maintain ;;
	upgrade) mode_upgrade ;;
	check) mode_check ;;
	*)
		err "Unhandled mode: $MODE"
		exit 1
		;;
	esac
}

main "$@"
