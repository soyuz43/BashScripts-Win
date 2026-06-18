SHELL := bash
.DEFAULT_GOAL := help

REPO_DIR := $(CURDIR)

INSTALL := $(REPO_DIR)/install.sh
DOTFILES_MANAGER := $(REPO_DIR)/modify/dotfiles-manager.sh

SCRIPT_DIRS := \
	$(REPO_DIR) \
	$(REPO_DIR)/create \
	$(REPO_DIR)/execute \
	$(REPO_DIR)/inspect \
	$(REPO_DIR)/modify \
	$(REPO_DIR)/experimental

SHELL_SCRIPTS := $(shell find "$(REPO_DIR)" -type f -name '*.sh')

EXECUTABLE_COMMANDS := \
	$(REPO_DIR)/create/issue-branch \
	$(REPO_DIR)/inspect/genealogy \
	$(REPO_DIR)/inspect/provenance

.PHONY: help new bootstrap maintain upgrade check restore status capture chmod lint format test clean tree

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
		'  make chmod      Make command scripts executable' \
		'  make lint       Run ShellCheck on shell scripts' \
		'  make format     Run shfmt in write mode on shell scripts' \
		'  make test       Bash syntax check all shell scripts' \
		'  make tree       Show repository tree' \
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
	@find "$(REPO_DIR)" -type f -name '*.sh' -exec chmod +x -- {} +
	@for file in $(EXECUTABLE_COMMANDS); do \
		if [[ -f "$$file" ]]; then \
			chmod +x -- "$$file"; \
		fi; \
	done

lint:
	@shellcheck $(SHELL_SCRIPTS)

format:
	@shfmt -w $(SHELL_SCRIPTS)

test:
	@for file in $(SHELL_SCRIPTS); do \
		printf 'Checking %s\n' "$$file"; \
		bash -n "$$file"; \
	done

tree:
	@tree -C --dirsfirst "$(REPO_DIR)"

clean:
	@rm -f "$$HOME"/bashscripts-install_*.log