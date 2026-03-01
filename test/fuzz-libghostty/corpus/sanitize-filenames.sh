#!/bin/sh
# Rename AFL++ output files to replace colons with underscores.
# Colons are invalid on Windows (NTFS).
#
# Usage: ./sanitize-filenames.sh [directory ...]
# Defaults to vt-parser-cmin and vt-parser-min in the same directory as this script.

cd "$(dirname "$0")" || exit 1

dirs="${@:-vt-parser-cmin vt-parser-min}"

for dir in $dirs; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    newname=$(echo "$f" | tr ':' '_')
    [ "$f" != "$newname" ] && mv "$f" "$newname"
  done
done
