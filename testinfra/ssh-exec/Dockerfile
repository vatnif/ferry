# Exec-capable SSH server for Ferry's SCP integration tests (M13).
#
# The :2222 SFTP server (atmoz/sftp) forces `internal-sftp` and ships no `scp`
# binary, so it CANNOT serve SCP — SCP runs the remote `scp -t`/`scp -f` over an
# SSH exec channel, which atmoz deliberately blocks. This image is a full
# OpenSSH server WITH the scp binary and exec enabled. It uses the same
# ferry/ferrypass credentials and the same client key as the SFTP server, so the
# app's auth paths (password + public key, host-key TOFU) are identical. See
# docs/TESTING.md and docs/DECISIONS.md ADR-020.
FROM alpine:3.20

RUN apk add --no-cache openssh openssh-client openssh-sftp-server \
 && adduser -D -u 1001 -h /home/ferry -s /bin/ash ferry \
 && echo "ferry:ferrypass" | chpasswd \
 && ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
