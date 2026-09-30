import AppKit

// Uses native REAPER command-line support; no keystrokes or Accessibility access.
final class Launcher: NSObject, NSApplicationDelegate {
    private var process: Process?

    private func fail(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn’t open Solo Studio"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared
        guard let reaper = workspace.urlForApplication(withBundleIdentifier: "com.cockos.reaper"),
              let executable = Bundle(url: reaper)?.executableURL else {
            fail("Install REAPER in Applications, then open Solo Studio again.")
            return
        }
        guard let script = Bundle.main.url(forResource: "launch", withExtension: "lua") else {
            fail("The launcher is incomplete. Rebuild it from the Solo Studio repository.")
            return
        }
        let arguments = ["-nonewinst", script.path]
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cockos.reaper").first {
            // Launch Services ignores new arguments when an app is already running.
            // REAPER's -nonewinst forwards this script to its existing process.
            let child = Process()
            child.executableURL = executable
            child.arguments = arguments
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { child in
                DispatchQueue.main.async {
                    if child.terminationStatus != 0 {
                        self.fail("REAPER couldn’t accept the launch request. Open REAPER and press Command–Option–Shift–P.")
                    } else {
                        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                        NSApp.terminate(nil)
                    }
                }
            }
            process = child
            do { try child.run() } catch { fail(error.localizedDescription) }
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.activates = true
            workspace.openApplication(at: reaper, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if let error = error { self.fail(error.localizedDescription) }
                    else { NSApp.terminate(nil) }
                }
            }
        }
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.setActivationPolicy(.accessory)
app.delegate = launcher
app.run()
