# icon-normalizer

Some macOS apps (audio plugins, vendor tools, cross-platform apps) ship icons
that fill the whole canvas or use hard square corners, so they look **too big**
or **off-shape** next to Apple's icons. This resizes them to the native
proportion — and can round square ones into the native squircle — and keeps them
that way after updates.

![Before / after](docs/before-after.png)

## What it does

- Scans installed apps; **resizes** any icon that fills ≥ 92% of the canvas to ~82%.
- Optionally **rounds** flat-cornered square icons to Apple's squircle shape.
- Applies them as a **custom icon** — it never edits the app bundle or its code
  signature, and it's fully reversible.
- Only touches **user-facing, non-Apple** apps (it reads the Launchpad database;
  on Tahoe, where Launchpad is gone, it falls back to `Info.plist` heuristics).
- An **optional** background watcher re-applies automatically after app updates.

## Install

```sh
git clone https://github.com/danielh989/macos-icon-normalizer.git
cd macos-icon-normalizer
sudo ./install.sh              # normalize now (on-demand, no background service)
sudo ./install.sh --watcher    # also install the auto-re-apply watcher
```

Needs macOS + Xcode Command Line Tools (`xcode-select --install`). Admin is
required because most apps in `/Applications` are owned by `root`.

## GUI (optional)

```sh
cd app && ./build.sh && open "Icon Normalizer.app"
```

A small panel: live log, **Threshold** slider, **Off/Auto/On** squircle,
**Dry run**, and buttons for **Apply**, **Reset**, **Install/Start/Stop watcher**,
and **Clear log**. Actions that touch root-owned apps prompt for your password.

## Usage (CLI)

```sh
P=/usr/local/icon-normalizer/venv/bin/python N=/usr/local/icon-normalizer/normalizer.py
sudo $P $N --dry-run     # preview, change nothing
sudo $P $N --force       # (re)apply to all oversized apps
sudo $P $N --revert      # restore originals (also stops the watcher)
sudo $P $N --stop-watcher / --start-watcher / --clear-log
```

## Configuration

Set as env vars (bake in at install, or edit the daemon plist), or use `--squircle` / `--no-squircle`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `ICON_NORMALIZER_THRESHOLD` | `0.92` | Min canvas fill to count as oversized (lower = more apps). |
| `ICON_NORMALIZER_CONTENT` | `0.82` | Target fill after normalization. |
| `ICON_NORMALIZER_SQUIRCLE` | `auto` | `auto` rounds only flat, uniform, opaque-cornered squares; `on` always; `off` never. |
| `ICON_NORMALIZER_SCAN_DIRS` | `/Applications` | Colon-separated roots to scan. |

> Squircle rounding clips the corners, so icons with a **border/frame** are left
> as plain resizing (rounding them would look broken). Force with `on` if you want.

## Security & trust

This is an unsigned personal tool that needs admin rights — so it's built to be
easy to audit, and does the least it can:

- **Admin/root** is only to write icons on `root`-owned apps and (optionally) to
  install the watcher. Nothing else needs it.
- **No network**, ever, except `pip` fetching Pillow/pyobjc into a local venv
  during install. It never phones home.
- **Never edits app bundles or code signatures** — icons are applied as a
  separate custom-icon resource, and `--revert` removes them.
- **Not notarized** → it appears as "unidentified developer" (removing that needs
  a paid Apple Developer ID). Read the source before running; it's small.
- Provided **as-is, no warranty** ([MIT](LICENSE)).

## Compatibility

- **macOS 15 Sequoia** — primary target (also expected on earlier releases).
- **macOS 26 Tahoe** — works; Launchpad's DB is gone so it uses `Info.plist`
  heuristics, and it renders third-party icons as provided (so both resizing and
  squircle rounding help, same as Sequoia).
- **macOS 27 Golden Gate** — inherits Tahoe's icon system; not directly tested.

## Uninstall

```sh
sudo ./uninstall.sh              # remove everything, restore original icons
sudo ./uninstall.sh --keep-icons # remove the watcher but keep normalized icons
```

## License

[MIT](LICENSE).
