#!/bin/sh
# Run a gate check without Bonjour, Python caches, or a live database fallback.
set -eu
cd "$1"
shift
export BENITO_BONJOUR=0 PYTHONDONTWRITEBYTECODE=1 BENITO_DB=/nonexistent
exec "$@"
