#!/bin/sh
# Ready, but never reads command input. The backend must kill it on timeout.
printf 'Maude> '
kill -STOP "$$"
