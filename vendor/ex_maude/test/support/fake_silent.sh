#!/bin/sh
# Fake Maude that never prints a prompt: accepts any arguments, swallows
# stdin, and stays alive. Used to test that Backend.Port's init fails fast
# instead of handing a never-ready worker to the pool.

while IFS= read -r _line; do
  :
done

# If stdin closes before timeout cleanup reaches us, stop this process itself
# rather than spawning a grandchild that can outlive the test runner.
kill -STOP "$$"
