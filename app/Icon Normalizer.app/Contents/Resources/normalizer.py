#!/usr/bin/env python3
"""
icon-normalizer -- shrink oversized macOS app icons to the native proportion.

Some third-party apps (audio plugins, cross-platform installers, etc.) ship an
icon whose artwork fills the whole 1024x1024 canvas, so it looks noticeably
bigger than Apple's icons in the Dock, Launchpad and Finder. This tool finds
those apps and rescales the artwork to the native macOS proportion (~82% of the
canvas, with transparent margin), then applies it as a *custom* icon -- without
touching the app bundle's own .icns or its code signature.

Design highlights
-----------------
* No hard-coded app list. It scans installed apps and decides per-icon.
* "User-facing" apps only: it gates on the Launchpad database, which is what
  cleanly separates real apps from installers / uninstallers / background
  agents (Info.plist and codesign flags are not enough on their own).
* Apple apps are skipped (com.apple.* bundle id or "Software Signing" authority).
* Idempotent: apps that already have a custom icon are left alone; icon
  measurements are cached by mtime so re-scans are cheap.
* Faithful rescale: every output size is derived from the original .icns
  representation at that same size, not from one downscaled master.
* Reversible: `--revert` removes the custom icons this tool applied.

Modes
-----
    normalizer.py            apply (needs sudo for root-owned apps)
    normalizer.py --dry-run  report what it would do, change nothing
    normalizer.py --revert   remove custom icons previously applied by this tool

Configuration (environment variables)
-------------------------------------
    ICON_NORMALIZER_THRESHOLD   fill fraction that counts as oversized (0.92)
    ICON_NORMALIZER_CONTENT     target fill after normalization        (0.82)
    ICON_NORMALIZER_SCAN_DIRS   colon-separated roots to scan   (/Applications)
"""
import os, sys, subprocess, plistlib, glob, json, hashlib, datetime, sqlite3, pwd, tempfile, shutil
from PIL import Image, ImageDraw

# ---- config -----------------------------------------------------------------
def _envf(name, default):
    try: return float(os.environ.get(name, default))
    except ValueError: return default

THRESHOLD    = _envf("ICON_NORMALIZER_THRESHOLD", 0.92)
CONTENT_FRAC = _envf("ICON_NORMALIZER_CONTENT", 0.82)
SCAN_DIRS    = os.environ.get("ICON_NORMALIZER_SCAN_DIRS", "/Applications").split(":")
# Squircle: give full-bleed, hard-cornered square icons the native rounded shape.
# off = never, on = always, auto = only when the icon is a hard-cornered square.
SQUIRCLE     = os.environ.get("ICON_NORMALIZER_SQUIRCLE", "auto").strip().lower()
CORNER_RATIO = 0.2237   # Apple app-icon corner radius as a fraction of the body

HERE        = os.path.dirname(os.path.abspath(__file__))
STATE_FILE  = os.path.join(HERE, "state.json")          # measure cache + applied set
LOG         = os.path.join(HERE, "icon-normalizer.log")
ICONSET = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),
           ("128x128",128),("128x128@2x",256),("256x256",256),
           ("256x256@2x",512),("512x512",512),("512x512@2x",1024)]

DRY    = "--dry-run" in sys.argv
REVERT = "--revert" in sys.argv
FORCE  = "--force" in sys.argv   # re-apply even if a custom icon is already set
STOP   = "--stop-watcher" in sys.argv
START  = "--start-watcher" in sys.argv
CLEARLOG = "--clear-log" in sys.argv
if "--squircle" in sys.argv:    SQUIRCLE = "on"
if "--no-squircle" in sys.argv: SQUIRCLE = "off"

def log(msg):
    line = f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] {msg}"
    print(line)
    if not DRY:
        try:
            with open(LOG, "a") as f: f.write(line + "\n")
        except Exception: pass

# ---- discovery --------------------------------------------------------------
def find_apps():
    apps = []
    for root in SCAN_DIRS:
        for dirpath, dirnames, _ in os.walk(root):
            keep = []
            for d in dirnames:
                if d.endswith(".app"):
                    apps.append(os.path.join(dirpath, d))   # don't descend into apps
                else:
                    keep.append(d)
            dirnames[:] = keep
    return sorted(set(apps))

def info_plist(app):
    p = os.path.join(app, "Contents", "Info.plist")
    if os.path.exists(p):
        try:
            with open(p, "rb") as f: return plistlib.load(f)
        except Exception: pass
    return {}

def bundle_id(app):
    return info_plist(app).get("CFBundleIdentifier")

