#!/usr/bin/env python3
"""Drive minisign through a pseudo-tty so its password prompt can be answered
non-interactively (release-upload.sh runs unattended). minisign reads the
password from /dev/tty exclusively; this provides that tty and feeds the
passphrase whenever a password prompt appears (handles keygen's two prompts and
sign's one uniformly).

Passphrase source, in order: $MINISIGN_PASSPHRASE_FILE (first line), else
$MINISIGN_PASSPHRASE, else empty.

Usage: abi-minisign-sign.py <minisign and its args...>
"""
import os
import pty
import select
import sys

pw_file = os.environ.get("MINISIGN_PASSPHRASE_FILE")
pw = os.environ.get("MINISIGN_PASSPHRASE", "")
if pw_file and os.path.exists(pw_file):
    with open(pw_file) as f:
        pw = f.readline().rstrip("\n")

argv = sys.argv[1:]
if not argv:
    sys.stderr.write("usage: abi-minisign-sign.py <minisign args...>\n")
    sys.exit(2)

pid, fd = pty.fork()
if pid == 0:  # child
    try:
        os.execvp(argv[0], argv)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"exec failed: {e}\n")
        os._exit(127)

sent = 0
while True:
    try:
        r, _, _ = select.select([fd], [], [], 60)
    except (OSError, ValueError):
        break
    if not r:
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    low = data.lower()
    if (b"password" in low or b"passphrase" in low) and sent < 6:
        os.write(fd, (pw + "\n").encode())
        sent += 1

_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
sys.exit(code)
