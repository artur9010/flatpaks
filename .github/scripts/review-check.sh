#!/usr/bin/env bash
# Check an opencode session against the manifest from upstream-source.sh, and write the
# "Sources checked" section of the PR comment from the session's actual tool calls, so
# it can't list anything the model didn't do.
#
# The session passes only when:
# - every part was read: a single, non-truncated tool output holds both its start and
#   end tokens;
# - every bumped version was searched for: a websearch query contains it (CVEs and
#   regressions reported against the new version).
# What's missing is printed to stdout, one item per line, and the exit code is 1.
#
# The session is opencode 2.x `session export` JSON: messages[] with .type, and
# assistant .content[] holding the tool calls ({type: "tool", name, state}).
#
# Usage: review-check.sh <session.json> <manifest> <sources.md>
set -euo pipefail

session=$1
manifest=$2
sources=$3

tools='.messages[] | select(.type == "assistant") | .content[] | select(.type == "tool" and .state.status == "completed")'

missing=0
while IFS=$'\t' read -r part start end; do
  if ! jq -e --arg start "$start" --arg end "$end" "
    any($tools; .state.metadata.truncated != true
      and (.state.content | tostring | contains(\$start) and contains(\$end)))" "$session" >/dev/null; then
    echo "$part (read it with its own cat)"
    missing=1
  fi
done <"$manifest.parts"

while IFS=$'\t' read -r _ label _ _ _ _ _ _ _ version; do
  [ -n "$version" ] || continue
  if ! jq -e --arg v "$version" "any($tools; .name == \"websearch\" and (.state.input.query | contains(\$v)))" "$session" >/dev/null; then
    echo "a websearch query containing \"$version\", for $label (CVEs, regressions and issues reported against it)"
    missing=1
  fi
done <"$manifest"

{
  echo "### Sources checked"
  while IFS=$'\t' read -r app label old new commits files kept total link _; do
    if [ "$commits" = - ]; then
      line="- github: [$label, release archives $old and $new]($link) ($app: archive diff, $files files)"
    else
      line="- github: [$label, between $old and $new]($link) ($app: $commits commits, $files files)"
    fi
    if [ "$kept" -lt "$total" ]; then
      line="$line, ⚠️ only the first $((kept / 1000)) KB of $((total / 1000)) KB were reviewed"
    fi
    echo "$line"
  done <"$manifest"
  while IFS=$'\t' read -r app old new reason; do
    echo "- ⚠️ source not available: $old -> $new ($app): $reason"
  done <"$manifest.missing"
  # Repos the model cloned on its own
  jq -r "$tools | select(.name == \"shell\") | .state.input.command // \"\"
    | capture(\"git clone .*https://github\\\\.com/(?<repo>[^ ]+)\").repo? // empty
    | sub(\"\\\\.git$\"; \"\") | \"- github: cloned \" + ." "$session" | sort -u |
    grep -vFf <(cut -f2 "$manifest" | sed 's/^/- github: cloned /') || true
  jq -r "$tools
    | if .name == \"websearch\" then \"- web search: \" + .state.input.query
      elif .name == \"webfetch\" then \"- web page: \" + .state.input.url
      else empty end" "$session"
} >"$sources"

exit "$missing"
