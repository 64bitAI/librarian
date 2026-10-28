#!/usr/bin/env bash
# Scan the working tree, and with --history every patch and commit message, for personal data.
# Patterns: scripts/personal-data.patterns, one ERE per line (not committed; see the .example file).
# Matching is grep -iwE, so a short word does not match inside a longer one.
# A hit prints the commit (or "worktree"), the path and the pattern number, never the match.
# Author and committer metadata are not scanned.
# Accepted hits are listed in scripts/personal-data.allow, one commit:path pair per line. The commit
# is a full or abbreviated hash or "worktree"; a commit message has the path "(message)".
# Exit: 0 clean, 1 hits, 2 patterns file missing or bad usage.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
patterns="$here/personal-data.patterns"
allow="$here/personal-data.allow"
history=0
case "${1:-}" in
  "") ;;
  --history) history=1 ;;
  *) echo "usage: personal-data-scan.sh [--history]" >&2; exit 2 ;;
esac
if [ ! -f "$patterns" ]; then
  echo "personal-data-scan: $patterns is missing; copy personal-data.patterns.example and fill it in" >&2
  exit 2
fi
cd "$root" || exit 2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pdscan.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
lines="$tmp/lines" # commit TAB path TAB content
: > "$lines"

# Working tree: tracked and untracked files that are not ignored, except the pattern files.
git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
  case "$f" in
    scripts/personal-data.patterns.example | scripts/personal-data.allow) continue ;;
  esac
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  awk -v p="$f" '{printf "worktree\t%s\t%s\n", p, $0}' "$f"
done >> "$lines"

if [ "$history" = 1 ]; then
  git log -p --all --no-color --no-ext-diff --no-textconv --format='@@COMMIT %H' |
    awk '
      /^@@COMMIT / { c=$2; path="(none)"; next }
      /^diff --git / { n=split($0, a, " b/"); path=a[n]; next }
      /^(index |--- |\+\+\+ |new file mode|deleted file mode|old mode|new mode|similarity|rename |Binary files)/ { next }
      { printf "%s\t%s\t%s\n", c, path, $0 }
    ' >> "$lines"
  git log --all --no-color --format='@@COMMIT %H%n%B' |
    awk '
      /^@@COMMIT / { c=$2; next }
      { printf "%s\t(message)\t%s\n", c, $0 }
    ' >> "$lines"
fi

hits="$tmp/hits"
: > "$hits"
n=0
while IFS= read -r pat || [ -n "$pat" ]; do
  case "$pat" in "" | "#"*) continue ;; esac
  n=$((n + 1))
  # Only the content field is matched, so paths and hashes never produce a hit.
  cut -f3- "$lines" > "$tmp/content"
  grep -iwEn -e "$pat" "$tmp/content" > "$tmp/grepout" 2>/dev/null
  rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "personal-data-scan: bad pattern $n" >&2
    exit 2
  fi
  cut -d: -f1 "$tmp/grepout" > "$tmp/ln"
  if [ -s "$tmp/ln" ]; then
    awk -v n="$n" 'NR==FNR { want[$1]=1; next } (FNR in want) { print $1 "\t" $2 "\t" n }' \
      "$tmp/ln" "$lines" | sort -u >> "$hits"
  fi
done < "$patterns"

status=0
: > "$tmp/report"
if [ -s "$hits" ]; then
  sort -u "$hits" | while IFS=$'\t' read -r c p k; do
    ok=0
    if [ -f "$allow" ]; then
      while IFS= read -r a || [ -n "$a" ]; do
        case "$a" in "" | "#"*) continue ;; esac
        ac=${a%%:*}
        ap=${a#*:}
        [ "$ap" = "$p" ] || continue
        case "$c" in "$ac"*) ok=1; break ;; esac
      done < "$allow"
    fi
    [ "$ok" = 1 ] || printf 'hit: commit %s path %s pattern %s\n' "$c" "$p" "$k"
  done > "$tmp/report"
fi
if [ -s "$tmp/report" ]; then
  cat "$tmp/report"
  status=1
fi
exit "$status"
