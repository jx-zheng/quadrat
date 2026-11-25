#!/usr/bin/env python3
"""Read /usr/bin/time -l output and require the whole-process footprint under 100 MB."""
from __future__ import annotations

import re
import sys


def field(text: str, label: str) -> int:
    match = re.search(rf"(\d+)\s+{re.escape(label)}", text)
    if not match:
        raise SystemExit(f"missing {label} in time output:\n{text}")
    return int(match.group(1))


def main() -> None:
    text = open(sys.argv[1]).read()
    footprint = field(text, "peak memory footprint")
    resident = field(text, "maximum resident set size")
    print(f"process footprint {footprint} resident {resident}")
    limit = 100 * 1024 * 1024
    if footprint >= limit:
        raise SystemExit(f"whole-process footprint {footprint} is over 100 MB")


if __name__ == "__main__":
    main()
