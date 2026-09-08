#!/usr/bin/env bash
# Replace duplicated library files with hardlinks to their seeding source.
# Dry-run by default; pass --apply to make changes.
set -uo pipefail

SRC_DIR=/data/downloads/complete
MEDIA_DIRS=(/data/movies /data/tv_shows)
MIN_SIZE=+100M
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

freed=0; linked=0; skipped=0

while IFS=$'\t' read -r size ino path; do
    if [ "$(stat -c %h "$path")" -gt 1 ]; then
        echo "already linked : $path"
        continue
    fi

    match=""
    while IFS=$'\t' read -r cino cpath; do
        [ "$cino" = "$ino" ] && continue
        # full byte comparison before we touch anything
        if cmp -s "$path" "$cpath"; then match="$cpath"; break; fi
    done < <(find "$SRC_DIR" -type f -size "${size}c" -printf '%i\t%p\n' 2>/dev/null)

    if [ -z "$match" ]; then
        echo "no source     : $path"
        skipped=$((skipped+1))
        continue
    fi

    echo "MATCH         : $path"
    echo "         <-    : $match"

    if [ "$APPLY" -eq 1 ]; then
        # link to a temp name first, then atomically rename over the original,
        # so a failure can never leave the library file missing
        tmp="${path}.relink.$$"
        if ln "$match" "$tmp" && mv -f "$tmp" "$path"; then
            echo "         ok    : relinked"
            linked=$((linked+1))
            freed=$((freed+size))
        else
            rm -f "$tmp"
            echo "         FAIL  : left untouched"
        fi
    else
        linked=$((linked+1))
        freed=$((freed+size))
    fi
done < <(find "${MEDIA_DIRS[@]}" -type f -size "$MIN_SIZE" -printf '%s\t%i\t%p\n' 2>/dev/null)

echo
if [ "$APPLY" -eq 1 ]; then
    echo "relinked $linked file(s), freed ~$((freed/1024/1024/1024)) GiB, skipped $skipped"
else
    echo "DRY RUN: would relink $linked file(s), freeing ~$((freed/1024/1024/1024)) GiB, skipped $skipped"
    echo "re-run with --apply to make changes"
fi
