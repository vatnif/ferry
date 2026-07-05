#!/bin/sh
# Start Ferry's local test servers and wait until both answer.
set -eu
cd "$(dirname "$0")"

# Larger fixture for future transfer/resume tests; generated, not committed.
if [ ! -f fixtures/seed/medium-1mb.bin ]; then
  dd if=/dev/urandom of=fixtures/seed/medium-1mb.bin bs=1024 count=1024 2>/dev/null
  echo "generated fixtures/seed/medium-1mb.bin"
fi

docker compose up -d

echo "waiting for servers..."
for port in 2222 2121; do
  tries=0
  until nc -z 127.0.0.1 "$port" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -gt 30 ]; then
      echo "ERROR: port $port did not come up after 30s" >&2
      docker compose ps
      exit 1
    fi
    sleep 1
  done
  echo "  port $port up"
done
echo "test servers ready: SFTP on 2222, FTP on 2121 (user: ferry / ferrypass)"
