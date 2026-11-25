#!/bin/sh
# A stand-in for a `jpr-review serve` / `checkout` that dies at startup with a
# non-auth failure (exit code 1; exit code 3 is reserved for AUTH_EXIT_CODE).
echo "gh: not logged in" >&2
exit 1