def is_apple(app):
    if (bundle_id(app) or "").startswith("com.apple."):
        return True
    try:
        r = subprocess.run(["codesign","-dvvv",app], capture_output=True, text=True)
        for line in (r.stdout + r.stderr).splitlines():
            if line.startswith("Authority="):
                auth = line.split("=",1)[1]
                if auth in ("Software Signing","Apple Mac OS Application Signing"):
                    return True
                if auth.startswith(("Developer ID Application","Apple Development")):
                    return False
    except Exception:
        pass
    return False

def custom_icon_present(app):
    icon = os.path.join(app, "Icon\r")
    return os.path.exists(icon) and os.path.getsize(icon) > 0

def strip_custom_icon(app):
    """Fully remove a custom icon: delete the Icon resource AND clear the
    kHasCustomIcon Finder flag. NSWorkspace.setIcon(None) leaves that flag set,
    which makes Finder show a generic/folder icon -- so we clear it explicitly."""
    icon = os.path.join(app, "Icon\r")
    try:
        if os.path.lexists(icon): os.remove(icon)
    except OSError:
        pass
    subprocess.run(["xattr", "-d", "com.apple.FinderInfo", app], capture_output=True)

# ---- watcher (launchd daemon) control ---------------------------------------
def _daemon_plists():
    return glob.glob("/Library/LaunchDaemons/*icon-normalizer*.plist")

def stop_watcher():
    for p in _daemon_plists():
        label = os.path.splitext(os.path.basename(p))[0]
        subprocess.run(["launchctl", "bootout", "system", p], capture_output=True)
        subprocess.run(["launchctl", "disable", f"system/{label}"], capture_output=True)
        log(f"watcher stopped: {label}")

def start_watcher():
    for p in _daemon_plists():
        label = os.path.splitext(os.path.basename(p))[0]
        subprocess.run(["launchctl", "enable", f"system/{label}"], capture_output=True)
        subprocess.run(["launchctl", "bootstrap", "system", p], capture_output=True)
        subprocess.run(["launchctl", "kickstart", "-k", f"system/{label}"], capture_output=True)
        log(f"watcher started: {label}")

# ---- "shows in Launchpad/Dock" via the Launchpad database -------------------
def _console_user():
    try:
        u = subprocess.run(["stat","-f","%Su","/dev/console"],
                           capture_output=True, text=True).stdout.strip()
        return u or None
    except Exception:
        return None

def find_launchpad_db():
    """Locate the logged-in user's Launchpad DB, even when running as root."""
    user = _console_user()
    uid = None
    if user and user != "root":
        try: uid = pwd.getpwnam(user).pw_uid
        except KeyError: pass
    cands = glob.glob("/var/folders/*/*/0/com.apple.dock.launchpad/db/db")
    for p in cands:
        try:
            if uid is None or os.stat(p).st_uid == uid:
                return p
        except OSError:
            continue
    return cands[0] if cands else None

def launchpad_bundle_ids():
    """Bundle ids that appear in Launchpad (real, user-facing apps), or None."""
    db = find_launchpad_db()
    if not db or not os.path.exists(db):
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        ids = {r[0] for r in con.execute(
            "SELECT bundleid FROM apps WHERE bundleid IS NOT NULL")}
        con.close()
        return ids or None
    except Exception:
        return None

# ---- fallback heuristic when the Launchpad DB is unreadable ------------------
NESTED = (".app",".bundle",".framework",".plugin",".xpc",".appex")
def _truthy(v):
    return v is True or str(v).strip().lower() in ("1","true","yes")

def is_dock_app(app):
    parent = os.path.dirname(app)
    while parent and parent != "/":
        if parent.endswith(NESTED): return False
        parent = os.path.dirname(parent)
    pl = info_plist(app)
    if _truthy(pl.get("LSUIElement")) or _truthy(pl.get("LSBackgroundOnly")):
        return False
    pkg = pl.get("CFBundlePackageType")
    return not (pkg and pkg != "APPL")

# ---- icon handling ----------------------------------------------------------
def find_icns(app):
    pl = info_plist(app)
    name = pl.get("CFBundleIconFile") or pl.get("CFBundleIconName")
    res = os.path.join(app, "Contents", "Resources")
    if name:
        if not name.endswith(".icns"): name += ".icns"
        c = os.path.join(res, name)
        if os.path.exists(c): return c
    ic = glob.glob(os.path.join(res, "*.icns"))
    return max(ic, key=os.path.getsize) if ic else None

