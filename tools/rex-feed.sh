#!/bin/sh
# Stopgap bridge: streams `rex events` and writes the pet's state/context files.
# Durable integration is the rex-beacon watcher (Go) writing the same files.
set -eu
STATE="$HOME/.cache/rex-pet/state"
CONTEXT="$HOME/.cache/rex-pet/context.json"
mkdir -p "$(dirname "$STATE")"

rex events --all --json | jq -r --unbuffered '
  .payload.event.payload // empty
  | select(.name == "progress_report")
  | [ (.block_id // ""), (.payload.state // ""), (.payload.title // .payload.message // "") ]
  | @tsv
' | while IFS="$(printf '\t')" read -r block raw title; do
  [ -n "$raw" ] || continue
  case "$raw" in
    *needed*|*blocked*|*permission*|*waiting*|*prompt*) state=blocked ;;
    *error*|*failed*) state=error ;;
    *done*|*complete*|*success*|*succeed*) state=done ;;
    *) state=working ;;
  esac

  printf '%s\n' "$state" > "$STATE"
  # context.json carries the pane to reply into; written atomically so the pet never reads a half file.
  jq -n --arg s "$state" --arg b "$block" --arg t "$title" \
    '{state: $s, block: $b, title: $t}' > "$CONTEXT.tmp"
  mv "$CONTEXT.tmp" "$CONTEXT"
done
