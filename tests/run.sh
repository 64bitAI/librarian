#!/usr/bin/env bash
# Every suite, with no API key in the environment. Exit 1 when any fails.
set -u
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
here="$(cd "$(dirname "$0")" && pwd)"; rc=0
for t in "$here"/brain.sh "$here"/collect.sh; do
  out="$(bash "$t" 2>&1)" || rc=1
  printf '%s: %s ok, %s FAIL; %s\n' "$(basename "$t")" "$(printf '%s\n' "$out" | grep -c '^ok ')" \
    "$(printf '%s\n' "$out" | grep -c '^FAIL')" "$(printf '%s\n' "$out" | tail -1)"
  printf '%s\n' "$out" | grep '^FAIL' || true
done
exit "$rc"
