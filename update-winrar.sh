#!/usr/bin/env bash

set -euo pipefail

echo "[INFO] Removing old WinRAR if present..."

winget uninstall --id RARLab.WinRAR -e || true

echo "[INFO] Installing latest WinRAR..."

winget install --id RARLab.WinRAR -e --silent \
	--accept-package-agreements \
	--accept-source-agreements

echo "[OK] WinRAR installation complete."
