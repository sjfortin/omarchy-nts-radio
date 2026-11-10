#!/usr/bin/env python3
"""Read a user-selected JSON backup with a strict size bound; no shell involved."""
import os
import stat
import pathlib
import sys


def read_backup(path):
    target = pathlib.Path(path)
    if not target.is_absolute() or target.suffix.lower() != ".json":
        raise ValueError("Select an absolute JSON file")
    # Nonblocking open avoids waiting for a FIFO writer. Validate the opened
    # descriptor, not a racy path stat, before performing a file read.
    fd = os.open(target, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("Select a regular JSON file")
        raw = source.read(4_000_001)
    if len(raw) > 4_000_000:
        raise ValueError("Backup exceeds 4 MB")
    return raw.decode("utf-8")


def main():
    try:
        if len(sys.argv) != 2:
            raise ValueError("Select a JSON backup")
        sys.stdout.write(read_backup(sys.argv[1]))
    except (OSError, ValueError, UnicodeError) as exc:
        sys.stderr.write(str(exc)[:200] + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
