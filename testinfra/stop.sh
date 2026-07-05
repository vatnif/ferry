#!/bin/sh
# Stop and remove Ferry's local test servers.
set -eu
cd "$(dirname "$0")"
docker compose down
