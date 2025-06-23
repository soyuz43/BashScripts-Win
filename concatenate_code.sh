#!/usr/bin/env bash
set -euo pipefail

output_file="code.md"
temp_output="$(mktemp)"          # work in a scratch file first

# Map extensions → language identifiers
declare -A lang_map=(
  [js]="javascript"  [jsx]="javascript"
  [go]="go"          [cs]="csharp"
  [md]="markdown"    [py]="python"
)

# Walk the tree, skipping the output file, and handle spaces safely (-print0 / read -d '')
find . \
  -type f \( -name "*.js"  -o -name "*.jsx" -o -name "*.go" \
            -o -name "*.cs" -o -name "*.md"  -o -name "*.py" \) \
  ! -name "$output_file" -print0 |
while IFS= read -r -d '' file; do
  relpath="${file#./}"                     # strip leading "./"
  ext="${file##*.}"
  lang="${lang_map[$ext]:-text}"

  {
    echo "# $relpath"
    echo "+++$lang"
    cat "$file"
    echo -e "+++\n"
  } >> "$temp_output"
done

mv "$temp_output" "$output_file"          # atomically replace/overwrite
