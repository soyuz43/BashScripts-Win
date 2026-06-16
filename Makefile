SHELL := bash
.DEFAULT_GOAL := help

REPO_DIR := $(CURDIR)
INSTALL := $(REPO_DIR)/install.sh
DOTFILES_MANAGER := $(REPO_DIR)/dotfiles-manager.sh

.PHONY: help new bootstrap maintain upgrade check restore status capture chmod lint format test clean

help:
	@printf '%s\n' \
		'BashScripts-WIN Makefile' \
		'' \
		'Common commands:' \
		'  make new        First-time machine setup: install + restore dotfiles' \
		'  make bootstrap  Run install.sh --bootstrap' \
		'  make maintain   Run install.sh --maintain' \
		'  make upgrade    Run install.sh --upgrade' \
		'  make check      Run install.sh --check' \
		'' \
		'Dotfiles:' \
		'  make restore    Restore managed dotfiles' \
		'  make status     Check managed dotfiles status' \
		'  make capture    Capture current machine config into dotfiles repo' \
		'' \
		'Development:' \
		'  make chmod      Make shell scripts executable' \
		'  make lint       Run ShellCheck' \
		'  make format     Run shfmt in write mode' \
		'  make test       Bash syntax check all shell scripts' \
		'  make clean      Remove temporary local logs'

new: bootstrap restore status

bootstrap:
	@bash "$(INSTALL)" --bootstrap

maintain:
	@bash "$(INSTALL)" --maintain

upgrade:
	@bash "$(INSTALL)" --upgrade

check:
	@bash "$(INSTALL)" --check

restore:
	@DOTFILES_DIR="$${DOTFILES_DIR:-$$HOME/dotfiles}" bash "$(DOTFILES_MANAGER)" --restore

status:
	@DOTFILES_DIR="$${DOTFILES_DIR:-$$HOME/dotfiles}" bash "$(DOTFILES_MANAGER)" --status

capture:
	@DOTFILES_DIR="$${DOTFILES_DIR:-$$HOME/dotfiles}" bash "$(DOTFILES_MANAGER)" --capture

chmod:
	@find "$(REPO_DIR)" -maxdepth 1 -type f -name '*.sh' -exec chmod +x -- {} +

lint:
	@shellcheck ./*.sh

format:
	@shfmt -w ./*.sh

test:
	@for file in ./*.sh; do \
		printf 'Checking %s\n' "$$file"; \
		bash -n "$$file"; \
	done

clean:
	@rm -f "$$HOME"/bashscripts-install_*.log