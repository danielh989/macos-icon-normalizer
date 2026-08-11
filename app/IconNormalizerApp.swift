// Icon Normalizer — small AppKit control panel for the icon-normalizer daemon.
// Monitors the watcher log, and applies / resets icons and the watcher with the
// chosen flags. Build with app/build.sh (needs the Swift toolchain).
import AppKit

let INSTALL = "/usr/local/icon-normalizer"
let PY  = "\(INSTALL)/venv/bin/python"
let NRM = "\(INSTALL)/normalizer.py"
let LOG = "\(INSTALL)/icon-normalizer.log"
// backend installer bundled inside the .app (Contents/Resources)
let INSTALLER = "\(Bundle.main.resourcePath ?? "")/install.sh"

func runShell(_ cmd: String) -> String {
    // -c (not -lc): don't source the login profile, which can print noise.
    let p = Process(); p.launchPath = "/bin/bash"; p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "error: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// Run as root via the native admin-password prompt.
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

    // Quit when the window is closed (no menu bar to force-quit from).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        let W: CGFloat = 600, H: CGFloat = 660, M: CGFloat = 18
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Icon Normalizer"; window.center()
        let v = window.contentView!

        @discardableResult
        func lbl(_ s: String, _ f: NSRect, bold: Bool = false, size: CGFloat = 13,
                 gray: Bool = false) -> NSTextField {
            let t = NSTextField(labelWithString: s); t.frame = f
            t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            if gray { t.textColor = .secondaryLabelColor }
            t.lineBreakMode = .byWordWrapping; t.maximumNumberOfLines = 2
            v.addSubview(t); return t
        }

        lbl("Icon Normalizer", NSRect(x: M, y: H-42, width: W-2*M, height: 26), bold: true, size: 17)
        statusLabel = lbl("…", NSRect(x: M, y: H-66, width: W-2*M, height: 18), size: 12, gray: true)

        // ---- log monitor ----
        lbl("Watcher log", NSRect(x: M, y: H-92, width: 200, height: 16), bold: true, size: 11)
        let bClear = NSButton(title: "Clear log", target: self, action: #selector(clearLog))
        bClear.frame = NSRect(x: W-M-104, y: H-97, width: 104, height: 22)
        bClear.bezelStyle = .rounded; bClear.controlSize = .small
        bClear.font = .systemFont(ofSize: 11)
        bClear.toolTip = "Empty the watcher log file."
        v.addSubview(bClear)
        let scroll = NSScrollView(frame: NSRect(x: M, y: 290, width: W-2*M, height: (H-98)-290))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView; v.addSubview(scroll)

        // ---- threshold ----
        lbl("Threshold", NSRect(x: M, y: 246, width: 80, height: 20))
        thresholdSlider = NSSlider(value: 0.92, minValue: 0.80, maxValue: 0.98,
                                   target: self, action: #selector(thresholdChanged))
        thresholdSlider.frame = NSRect(x: M+90, y: 244, width: 250, height: 22)
        thresholdSlider.toolTip = "Only icons whose art fills at least this fraction of the canvas are treated as oversized and resized."
        v.addSubview(thresholdSlider)
        thresholdValue = lbl("92%", NSRect(x: M+350, y: 246, width: 60, height: 20))
        lbl("Minimum fill to count an icon as oversized (lower = affects more apps).",
            NSRect(x: M, y: 226, width: W-2*M, height: 16), size: 11, gray: true)

        // ---- squircle ----
        lbl("Squircle", NSRect(x: M, y: 196, width: 80, height: 20))
        squircle = NSSegmentedControl(labels: ["Off", "Auto", "On"],
                                      trackingMode: .selectOne, target: nil, action: nil)
        squircle.frame = NSRect(x: M+90, y: 192, width: 200, height: 26)
        squircle.selectedSegment = 1
        squircle.toolTip = "Round square icons to Apple's native shape. Auto only does it when safe (flat, uniform corners); On may clip bordered icons."
        v.addSubview(squircle)
        lbl("Off: keep shape · Auto: round only when safe · On: always (may clip borders).",
            NSRect(x: M, y: 174, width: W-2*M, height: 16), size: 11, gray: true)

        // ---- dry run ----
        dryRun = NSButton(checkboxWithTitle: "Dry run — preview what would change, apply nothing",
                          target: nil, action: nil)
        dryRun.frame = NSRect(x: M, y: 142, width: W-2*M, height: 20)
        dryRun.toolTip = "Show which apps Apply would touch, without changing any icons."
        v.addSubview(dryRun)

        // ---- main buttons ----
        @discardableResult
        func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat,
                    _ sel: Selector, tip: String, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: y, width: w, height: 34)
            b.bezelStyle = .rounded; b.toolTip = tip
            if !key.isEmpty { b.keyEquivalent = key }
            v.addSubview(b); return b
        }
        button("Apply now", M, 92, 150, #selector(apply),
               tip: "Normalize oversized icons now with the settings above (asks for admin password).", key: "\r")
        button("Reset icons", M+165, 92, 150, #selector(reset),
               tip: "Restore original icons AND stop the watcher so they stay reset.")
        button("Refresh", M+330, 92, 130, #selector(refresh),
               tip: "Reload status and log.")

        // ---- setup / watcher controls ----
        button("Install scanner", M, 42, 140, #selector(installScanner),
               tip: "Copy the scanner + venv into place for on-demand use (no background service).")
        button("Install watcher", M+148, 42, 140, #selector(installWatcher),
               tip: "Also install the background service that re-normalizes icons after app updates.")
        button("Start", M+296, 42, 90, #selector(startWatcher),
               tip: "Load the installed watcher.")
        button("Stop", M+394, 42, 90, #selector(stopWatcher),
               tip: "Unload the watcher. Icons stay as they are until you start it again.")
        lbl("Scanner = on-demand (Apply). Watcher = optional auto re-apply. Reset stops the watcher.",
            NSRect(x: M, y: 16, width: W-2*M, height: 16), size: 11, gray: true)

        thresholdChanged(thresholdSlider)
        refresh(self)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.refresh(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func thresholdString() -> String { String(format: "%.2f", thresholdSlider.doubleValue) }
    func squircleFlag() -> String {
        switch squircle.selectedSegment { case 0: return "--no-squircle"; case 2: return "--squircle"; default: return "" }
    }

    @objc func thresholdChanged(_ s: Any?) {
        thresholdValue.stringValue = "\(Int((thresholdSlider.doubleValue*100).rounded()))%"
    }

    @objc func refresh(_ sender: Any?) {
        let plist = runShell("ls /Library/LaunchDaemons/*icon-normalizer*.plist 2>/dev/null | head -1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = !plist.isEmpty && FileManager.default.fileExists(atPath: NRM)
        var running = false
        if installed {
            let label = (plist as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            running = runShell("launchctl print system/\(label) >/dev/null 2>&1 && echo yes")
                .contains("yes")
        }
        let last = runShell("tail -n 1 \(shq(LOG)) 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = installed
            ? "Watcher: \(running ? "running ✓" : "stopped ✕")   •   \(last.isEmpty ? "no log yet" : last)"
            : "Not set up yet — click “Install watcher”, or just press Apply now."
        let tail = runShell("tail -n 200 \(shq(LOG)) 2>/dev/null")
        if logView.string != tail { logView.string = tail; logView.scrollToEndOfDocument(nil) }
    }

    func runAdminAction(_ cmd: String, _ status: String) {
        if busy { return }
        busy = true; statusLabel.stringValue = status
        DispatchQueue.global().async {
            _ = runAdmin(cmd)
            DispatchQueue.main.async { self.busy = false; self.refresh(nil) }
        }
    }

    var backendInstalled: Bool { FileManager.default.fileExists(atPath: NRM) }

    func alertInstallFirst() {
        let a = NSAlert(); a.messageText = "Scanner isn't set up yet"
        a.informativeText = "Click “Install watcher” first (or just use Apply now — it sets things up on first use)."
        a.runModal()
    }

    @objc func apply(_ sender: Any?) {
        if busy { return }
        let env = "ICON_NORMALIZER_THRESHOLD=\(thresholdString())"
        if dryRun.state == .on {
            guard backendInstalled else { alertInstallFirst(); return }
            busy = true; statusLabel.stringValue = "Previewing…"
            let cmd = "\(env) \(shq(PY)) \(shq(NRM)) --dry-run \(squircleFlag())"
            DispatchQueue.global().async {
                let out = runShell(cmd)
                DispatchQueue.main.async {
                    self.busy = false
                    let a = NSAlert(); a.messageText = "Dry-run preview"
                    a.informativeText = out.isEmpty ? "(no output)" : out; a.runModal()
                    self.refresh(nil)
                }
            }
            return
        }
        // Real apply: if the backend isn't installed yet, set it up first (no watcher).
        let prefix = backendInstalled ? "" : "bash \(shq(INSTALLER)) >/dev/null 2>&1 && "
        let cmd = prefix + "\(env) \(shq(PY)) \(shq(NRM)) --force \(squircleFlag())"
        runAdminAction(cmd, backendInstalled ? "Applying (enter admin password)…"
                                             : "Setting up + applying (enter admin password)…")
    }

    @objc func installScanner(_ sender: Any?) {
        runAdminAction("bash \(shq(INSTALLER))", "Installing scanner (enter admin password)…")
    }
    @objc func installWatcher(_ sender: Any?) {
        runAdminAction("bash \(shq(INSTALLER)) --watcher", "Installing watcher (enter admin password)…")
    }

    @objc func reset(_ sender: Any?) {
        if busy { return }
        guard backendInstalled else { alertInstallFirst(); return }
        let a = NSAlert()
        a.messageText = "Restore original icons?"
        a.informativeText = "Removes the custom icons applied by this tool and stops the watcher so they stay reset."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runAdminAction("\(shq(PY)) \(shq(NRM)) --revert", "Resetting (enter admin password)…")
    }

    @objc func clearLog(_ s: Any?) {
        runAdminAction("\(shq(PY)) \(shq(NRM)) --clear-log", "Clearing log…")
    }
    @objc func startWatcher(_ s: Any?) {
        runAdminAction("\(shq(PY)) \(shq(NRM)) --start-watcher", "Starting watcher…")
    }
    @objc func stopWatcher(_ s: Any?) {
        runAdminAction("\(shq(PY)) \(shq(NRM)) --stop-watcher", "Stopping watcher…")
    }
}

let app = NSApplication.shared
let ctrl = Controller()
app.delegate = ctrl
app.setActivationPolicy(.regular)
app.run()
