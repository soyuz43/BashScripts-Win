#!/bin/bash

# Create a temp file
temp_output="$(mktemp)"
output_file="code.md"

# Declare an associative array mapping extensions to languages
declare -A lang_map=(
  ["js"]="javascript"
  ["jsx"]="javascript"
  ["go"]="go"
  ["cs"]="csharp"
  ["md"]="markdown"
  ["py"]="python"
)

# Find and process files
find . -type f \( -name "*.js" -o -name "*.jsx" -o -name "*.go" -o -name "*.cs" -o -name "*.md" -o -name "*.py" \) | while read -r file; do
  filename=$(basename "$file")
  ext="${filename##*.}"
  lang="${lang_map[$ext]:-text}"

  echo "# $filename" >> "$temp_output"
  echo "+++$lang" >> "$temp_output"
  cat "$file" >> "$temp_output"
  echo -e "+++\n" >> "$temp_output"
done

# Move temp to final output (overwrite safely)
mv "$temp_output" "$output_file"
