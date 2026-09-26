#!/bin/sh
# Prompt-compatible fake that emits output continuously without completing
# the command. It distinguishes an absolute deadline from an idle timeout.

printf 'Maude> '

while IFS= read -r line; do
  case "$line" in
    quit*)
      exit 0
      ;;
    drip*)
      count=0
      while [ "$count" -lt 20 ]; do
        printf 'x'
        sleep 0.05
        count=$((count + 1))
      done
      printf '\nMaude> '
      ;;
    *)
      printf 'result String: "echo:%s"\nMaude> ' "$line"
      ;;
  esac
done
