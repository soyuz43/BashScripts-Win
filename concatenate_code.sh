#!/usr/bin/env bash
set -euo pipefail

output_file="code.md"
temp_output="$(mktemp)"

# Updated language map with PowerShell entries
declare -A lang_map=(
  [js]="javascript"   [jsx]="javascript"
  [go]="go"           [cs]="csharp"
  [md]="markdown"     [py]="python"
  [ps1]="powershell"  [psd1]="powershell"  [psm1]="powershell"
)

# Modified find command with PowerShell extensions
find . \
  -type f \( -name "*.js"  -o -name "*.jsx" -o -name "*.go" \
            -o -name "*.cs" -o -name "*.md"  -o -name "*.py" \
            -o -name "*.ps1" -o -name "*.psd1" -o -name "*.psm1" \) \
  ! -name "$output_file" -print0 |
while IFS= read -r -d '' file; do
  relpath="${file#./}"
  ext="${file##*.}"
  lang="${lang_map[$ext]:-text}"

  {
    echo "# $relpath"
    printf '```%s\n' "$lang"
    cat "$file"
    printf '```\n\n'
  } >> "$temp_output"
done

mv "$temp_output" "$output_file"