def reps_from_icns(icns, workdir):
    iconset = os.path.join(workdir, "orig.iconset")
    subprocess.run(["rm","-rf",iconset], check=False)
    subprocess.run(["iconutil","-c","iconset",icns,"-o",iconset], capture_output=True)
    reps = {}
    pngs = glob.glob(os.path.join(iconset,"*.png")) if os.path.isdir(iconset) else []
    if not pngs:
        out = os.path.join(workdir, "sips.png")
        subprocess.run(["sips","-s","format","png",icns,"--out",out], capture_output=True)
        if os.path.exists(out):
            im = Image.open(out).convert("RGBA"); reps[im.size[0]] = im
        return reps
    for p in pngs:
        im = Image.open(p).convert("RGBA"); w,h = im.size
        if w == h: reps[w] = im
    return reps

def fill_of(reps):
    if not reps: return None
    im = reps[max(reps)]
    b = im.getchannel("A").getbbox()
    if not b: return None
    w,h = im.size
    return max((b[2]-b[0])/w, (b[3]-b[1])/h)

def is_hard_square(reps):
    """True only when the art is a near-square whose four corners are both
    OPAQUE and near-UNIFORM in color -- i.e. rounding them into a squircle is
    guaranteed invisible. This deliberately rejects:
      * logos on transparency / already-rounded icons (transparent corners), and
      * icons with a border or edge detail (opaque but high colour variance),
        which the squircle mask would clip and make look broken.
    """
    import statistics
    im = reps[max(reps)]
    b = im.getchannel("A").getbbox()
    if not b: return False
    art = im.crop(b); a = art.getchannel("A"); rgb = art.convert("RGB"); w,h = art.size
    if min(w,h) < 8 or abs(w-h) > 0.10*max(w,h):
        return False
    s = max(2, int(min(w,h)*0.06))
    def corner(x0,y0):
        alphas = [a.getpixel((x,y)) for x in range(x0,x0+s) for y in range(y0,y0+s)]
        pxs = [rgb.getpixel((x,y)) for x in range(x0,x0+s) for y in range(y0,y0+s)]
        mean_a = sum(alphas)/len(alphas)
        std = sum(statistics.pstdev(c) for c in zip(*pxs))/3
        return mean_a, std
    for x0,y0 in ((0,0),(w-s,0),(0,h-s),(w-s,h-s)):
        mean_a, std = corner(x0,y0)
        # mean_a > 60 accepts solid/gradient fills that reach the edge (incl.
        # icons already given a small rounding, like a gradient tile); it still
        # rejects logos on transparency (corner alpha ~0). std <= 12 rejects a
        # border / edge detail that the mask would clip.
        if mean_a < 60 or std > 12:
            return False
    return True

_mask_cache = {}
def _squircle_mask(px, body):
    key = (px, body)
    if key not in _mask_cache:
        m = Image.new("L", (px, px), 0)
        off = (px-body)//2
        ImageDraw.Draw(m).rounded_rectangle(
            [off, off, off+body-1, off+body-1], radius=int(body*CORNER_RATIO), fill=255)
        _mask_cache[key] = m
    return _mask_cache[key]

