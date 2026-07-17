#!/bin/sh
# Runs (as root) before sshd starts — atmoz/sftp executes /etc/sftp.d/* at boot.
# Relax OpenSSH 9.8+ PerSourcePenalties for the test harness: Ferry's TOFU flow
# deliberately disconnects during KEX when a host key isn't trusted, which sshd
# otherwise penalises as "connections without attempting authentication",
# wedging the source IP for ~15s under the full suite's connection volume.
# This only affects the local test container, never a real server.
echo "PerSourcePenalties no" >> /etc/ssh/sshd_config
