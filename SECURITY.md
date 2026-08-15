# Security Policy

## Reporting a vulnerability

Please open a GitHub issue, or for something sensitive email danielh989@gmail.com.
This is a personal side project, so responses are best-effort — thanks for your patience.

## What to know before running

- It needs **administrator rights** to change icons on `root`-owned apps in
  `/Applications`. Nothing else needs elevated privileges.
- It makes **no network calls**, except `pip` fetching Pillow/pyobjc into a local
  virtualenv during setup. It never phones home.
- It **never modifies app bundles or their code signatures** — icons are applied
  as a separate custom-icon resource.
- It is **unsigned** (no paid Apple Developer ID), so please review the source
  before running. It's small and MIT-licensed.
- Everything is **reversible**: `./run.sh --revert` or `sudo ./uninstall.sh`.

## Supported versions

Only the latest commit on `main` is supported.
