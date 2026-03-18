#!/usr/bin/env bash
set -euo pipefail

output_file="code.md"
temp_output="$(mktemp)"

# Updated language map with PowerShell, JSON, and YAML entries
declare -A lang_map=(
	[js]="javascript" [jsx]="javascript"
	[go]="go" [cs]="csharp"
	[md]="markdown" [py]="python"
	[ps1]="powershell" [psd1]="powershell" [psm1]="powershell"
	[json]="json" [yaml]="yaml" [yml]="yaml"
)

# Modified find command to include json, yaml, and pt files
# Note: *.docx is intentionally excluded to avoid binary corruption
find . \
	-type f \( -name "*.js" -o -name "*.jsx" -o -name "*.go" \
	-o -name "*.cs" -o -name "*.md" -o -name "*.py" \
	-o -name "*.ps1" -o -name "*.psd1" -o -name "*.psm1" \
	-o -name "*.json" -o -name "*.yaml" -o -name "*.yml" \
	-o -name "*.pt" \) \
	! -name "$output_file" -print0 |
	while IFS= read -r -d '' file; do
		relpath="${file#./}"
		ext="${file##*.}"
		lang="${lang_map[$ext]:-text}"

		{
			echo "# $relpath"

			# Handle binary PyTorch files differently (list path, skip content)
			if [[ "$ext" == "pt" ]]; then
				echo ""
				echo "*Binary PyTorch artifact. Content omitted.*"
				echo ""
			else
				# Handle text/code files normally
				printf '```%s\n' "$lang"
				cat "$file"
				printf '```\n\n'
			fi
		} >>"$temp_output"
	done

mv "$temp_output" "$output_file"
