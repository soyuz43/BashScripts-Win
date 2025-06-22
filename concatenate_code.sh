#!/bin/bash

# Output file
output_file="code.md"
> "$output_file"  # Clear or create the file

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

  echo "# $filename" >> "$output_file"
  echo "+++$lang" >> "$output_file"
  cat "$file" >> "$output_file"
  echo -e "+++\n" >> "$output_file"
done
