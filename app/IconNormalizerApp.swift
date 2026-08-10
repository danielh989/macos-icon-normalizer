// Icon Normalizer — small AppKit control panel for the icon-normalizer daemon.
// Monitors the watcher log, and applies / resets icons with the chosen flags.
// Build with app/build.sh (needs the Swift toolchain from Xcode / CLT).
import AppKit

let INSTALL = "/usr/local/icon-normalizer"
let PY  = "\(INSTALL)/venv/bin/python"
let NRM = "\(INSTALL)/normalizer.py"
let LOG = "\(INSTALL)/icon-normalizer.log"

// Run a shell command as the current user; return combined stdout+stderr.
func runShell(_ cmd: String) -> String {
    let p = Process()
    p.launchPath = "/bin/bash"
    p.arguments = ["-lc", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "error: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// Run a shell command as root via the native admin-password prompt.
func runAdmin(_ cmd: String) -> String {
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"")
    let osa = "do shell script \"\(escaped)\" with administrator privileges"
    let p = Process()
    p.launchPath = "/usr/bin/osascript"
    p.arguments = ["-e", osa]
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "error: \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var squircle: NSSegmentedControl!
    var dryRun: NSButton!
    var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let W: CGFloat = 560, H: CGFloat = 540, M: CGFloat = 16
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Icon Normalizer"
        window.center()
        let v = window.contentView!

        func label(_ s: String, _ f: NSRect, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
            let t = NSTextField(labelWithString: s); t.frame = f
            t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            v.addSubview(t); return t
        }

        label("Icon Normalizer", NSRect(x: M, y: H-40, width: W-2*M, height: 24), bold: true, size: 17)
        statusLabel = label("…", NSRect(x: M, y: H-64, width: W-2*M, height: 18), size: 12)
        statusLabel.textColor = .secondaryLabelColor

        // Log monitor
        label("Watcher log", NSRect(x: M, y: H-92, width: 200, height: 16), bold: true, size: 11)
        let scroll = NSScrollView(frame: NSRect(x: M, y: 150, width: W-2*M, height: H-92-150-6))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView
        v.addSubview(scroll)

        // Squircle selector
        label("Squircle:", NSRect(x: M, y: 112, width: 70, height: 20))
        squircle = NSSegmentedControl(labels: ["Off", "Auto", "On"],
                                      trackingMode: .selectOne, target: nil, action: nil)
        squircle.frame = NSRect(x: M+70, y: 108, width: 200, height: 26)
        squircle.selectedSegment = 1  // Auto
        v.addSubview(squircle)

        dryRun = NSButton(checkboxWithTitle: "Dry run (preview only, no changes)",
                          target: nil, action: nil)
        dryRun.frame = NSRect(x: M, y: 80, width: W-2*M, height: 20)
        v.addSubview(dryRun)

        // Buttons
        func button(_ title: String, _ x: CGFloat, _ sel: Selector, key: String = "") -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: M, width: 150, height: 34)
            b.bezelStyle = .rounded
            if !key.isEmpty { b.keyEquivalent = key }
            v.addSubview(b); return b
        }
        button("Apply now", M, #selector(apply), key: "\r")
        button("Reset icons", M+160, #selector(reset))
        button("Refresh", M+320, #selector(refresh))

        refresh(self)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func squircleFlag() -> String {
        switch squircle.selectedSegment {
        case 0: return "--no-squircle"
        case 2: return "--squircle"
        default: return ""
        }
    }

    @objc func refresh(_ sender: Any?) {
        // status
        let plist = runShell("ls /Library/LaunchDaemons/*icon-normalizer*.plist 2>/dev/null | head -1").trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = !plist.isEmpty && FileManager.default.fileExists(atPath: NRM)
        let last = runShell("tail -n 1 \(shq(LOG)) 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel.stringValue = installed
            ? "Watcher: installed ✓   •   last log: \(last.isEmpty ? "—" : last)"
            : "Watcher: not installed — run install.sh first"
        // log tail
        let tail = runShell("tail -n 200 \(shq(LOG)) 2>/dev/null")
        if logView.string != tail {
            logView.string = tail
            logView.scrollToEndOfDocument(nil)
        }
    }

    func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func setBusy(_ b: Bool) { busy = b }

    @objc func apply(_ sender: Any?) {
        if busy { return }
        let sq = squircleFlag()
        let dry = dryRun.state == .on
        let cmd = "\(shq(PY)) \(shq(NRM)) \(dry ? "--dry-run" : "--force") \(sq)"
        setBusy(true)
        statusLabel.stringValue = dry ? "Previewing…" : "Applying (enter admin password)…"
        DispatchQueue.global().async {
            let out = dry ? runShell(cmd) : runAdmin(cmd)
            DispatchQueue.main.async {
                self.setBusy(false)
                if dry { self.showSheet("Dry-run preview", out) }
                self.refresh(nil)
            }
        }
    }

    @objc func reset(_ sender: Any?) {
        if busy { return }
        let alert = NSAlert()
        alert.messageText = "Restore original icons?"
        alert.informativeText = "This removes the custom icons applied by this tool."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cmd = "\(shq(PY)) \(shq(NRM)) --revert"
        setBusy(true)
        statusLabel.stringValue = "Resetting (enter admin password)…"
        DispatchQueue.global().async {
            _ = runAdmin(cmd)
            DispatchQueue.main.async { self.setBusy(false); self.refresh(nil) }
        }
    }

    func showSheet(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title
        a.informativeText = body.isEmpty ? "(no output)" : body
        a.runModal()
    }
}

let app = NSApplication.shared
let ctrl = Controller()
app.delegate = ctrl
app.setActivationPolicy(.regular)
app.run()
