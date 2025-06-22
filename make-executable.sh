#!/bin/bash

# Make all .sh files in the current directory executable
for file in *.sh; do
  if [ -f "$file" ]; then
    chmod +x "$file"
    echo "Made executable: $file"
  fi
done
