# Quadrat

A minimal, native macOS disk-usage visualizer. Pick a disk, see a squarified treemap of what is using the space, hover for the path and size, drill in, and reveal or move items to the Trash.

Quadrat reads file sizes only. Nothing is uploaded, and nothing is deleted except through Finder’s Trash.

## Layout

- `App/` is the macOS app (XcodeGen, `project.yml`). Bundle id `com.kevinzheng.quadrat`, macOS 15, hardened runtime, not sandboxed.
- `Packages/QuadratCore/` is the Swift package: the node arena, folding rule, scanner, squarified layout, and hit testing. It builds and tests on Linux.
- `scripts/make_app_icon.py` draws the app icon. Concept C (cyan lens on a treemap) is the one in `App/Assets.xcassets`.
- `scripts/install.sh` builds into `/tmp` and installs `~/Applications/Quadrat.app`.

## Build

```bash
brew install xcodegen
scripts/install.sh
```

The script signs with an Apple Development identity when one is on the machine, and ad hoc otherwise.

Regenerate the icon with:

```bash
python3 scripts/make_app_icon.py --concept C --iconset App/Assets.xcassets/AppIcon.appiconset
```

That needs Pillow and numpy.

## Checks

```bash
swift test --package-path Packages/QuadratCore
```

The app also has two headless modes used by CI:

```bash
Quadrat.app/Contents/MacOS/Quadrat --snapshot /tmp/screens
Quadrat.app/Contents/MacOS/Quadrat --perf /some/dir --out perf.json --idle-seconds 30
```

`--snapshot` writes the six screens in light and dark. `--perf` scans an in-memory tree of 1.5 million files, scans the given directory, scans `/`, then records idle CPU and frame times.
