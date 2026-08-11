# icon-normalizer

[![CodeQL](https://github.com/danielh989/macos-icon-normalizer/actions/workflows/codeql.yml/badge.svg)](https://github.com/danielh989/macos-icon-normalizer/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-Sequoia%20%7C%20Tahoe-black)

Some macOS apps (audio plugins, vendor tools, cross-platform apps) ship icons
that fill the whole canvas or use hard square corners, so they look **too big**
or **off-shape** next to Apple's. This resizes them to the native proportion —
and can round square ones into the native squircle.

![Before / after](docs/before-after.png)

*Resized to the native size, and (for square icons) rounded to the native
squircle — the same shape macOS uses for Tahoe's Liquid Glass icons.*

## Use it

**Fix your icons now** — nothing gets installed:

```sh
git clone https://github.com/danielh989/macos-icon-normalizer.git
cd macos-icon-normalizer
./run.sh
```

That's it. (`./run.sh --dry-run` first if you want to preview.) Run it again
whenever you install or update apps.

**Keep them fixed automatically (the watcher)** — optional. Installs a background
service that re-applies after every app update:

```sh
sudo ./install.sh      # installs & starts the watcher (launchd daemon)
```

Needs macOS + Xcode Command Line Tools (the first run offers to install them if
missing). You'll be asked for your password because most apps in `/Applications`
are owned by `root`.

## What it does

- Resizes any icon that fills ≥ 92% of the canvas down to the native ~82%.
- Rounds flat-cornered square icons to Apple's squircle shape (skips ones with a
  border — rounding would clip it).
- Applies them as a **custom icon** — never edits the app bundle or its code
  signature, and it's fully reversible (`./run.sh --revert`).
- Only touches **user-facing, non-Apple** apps.

## Options

Pass to `run.sh` (e.g. `./run.sh --squircle`) or set as env vars:

| Setting | Default | Meaning |
| --- | --- | --- |
| `ICON_NORMALIZER_THRESHOLD` | `0.92` | Min canvas fill to count as oversized (lower = more apps). |
| `ICON_NORMALIZER_SQUIRCLE` | `auto` | `auto` rounds only safe flat-cornered squares; `on` always; `off` never. |
| `--revert` | | Restore original icons (and stop the watcher). |
| `--force` | | Re-apply even to already-customized apps. |

## Security & trust

An unsigned personal tool that needs admin — so it's built to be easy to audit
and does the least it can:

- **Admin** is only to write icons on `root`-owned apps and (optionally) install
  the watcher. Nothing else needs it.
- **No network**, except `pip` fetching Pillow/pyobjc into a local venv on first
  run. It never phones home.
- **Never edits app bundles or code signatures.** Icons are a separate custom
  resource; `--revert` removes them.
- Provided **as-is, no warranty** ([MIT](LICENSE)). Read the source first — it's small.

## Compatibility

- **macOS 15 Sequoia** — primary target (likely fine on earlier releases).
- **macOS 26 Tahoe** — works. To decide which apps are real third-party apps
  (vs. Apple apps, installers, helpers, background agents) it normally reads the
  Launchpad database; Tahoe removed that, so it falls back to `Info.plist`
  heuristics for the same "is this a user-facing app?" check. Resizing and
  squircle rounding both still apply.
- **macOS 27 Golden Gate** — inherits Tahoe's icon system; not directly tested.

Tahoe's Liquid Glass drops non-conforming icons into a gray **"icon jail"**.
Giving an icon the native shape/margin lets it render as a clean squircle instead:

![Tahoe icon jail vs normalized](docs/tahoe-icon-jail.png)

## Uninstall

```sh
sudo ./uninstall.sh              # remove the watcher, restore original icons
sudo ./uninstall.sh --keep-icons # remove the watcher but keep normalized icons
```

## License

[MIT](LICENSE).
