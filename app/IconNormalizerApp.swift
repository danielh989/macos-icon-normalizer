// Icon Normalizer — optional AppKit front-end for the icon-normalizer scanner.
// On-demand (Apply/Reset/Dry-run) runs self-contained from a per-user support
// folder (no /usr/local). Installing is only for the optional background watcher.
// Build with app/build.sh.
import AppKit

// Self-contained, user-owned backend for on-demand use.
let SUPPORT = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/IconNormalizer")
let VENV = SUPPORT + "/venv"
let PYV  = VENV + "/bin/python"
let PIPV = VENV + "/bin/pip"
let NRM  = SUPPORT + "/normalizer.py"
let LOG  = SUPPORT + "/icon-normalizer.log"
// Bundled inside the .app (Contents/Resources).
let RES         = Bundle.main.resourcePath ?? ""
let BUNDLED_NRM = RES + "/normalizer.py"
let BUNDLED_REQ = RES + "/requirements.txt"
let INSTALLER   = RES + "/install.sh"

func runShell(_ cmd: String) -> String {
    let p = Process(); p.launchPath = "/bin/bash"; p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "error: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func runAdmin(_ cmd: String) -> String {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
    let p = Process(); p.launchPath = "/usr/bin/osascript"
    p.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "error: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var squircle: NSSegmentedControl!
    var dryRun: NSButton!
    var thresholdSlider: NSSlider!
    var thresholdValue: NSTextField!
    var busy = false
    var pinnedReport: String?   // when set, the log view shows this (e.g. dry-run) instead of the live log

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // Copy the bundled scanner into the user support dir and build its venv once.
    func ensureBackend() -> String {
        return "mkdir -p \(shq(SUPPORT)) && cp -f \(shq(BUNDLED_NRM)) \(shq(NRM)) && "
             + "{ [ -x \(shq(PYV)) ] || { /usr/bin/python3 -m venv \(shq(VENV)) && "
             + "\(shq(PIPV)) install -q --upgrade pip && "
             + "\(shq(PIPV)) install -q -r \(shq(BUNDLED_REQ)); }; }"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let W: CGFloat = 600, H: CGFloat = 660, M: CGFloat = 18
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Icon Normalizer"; window.center()
        let v = window.contentView!

        @discardableResult
        func lbl(_ s: String, _ f: NSRect, bold: Bool = false, size: CGFloat = 13, gray: Bool = false) -> NSTextField {
            let t = NSTextField(labelWithString: s); t.frame = f
            t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            if gray { t.textColor = .secondaryLabelColor }
            t.lineBreakMode = .byTruncatingTail
            v.addSubview(t); return t
        }
        @discardableResult
        func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ sel: Selector,
                    tip: String, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: y, width: w, height: 34); b.bezelStyle = .rounded; b.toolTip = tip
            if !key.isEmpty { b.keyEquivalent = key }
            v.addSubview(b); return b
        }

        lbl("Icon Normalizer", NSRect(x: M, y: H-42, width: W-2*M, height: 26), bold: true, size: 17)
        statusLabel = lbl("…", NSRect(x: M, y: H-66, width: W-2*M, height: 18), size: 12, gray: true)

        lbl("Log", NSRect(x: M, y: H-92, width: 200, height: 16), bold: true, size: 11)
        let bClear = NSButton(title: "Clear log", target: self, action: #selector(clearLog))
        bClear.frame = NSRect(x: W-M-104, y: H-97, width: 104, height: 22)
        bClear.bezelStyle = .rounded; bClear.controlSize = .small; bClear.font = .systemFont(ofSize: 11)
        bClear.toolTip = "Empty the on-demand log."; v.addSubview(bClear)

        let bUnlock = NSButton(title: "Unlock", target: self, action: #selector(unlock))
        bUnlock.frame = NSRect(x: W-M-104-96, y: H-97, width: 90, height: 22)
        bUnlock.bezelStyle = .rounded; bUnlock.controlSize = .small; bUnlock.font = .systemFont(ofSize: 11)
        bUnlock.toolTip = "Enter your admin password once now; actions won't re-ask for a few minutes."
        v.addSubview(bUnlock)

        let scroll = NSScrollView(frame: NSRect(x: M, y: 290, width: W-2*M, height: (H-98)-290))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]; scroll.documentView = logView; v.addSubview(scroll)

        lbl("Threshold", NSRect(x: M, y: 246, width: 80, height: 20))
        thresholdSlider = NSSlider(value: 0.92, minValue: 0.80, maxValue: 0.98,
                                   target: self, action: #selector(thresholdChanged))
        thresholdSlider.frame = NSRect(x: M+90, y: 244, width: 250, height: 22)
        thresholdSlider.toolTip = "Only icons filling at least this fraction of the canvas are treated as oversized."
        v.addSubview(thresholdSlider)
        thresholdValue = lbl("92%", NSRect(x: M+350, y: 246, width: 60, height: 20))
        lbl("Minimum fill to count an icon as oversized (lower = affects more apps).",
            NSRect(x: M, y: 226, width: W-2*M, height: 16), size: 11, gray: true)

        lbl("Squircle", NSRect(x: M, y: 196, width: 80, height: 20))
        squircle = NSSegmentedControl(labels: ["Off", "Auto", "On"], trackingMode: .selectOne, target: nil, action: nil)
        squircle.frame = NSRect(x: M+90, y: 192, width: 200, height: 26); squircle.selectedSegment = 1
        squircle.toolTip = "Round square icons to Apple's shape. Auto only when safe; On may clip bordered icons."
        v.addSubview(squircle)
        lbl("Off: keep shape · Auto: round only when safe · On: always (may clip borders).",
            NSRect(x: M, y: 174, width: W-2*M, height: 16), size: 11, gray: true)

        dryRun = NSButton(checkboxWithTitle: "Dry run — preview what would change, apply nothing", target: nil, action: nil)
        dryRun.frame = NSRect(x: M, y: 142, width: W-2*M, height: 20)
        dryRun.toolTip = "Show which apps Apply would touch, without changing anything."
        v.addSubview(dryRun)

        // on-demand actions
        button("Apply now", M, 92, 150, #selector(apply),
               tip: "Normalize oversized icons now (asks for your password for root-owned apps).", key: "\r")
        button("Reset icons", M+165, 92, 150, #selector(reset),
               tip: "Restore original icons (and stop the watcher if installed).")
        button("Refresh", M+330, 92, 130, #selector(refresh), tip: "Reload status and log.")

        // optional watcher
        button("Install watcher", M, 42, 150, #selector(installWatcher),
               tip: "Optional. Install a background service that re-normalizes automatically after app updates.")
        button("Start", M+165, 42, 95, #selector(startWatcher), tip: "Load the installed watcher.")
        button("Stop", M+270, 42, 95, #selector(stopWatcher), tip: "Unload the watcher.")
        lbl("Apply/Reset work on-demand (nothing installed). The watcher is optional (auto re-apply).",
            NSRect(x: M, y: 16, width: W-2*M, height: 16), size: 11, gray: true)

        thresholdChanged(thresholdSlider); refresh(self)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.refresh(nil) }
        // Build the venv quietly on first launch so the first action isn't slow.
        if !FileManager.default.isExecutableFile(atPath: PYV) {
            busy = true; statusLabel.stringValue = "Setting up (first launch, ~1 min)…"
            DispatchQueue.global().async {
                _ = runShell(self.ensureBackend())
                DispatchQueue.main.async { self.busy = false; self.refresh(nil) }
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func thresholdString() -> String { String(format: "%.2f", thresholdSlider.doubleValue) }
    func squircleFlag() -> String {
        switch squircle.selectedSegment { case 0: return "--no-squircle"; case 2: return "--squircle"; default: return "" }
    }
    @objc func thresholdChanged(_ s: Any?) {
        thresholdValue.stringValue = "\(Int((thresholdSlider.doubleValue*100).rounded()))%"
    }

    @objc func refresh(_ sender: Any?) {
        if sender != nil { pinnedReport = nil }   // a real Refresh returns to the live log
        let plist = runShell("ls /Library/LaunchDaemons/*icon-normalizer*.plist 2>/dev/null | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var watcher = "not installed"
        if !plist.isEmpty {
            let label = (plist as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            let running = runShell("launchctl print system/\(label) >/dev/null 2>&1 && echo yes").contains("yes")
            watcher = running ? "running ✓" : "installed (stopped)"
        }
        if pinnedReport != nil {
            statusLabel.stringValue = "Dry-run preview below — press Refresh for the live log"
            return
        }
        let last = runShell("tail -n 1 \(shq(LOG)) 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = "Watcher: \(watcher)   •   \(last.isEmpty ? "ready — press Apply" : last)"
        let tail = runShell("tail -n 200 \(shq(LOG)) 2>/dev/null")
        if logView.string != tail { logView.string = tail; logView.scrollToEndOfDocument(nil) }
    }

    // Build venv as the user, then run the privileged part with an admin prompt.
    func ensureThenAdmin(_ cmd: String, _ status: String) {
        if busy { return }
        pinnedReport = nil
        busy = true; statusLabel.stringValue = status
        DispatchQueue.global().async {
            let setup = runShell(self.ensureBackend())
            let out = setup + runAdmin(cmd)     // runAdmin escalates via the admin prompt
            DispatchQueue.main.async {
                self.busy = false
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {           // show THIS run's output (not stale log)
                    self.pinnedReport = out
                    self.logView.string = out
                    self.logView.scrollToEndOfDocument(nil)
                }
                let f = out.components(separatedBy: "FAIL setIcon").count - 1
                if out.lowercased().contains("cancel") {
                    self.statusLabel.stringValue = "Cancelled — no changes (admin password not entered)."
                } else if f > 0 {
                    self.statusLabel.stringValue = "\(f) app(s) failed — you must enter your admin password when prompted."
                } else {
                    self.statusLabel.stringValue = "Done ✓ — press Refresh for the live log."
                }
            }
        }
    }

    @objc func apply(_ sender: Any?) {
        if busy { return }
        let env = "ICON_NORMALIZER_THRESHOLD=\(thresholdString())"
        if dryRun.state == .on {
            pinnedReport = nil
            busy = true; statusLabel.stringValue = "Previewing…"
            DispatchQueue.global().async {
                let out = runShell("\(self.ensureBackend()) && \(env) \(self.shq(PYV)) \(self.shq(NRM)) --dry-run \(self.squircleFlag())")
                DispatchQueue.main.async {
                    self.busy = false
                    self.pinnedReport = out.isEmpty ? "(no changes)" : out
                    self.logView.string = self.pinnedReport!
                    self.logView.scrollToBeginningOfDocument(nil)
                    self.statusLabel.stringValue = "Dry-run preview below — press Refresh for the live log"
                }
            }
            return
        }
        ensureThenAdmin("\(env) \(shq(PYV)) \(shq(NRM)) --force \(squircleFlag())", "Applying (enter password)…")
    }

    @objc func reset(_ sender: Any?) {
        if busy { return }
        let a = NSAlert(); a.messageText = "Restore original icons?"
        a.informativeText = "Removes the custom icons applied by this tool, and stops the watcher if installed."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ensureThenAdmin("\(shq(PYV)) \(shq(NRM)) --revert", "Resetting (enter password)…")
    }

    @objc func installWatcher(_ sender: Any?) {
        if busy { return }
        busy = true; statusLabel.stringValue = "Installing watcher (enter password)…"
        DispatchQueue.global().async {
            _ = runAdmin("bash \(self.shq(INSTALLER))")
            DispatchQueue.main.async { self.busy = false; self.refresh(nil) }
        }
    }
    @objc func startWatcher(_ s: Any?) { ensureThenAdmin("\(shq(PYV)) \(shq(NRM)) --start-watcher", "Starting watcher…") }
    @objc func stopWatcher(_ s: Any?)  { ensureThenAdmin("\(shq(PYV)) \(shq(NRM)) --stop-watcher", "Stopping watcher…") }

    @objc func unlock(_ s: Any?) {
        if busy { return }
        busy = true; statusLabel.stringValue = "Unlocking (enter password once)…"
        DispatchQueue.global().async {
            _ = runAdmin("true")   // primes the ~5-min admin auth cache
            DispatchQueue.main.async {
                self.busy = false
                self.statusLabel.stringValue = "Unlocked ✓ — actions won't re-ask for a few minutes."
            }
        }
    }

    @objc func clearLog(_ s: Any?) {
        _ = runShell(": > \(shq(LOG))")   // user-owned log, no admin needed
        refresh(nil)
    }
}

let app = NSApplication.shared
let ctrl = Controller()
app.delegate = ctrl
app.setActivationPolicy(.regular)
app.run()