def _level(src, px, squircle=False):
    im = src; b = im.getchannel("A").getbbox()
    if b: im = im.crop(b)
    w,h = im.size
    if squircle:
        # scale the (square) art to fill the body, then clip to the squircle
        body = int(px*CONTENT_FRAC)
        im = im.resize((body, body), Image.LANCZOS)
        c = Image.new("RGBA",(px,px),(0,0,0,0)); off = (px-body)//2
        c.paste(im, (off, off))
        mask = _squircle_mask(px, body)
        c.putalpha(Image.composite(c.getchannel("A"), Image.new("L",(px,px),0), mask))
        return c
    target = int(px*CONTENT_FRAC); s = target/max(w,h)
    nw,nh = max(1,round(w*s)), max(1,round(h*s))
    im = im.resize((nw,nh), Image.LANCZOS)
    c = Image.new("RGBA",(px,px),(0,0,0,0)); c.paste(im, ((px-nw)//2,(px-nh)//2), im)
    return c

def _pick(reps, px):
    if px in reps: return reps[px]
    bigger = sorted(s for s in reps if s > px)
    return reps[bigger[0]] if bigger else reps[max(reps)]

def build_norm_icns(reps, out_path, workdir, squircle=False):
    iconset = os.path.join(workdir, "out.iconset")
    subprocess.run(["rm","-rf",iconset], check=False); os.makedirs(iconset, exist_ok=True)
    cache = {}
    for base,px in ICONSET:
        if px not in cache: cache[px] = _level(_pick(reps,px), px, squircle)
        cache[px].save(os.path.join(iconset, f"icon_{base}.png"))
    r = subprocess.run(["iconutil","-c","icns",iconset,"-o",out_path], capture_output=True)
    return r.returncode == 0

# ---- state ------------------------------------------------------------------
def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
        s.setdefault("measure", {}); s.setdefault("applied", {})
        return s
    except Exception:
        return {"measure": {}, "applied": {}}

def save_state(s):
    if DRY: return
    try:
        with open(STATE_FILE,"w") as f: json.dump(s, f, indent=0)
    except Exception: pass

def refresh_ui():
    subprocess.run(["killall","Dock"], check=False)
    subprocess.run(["killall","Finder"], check=False)

# ---- modes ------------------------------------------------------------------
def revert():
    from AppKit import NSWorkspace
    ws = NSWorkspace.sharedWorkspace()
    state = load_state()
    n = 0
    for app in list(state["applied"].keys()):
        if os.path.isdir(app):
            ws.setIcon_forFile_options_(None, app, 0)
            strip_custom_icon(app)        # clear the flag too, or Finder shows a folder icon
            log(f"reverted: {app}"); n += 1
        state["applied"].pop(app, None)
    save_state(state)
    # Stop the watcher, otherwise it would re-normalize these apps immediately.
    stop_watcher()
    if n:
        subprocess.run(["/bin/rm","-rf","/Library/Caches/com.apple.iconservices.store"], check=False)
        refresh_ui()
    log(f"revert done: {n} app(s) restored; watcher stopped")

def run():
    from AppKit import NSWorkspace, NSImage
    ws = NSWorkspace.sharedWorkspace()
    state = load_state()
    if not DRY and os.geteuid() != 0:
        log("NOTE: not running as root — apps owned by root will be skipped. "
            "Re-run with:  sudo icon-normalizer")
    lp = launchpad_bundle_ids()
    log(f"Launchpad set: {len(lp)} apps -> gating on it" if lp
        else "Launchpad DB unavailable -> Info.plist fallback")
    # Per-run scratch dir owned by whoever runs (avoids root/user permission
    # clashes from a shared cache under the install dir).
    tmp = tempfile.mkdtemp(prefix="icon-normalizer-")
    changed = 0; would = []
    for app in find_apps():
        if lp is not None:
            if (bundle_id(app) or "") not in lp: continue
        elif not is_dock_app(app):
            continue
        if custom_icon_present(app) and not FORCE:
            continue
        icns = find_icns(app)
        if not icns: continue
        try: mtime = os.path.getmtime(icns)
        except OSError: continue
        cached = state["measure"].get(icns)
        if cached and cached.get("mtime")==mtime and cached.get("fill",1) < THRESHOLD:
            continue
        if is_apple(app):
            state["measure"][icns] = {"mtime":mtime,"fill":0.0,"apple":True}
            continue
        wd = os.path.join(tmp, hashlib.md5(app.encode()).hexdigest())
        os.makedirs(wd, exist_ok=True)
        reps = reps_from_icns(icns, wd); fill = fill_of(reps)
        if fill is None: continue
        state["measure"][icns] = {"mtime":mtime,"fill":fill}
        if fill < THRESHOLD: continue
        sq = (SQUIRCLE == "on") or (SQUIRCLE == "auto" and is_hard_square(reps))
        out = os.path.join(wd, "normalized.icns")
        if not build_norm_icns(reps, out, wd, sq):
            log(f"FAIL build icns: {app}"); continue
        if DRY:
            would.append((app, fill, sq)); continue
        img = NSImage.alloc().initWithContentsOfFile_(out)
        if img and ws.setIcon_forFile_options_(img, app, 0):
            log(f"normalized ({fill*100:.0f}%{', squircle' if sq else ''}): {app}")
            state["applied"][app] = bundle_id(app) or ""
            changed += 1
        else:
            log(f"FAIL setIcon (permissions? need sudo): {app}")
    save_state(state)
    shutil.rmtree(tmp, ignore_errors=True)
    if DRY:
        print(f"\n[DRY-RUN] would normalize {len(would)} app(s) "
              f"(threshold {THRESHOLD*100:.0f}%):")
        for app,fill,sq in sorted(would, key=lambda x:-x[1]):
            print(f"  {fill*100:5.1f}%{'  [squircle]' if sq else '           '}  {app}")
        print("Apple apps and already-customized apps are skipped.")
    elif changed:
        refresh_ui()
        log(f"done: normalized {changed}, Dock/Finder refreshed")

def clear_log():
    try:
        open(LOG, "w").close()
        print("log cleared")
    except OSError as e:
        print("could not clear log:", e)

if __name__ == "__main__":
    if CLEARLOG:  clear_log()
    elif STOP:    stop_watcher()
    elif START:   start_watcher()
    elif REVERT:  revert()
    else:         run()
