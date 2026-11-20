#!/bin/sh
# A stand-in for a `jpr-review serve` that dies at startup, the way it does
# without `gh auth`: one line on stderr and a non-zero exit.
echo "gh: not logged in" >&2
exit 3
