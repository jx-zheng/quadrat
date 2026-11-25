#!/usr/bin/env python3
"""Create an on-disk tree of empty files for the macOS perf scan.

    python3 scripts/synthesize_tree.py /tmp/quadrat-synth 1500000
"""
from __future__ import annotations

import os
import sys


def main() -> None:
    root = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1_500_000
    per_dir = 300
    os.makedirs(root, exist_ok=True)
    made = 0
    directories = (count + per_dir - 1) // per_dir
    for index in range(directories):
        folder = os.path.join(root, f"d{index}")
        os.makedirs(folder, exist_ok=True)
        batch = min(per_dir, count - made)
        for file_index in range(batch):
            path = os.path.join(folder, f"f{file_index}")
            fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o644)
            os.close(fd)
            made += 1
        if made >= count:
            break
    print(made)


if __name__ == "__main__":
    main()
