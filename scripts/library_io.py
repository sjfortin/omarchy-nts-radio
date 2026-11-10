#!/usr/bin/env python3
"""Read a user-selected JSON backup with a strict size bound; no shell involved."""
import pathlib
import sys


def read_backup(path):
    target = pathlib.Path(path)
    if not target.is_absolute() or target.suffix.lower() != ".json":
        raise ValueError("Select an absolute JSON file")
    with target.open("rb") as source:
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
