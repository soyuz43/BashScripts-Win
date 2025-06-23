#!/usr/bin/env bash
set -euo pipefail

output_file="code.md"
temp_output="$(mktemp)"          # build output here first

# Map extensions → language identifiers
declare -A lang_map=(
  [js]="javascript"  [jsx]="javascript"
  [go]="go"          [cs]="csharp"
  [md]="markdown"    [py]="python"
)

# Walk the tree, skipping the output file; handle spaces safely
find . \
  -type f \( -name "*.js"  -o -name "*.jsx" -o -name "*.go" \
            -o -name "*.cs" -o -name "*.md"  -o -name "*.py" \) \
  ! -name "$output_file" -print0 |
while IFS= read -r -d '' file; do
  relpath="${file#./}"               # remove leading "./"
  ext="${file##*.}"
  lang="${lang_map[$ext]:-text}"

  {
    echo "# $relpath"
    printf '```%s\n' "$lang"         # opening fence with language tag
    cat "$file"
    printf '```\n\n'                 # closing fence + blank line
  } >> "$temp_output"
done

mv "$temp_output" "$output_file"     # atomic replace
