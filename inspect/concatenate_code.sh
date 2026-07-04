#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# OUTPUT FILE (WITH TIMESTAMP)
# ------------------------------------------------------------

timestamp="$(date +"%Y-%m-%d_%H-%M-%S")"
output_file="code-${timestamp}.md"

temp_output="$(mktemp)"

cleanup() {
	rm -f "$temp_output"
}
trap cleanup EXIT

# ------------------------------------------------------------
# LANGUAGE MAP
# ------------------------------------------------------------

declare -A lang_map=(
	[js]="javascript" [jsx]="javascript" [mjs]="javascript"
	[go]="go" [cs]="csharp"
	[md]="markdown" [py]="python"
	[ps1]="powershell" [psd1]="powershell" [psm1]="powershell"
	[json]="json" [yaml]="yaml" [yml]="yaml"
)

# ------------------------------------------------------------
# FILE COLLECTION
# ------------------------------------------------------------

mapfile -d '' files < <(
	find . \
		-type f \( -name "*.js" -o -name "*.jsx" -o -name "*.mjs" -o -name "*.go" \
		-o -name "*.cs" -o -name "*.md" -o -name "*.py" \
		-o -name "*.ps1" -o -name "*.psd1" -o -name "*.psm1" \
		-o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \
		-o -name "*.pt" \) \
		! -path "*/.git/*" \
		! -path "*/node_modules/*" \
		! -path "*/venv/*" \
	    ! -path "*/.venv/*" \
	    ! -path "*/__pycache__/*" \
	    ! -path "*/dist/*" \
	    ! -path "*/build/*" \
	    ! -path "*/target/*" \
	    ! -path "*/.idea/*" \
	    ! -path "*/.vscode/*" \
	    ! -path "*/coverage/*" \
		-print0 | sort -z
)

# ------------------------------------------------------------
# PROCESS FILES
# ------------------------------------------------------------

for file in "${files[@]}"; do
	relpath="${file#./}"

	ext="${file##*.}"
	ext="${ext,,}" # normalize lowercase

	lang="${lang_map[$ext]:-text}"

	{
		printf '# %s\n\n' "$relpath"

		if [[ "$ext" == "pt" ]]; then
			echo "*Binary PyTorch artifact. Content omitted.*"
			echo ""
		else
			printf '```%s\n' "$lang"
			cat "$file"
			printf '\n```\n\n'
		fi
	} >>"$temp_output"
done

# ------------------------------------------------------------
# FINALIZE
# ------------------------------------------------------------

mv "$temp_output" "$output_file"
trap - EXIT

echo "Generated: $output_file"
