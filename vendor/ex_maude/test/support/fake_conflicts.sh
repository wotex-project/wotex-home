#!/bin/sh
# Deterministic protocol fixture for API result and option handling.
printf 'Maude> '
while IFS= read -r line; do
  case "$line" in
    quit*) exit 0 ;;
    'reduce in CONFLICT-DETECTOR :'*) printf 'result ConflictSet: noConflict\nMaude> ' ;;
    search*) printf 'No solution.\nMaude> ' ;;
    *) printf 'Maude> ' ;;
  esac
done
