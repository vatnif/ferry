#!/bin/sh
# Start Ferry's local test servers and wait until both answer.
set -eu
cd "$(dirname "$0")"

# Larger fixture for future transfer/resume tests; generated, not committed.
if [ ! -f fixtures/seed/medium-1mb.bin ]; then
  dd if=/dev/urandom of=fixtures/seed/medium-1mb.bin bs=1024 count=1024 2>/dev/null
  echo "generated fixtures/seed/medium-1mb.bin"
fi

# Client keypair for the SSH public-key-auth integration tests (M11). The
# public key is mounted into the SFTP container's .ssh/keys (atmoz appends it
# to authorized_keys); the private key is read by the tests. Generated, never
# committed (see .gitignore).
if [ ! -f fixtures/keys/id_ed25519 ]; then
  mkdir -p fixtures/keys
  ssh-keygen -t ed25519 -N "" -C "ferry-test-client" -f fixtures/keys/id_ed25519 -q
  echo "generated fixtures/keys/id_ed25519 (test client key)"
fi

# Self-signed certificate for the explicit-FTPS test server (M12). Generated,
# never committed (see .gitignore). Tests connect with cert verification off.
if [ ! -f fixtures/certs/ftps.key ]; then
  mkdir -p fixtures/certs
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout fixtures/certs/ftps.key -out fixtures/certs/ftps.crt \
    -days 3650 -subj "/CN=127.0.0.1" >/dev/null 2>&1
  echo "generated fixtures/certs/ftps.{crt,key} (self-signed test cert)"
fi

# --build so the SCP/exec server (ssh-exec/) reflects any Dockerfile changes;
# the build is cached, so this is fast when nothing changed.
docker compose up -d --build

echo "waiting for servers..."
for port in 2222 2121 2990 2223; do
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
echo "test servers ready: SFTP on 2222, SSH/SCP on 2223, FTP on 2121, FTPS on 2990 (user: ferry / ferrypass)"
