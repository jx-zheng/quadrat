#!/usr/bin/env python3
"""A home-folder-shaped tree of about a million items.

Deep node_modules, Messages attachment buckets, a Photos library, app
bundles, a long single-child chain, and a few large files. Tiny files are
empty so the scan has something to count. Folders that should survive
scan folding get a real 1 MiB payload.

    python3 scripts/messy_tree.py /tmp/quadrat-messy
"""
from __future__ import annotations

import os
import sys

CHUNK = bytes((7,)) * (1 << 20)
TARGET = 1_000_000


def main() -> None:
    root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/quadrat-messy"
    os.makedirs(root, exist_ok=True)
    items = 0

    def directory(path: str) -> str:
        nonlocal items
        os.makedirs(path, exist_ok=True)
        items += 1
        return path

    def file(path: str, chunks: int = 0) -> None:
        nonlocal items
        fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
        try:
            remaining = chunks
            while remaining > 0:
                os.write(fd, CHUNK)
                remaining -= 1
        finally:
            os.close(fd)
        items += 1

    users = directory(os.path.join(root, "Users"))
    person = directory(os.path.join(users, "person"))
    library = directory(os.path.join(person, "Library"))

    messages = directory(os.path.join(library, "Messages"))
    attachments = directory(os.path.join(messages, "Attachments"))
    for index in range(256):
        bucket = directory(os.path.join(attachments, f"{index:02x}"))
        # A real payload keeps the folder after scan folding. Four tiny names sit beside it.
        file(os.path.join(bucket, "attachment.jpg"), chunks=1 if index < 48 else 0)
        for extra in range(4):
            file(os.path.join(bucket, f"{extra:02d}.plist"))

    photos = directory(os.path.join(library, "Photos Library.photoslibrary"))
    originals = directory(os.path.join(photos, "originals"))
    derivatives = directory(os.path.join(photos, "resources", "derivatives"))
    for index in range(80):
        file(os.path.join(originals, f"IMG_{index:04d}.heic"), chunks=1 if index < 24 else 0)
    for index in range(40):
        file(os.path.join(derivatives, f"thumb_{index:04d}.jpg"), chunks=1 if index < 12 else 0)

    support = directory(os.path.join(library, "Application Support"))
    cursor = support
    for name in (
        "com.example.chain",
        "Data",
        "Cache",
        "v3",
        "store",
        "objects",
        "aa",
        "bb",
        "cc",
        "dd",
        "ee",
        "ff",
    ):
        cursor = directory(os.path.join(cursor, name))
    file(os.path.join(cursor, "blob.bin"), chunks=8)
    file(os.path.join(cursor, "notes.txt"))

    developer = directory(os.path.join(library, "Developer"))
    repo = directory(os.path.join(developer, "repo"))
    cursor = repo
    for level in range(12):
        name = "node_modules" if level % 2 == 0 else f"pkg{level}"
        cursor = directory(os.path.join(cursor, name))
        for index in range(24):
            file(os.path.join(cursor, f"file{index}.js"))
    modules = directory(os.path.join(cursor, "node_modules"))
    for index in range(300):
        package = directory(os.path.join(modules, f"package-{index:04d}"))
        for child in range(6):
            file(os.path.join(package, f"index{child}.js"))

    applications = directory(os.path.join(root, "Applications"))
    xcode = directory(os.path.join(applications, "Xcode.app"))
    contents = directory(os.path.join(xcode, "Contents"))
    frameworks = directory(os.path.join(contents, "Frameworks"))
    resources = directory(os.path.join(contents, "Resources"))
    for index in range(48):
        framework = directory(os.path.join(frameworks, f"Framework{index}.framework"))
        versions = directory(os.path.join(framework, "Versions"))
        current = directory(os.path.join(versions, "A"))
        file(os.path.join(current, "Framework"), chunks=1 if index < 12 else 0)
        bundled = directory(os.path.join(current, "Resources"))
        for child in range(3):
            file(os.path.join(bundled, f"asset{child}.car"))
    for index in range(40):
        file(os.path.join(resources, f"icon{index}.icns"))

    other = directory(os.path.join(applications, "Utilities"))
    utility = directory(os.path.join(other, "Console.app", "Contents", "Resources"))
    for index in range(12):
        file(os.path.join(utility, f"view{index}.nib"))

    file(os.path.join(root, "Archive.dmg"), chunks=4)
    file(os.path.join(root, "Machine.sparseimage"), chunks=2)

    # The million count uses the same flat shape as the fast scan fixture.
    # The home-folder tree above is what makes the picture messy.
    bulk_root = directory(os.path.join(root, "bulk"))
    per_dir = 300
    folder_index = 0
    while items < TARGET:
        folder = os.path.join(bulk_root, f"d{folder_index}")
        os.makedirs(folder, exist_ok=True)
        items += 1
        batch = min(per_dir, TARGET - items)
        for index in range(batch):
            fd = os.open(os.path.join(folder, f"f{index}"), os.O_CREAT | os.O_WRONLY, 0o644)
            os.close(fd)
            items += 1
        folder_index += 1

    print(f"items {items}")


if __name__ == "__main__":
    main()
