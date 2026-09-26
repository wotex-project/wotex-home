#!/bin/sh
# Exact arithmetic results for the benchmark harness; no Maude installation needed.
printf 'Maude> '
while IFS= read -r line; do
  case "$line" in
    quit*) exit 0 ;;
    'reduce in BOOL : true and false .') printf 'result Bool: false\nMaude> ' ;;
    'reduce in NAT : 1 + 1 .') printf 'result Nat: 2\nMaude> ' ;;
    'reduce in NAT : 10 * 9 * 8 * 7 * 6 .') printf 'result Nat: 30240\nMaude> ' ;;
    *) printf 'Maude> ' ;;
  esac
done
