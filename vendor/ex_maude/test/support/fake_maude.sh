#!/bin/sh
# Fake Maude for backend lifecycle tests: speaks just enough of the prompt
# protocol to drive ExMaude.Backend.Port without a real interpreter.
#
#   * prints the `Maude> ` prompt immediately and after every command
#   * `hang ...` lines produce no response (simulates a wedged interpreter
#     stuck in an unbounded rewrite)
#   * `die ...` lines exit without a response (simulates a crashed
#     interpreter: readers observe EOF)
#   * `quit` exits cleanly
#   * anything else is echoed back as a String result so tests can correlate
#     each response with the exact command that produced it

printf 'Maude> '

while IFS= read -r line; do
  case "$line" in
    quit*)
      exit 0
      ;;
    hang*)
      # Stop this process itself instead of spawning `sleep`: backend timeout
      # cleanup can then kill the complete fake without leaving a grandchild
      # holding the test runner's output descriptors open.
      kill -STOP "$$"
      ;;
    die*)
      exit 1
      ;;
    Warning:*)
      printf '%s\nMaude> ' "$line"
      ;;
    invalid_utf8*)
      printf 'result String: "\377"\nMaude> '
      ;;
    oversized*)
      printf 'result String: "'
      count=0
      while [ "$count" -lt 256 ]; do
        printf 'x'
        count=$((count + 1))
      done
      printf '"\nMaude> '
      ;;
    *)
      printf 'result String: "echo:%s"\nMaude> ' "$line"
      ;;
  esac
done
