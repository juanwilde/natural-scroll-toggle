import AppKit
import ApplicationServices
import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

// Natural Scroll Toggle
// ---------------------
// Menu bar toggle for macOS "Natural scrolling" with an optional automatic
// mode:
//
//   - Automatic mode (default): watches for external mice (USB, Bluetooth,
//     2.4 GHz dongles). Mouse connected -> Natural scrolling OFF; no mouse ->
//     ON. Designed for people who like natural scrolling on the trackpad but
//     classic scrolling with a mouse wheel.
//   - Manual mode: click the menu item to flip the setting; this disables
//     automatic mode until re-enabled from the menu.
//
// Why not just write com.apple.swipescrolldirection? On modern macOS a direct
// preference write does NOT apply the change to the running system. Instead,
// the app operates the real System Settings switch (Trackpad pane) through
// the Accessibility API, which is exactly what a human toggle does, so the
// change takes effect everywhere immediately. If the Accessibility permission
// is missing, it falls back to the direct write (+ cfprefsd/hidd restart).

private let prefKey = "com.apple.swipescrolldirection" as CFString
private let supportDir = NSHomeDirectory() + "/Library/Application Support/natural-scroll-toggle"
private let ignoreFile = supportDir + "/ignore.txt"
private let logFile = NSHomeDirectory() + "/Library/Logs/natural-scroll-toggle.log"

func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    if let data = line.data(using: .utf8),
       let handle = FileHandle(forWritingAtPath: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else if let data = line.data(using: .utf8) {
        try? data.write(to: URL(fileURLWithPath: logFile))
    }
}

func naturalScrollingEnabled() -> Bool {
    CFPreferencesCopyAppValue(prefKey, kCFPreferencesAnyApplication) as? Bool ?? false
}

func setNaturalScrollingDirect(_ enabled: Bool) {
    CFPreferencesSetValue(prefKey, enabled as CFPropertyList,
                          kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost)
    for daemon in ["cfprefsd", "hidd"] {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = [daemon]
        try? kill.run()
        kill.waitUntilExit()
    }
}

// MARK: - Mouse watcher (IOKit HID)

final class MouseWatcher {
    private let manager: IOHIDManager
    private let onChange: (Bool) -> Void
    private var debounce: DispatchWorkItem?
    private var lastState: Bool?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager,
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)

        let callback: IOHIDDeviceCallback = { context, _, _, device in
            guard let context else { return }
            let watcher = Unmanaged<MouseWatcher>.fromOpaque(context).takeUnretainedValue()
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            log("Evento HID: \(name)")
            watcher.scheduleReevaluate()
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        scheduleHeartbeat()
    }

    var mouseConnected: Bool { lastState ?? false }

    private func loadIgnoredProducts() -> Set<String> {
        guard let text = try? String(contentsOfFile: ignoreFile, encoding: .utf8) else { return [] }
        return Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    private func isExternalMouse(_ device: IOHIDDevice, ignored: Set<String>) -> Bool {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
        let lower = name.lowercased()
        if lower.contains("trackpad") || lower.contains("internal") { return false }
        if ignored.contains(name) { return false }
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        if transport == "SPI" || transport == "I2C" || transport == "FIFO" { return false }
        return true
    }

    func reevaluate() {
        let ignored = loadIgnoredProducts()
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let mice = devices.filter { isExternalMouse($0, ignored: ignored) }
        let names = mice.map { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "?" }
        let connected = !mice.isEmpty
        if connected != lastState {
            lastState = connected
            log("Ratones externos: \(connected ? names.joined(separator: ", ") : "ninguno")")
            onChange(connected)
        }
    }

    func scheduleReevaluate() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reevaluate() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func scheduleHeartbeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reevaluate()
            self?.scheduleHeartbeat()
        }
    }
}

// MARK: - Menu bar app

final class StatusController: NSObject, NSApplicationDelegate {
    private let settingsBundleID = "com.apple.systempreferences"
    private let trackpadPaneURL = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var watcher: MouseWatcher?
    private var shownState: Bool?
    private var applyBusy = false
    private var pendingDesired: Bool?

    private var autoMode: Bool {
        get { defaults.object(forKey: "autoMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        watcher = MouseWatcher { [weak self] connected in
            guard let self, self.autoMode else { return }
            self.requestApply(!connected)
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        log("Iniciado (modo \(autoMode ? "automatico" : "manual"))")
        watcher?.reevaluate()
    }

    // MARK: Applying changes

    /// Applies `desired` if the current setting differs. Serialized; requests
    /// received while busy are queued and applied afterwards.
    private func requestApply(_ desired: Bool) {
        if applyBusy {
            pendingDesired = desired
            return
        }
        applyBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.performApply(desired)
            DispatchQueue.main.async {
                self.applyBusy = false
                self.shownState = nil
                self.refresh()
                if let pending = self.pendingDesired {
                    self.pendingDesired = nil
                    if pending != naturalScrollingEnabled() {
                        self.requestApply(pending)
                    }
                }
            }
        }
    }

    private func performApply(_ desired: Bool) {
        let current = naturalScrollingEnabled()
        guard current != desired else {
            log("Ya en el estado deseado: \(desired ? "ON" : "OFF")")
            return
        }
        log("Aplicando natural scrolling -> \(desired ? "ON" : "OFF")")
        let trusted = AXIsProcessTrustedWithOptions(nil)
        if trusted && toggleViaSettingsUI(from: current, prompt: false) {
            log("Aplicado via Ajustes del Sistema")
        } else {
            if !trusted {
                log("SIN permiso de Accesibilidad: se usa escritura directa (NO aplica en caliente). Activalo en Ajustes > Privacidad y seguridad > Accesibilidad.")
            } else {
                log("No se pudo operar el interruptor de Ajustes; fallback a escritura directa")
            }
            setNaturalScrollingDirect(desired)
        }
    }

    /// Flips the real System Settings switch via the Accessibility API.
    /// Returns true if the preference value actually changed.
    private func toggleViaSettingsUI(from current: Bool, prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary? = prompt ? [promptKey: true] as CFDictionary : nil
        guard AXIsProcessTrustedWithOptions(options) else {
            if prompt {
                DispatchQueue.main.async { self.showAccessibilityHelp() }
            } else {
                self.notifyMissingAccessibilityOnce()
            }
            return false
        }

        let settingsWasRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleID)
            .contains { !$0.isTerminated }

        let semaphore = DispatchSemaphore(value: 0)
        var openedApp: NSRunningApplication?
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(trackpadPaneURL, configuration: config) { app, _ in
            openedApp = app
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        guard let app = openedApp ??
                NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first
        else { return false }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = waitForWindow(appEl, timeout: 10) else { return false }

        // "Scroll & Zoom" tab: middle radio button of the pane's tab group
        guard let radios = waitForElements(in: window, role: "AXRadioButton", minCount: 3, timeout: 8),
              radios.count >= 3 else { return false }
        AXUIElementPerformAction(radios[1], "AXPress" as CFString)
        Thread.sleep(forTimeInterval: 0.5)

        // First checkbox in the pane content = "Natural scrolling"
        guard let boxes = waitForElements(in: window, role: "AXCheckBox", minCount: 1, timeout: 8),
              !boxes.isEmpty else { return false }
        AXUIElementPerformAction(boxes[0], "AXPress" as CFString)

        var changed = false
        for _ in 0..<30 where !changed {
            Thread.sleep(forTimeInterval: 0.1)
            changed = naturalScrollingEnabled() != current
        }

        if !settingsWasRunning, let close = findCloseButton(of: window) {
            AXUIElementPerformAction(close, "AXPress" as CFString)
        }
        return changed
    }

    private func waitForWindow(_ appEl: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, "AXWindows" as CFString, &ref) == .success,
               let windows = ref as? [AXUIElement], let first = windows.first {
                return first
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    private func waitForElements(in root: AXUIElement, role: String, minCount: Int, timeout: TimeInterval) -> [AXUIElement]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = findAll(root, role: role)
            if found.count >= minCount { return found }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func findAll(_ root: AXUIElement, role: String) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 5000 {
            let el = queue.removeFirst()
            visited += 1
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &roleRef) == .success,
               roleRef as? String == role {
                result.append(el)
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    private func findCloseButton(of window: AXUIElement) -> AXUIElement? {
        findAll(window, role: "AXButton").first { el in
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(el, "AXSubrole" as CFString, &ref)
            return ref as? String == "AXCloseButton"
        }
    }

    private var accessibilityAlertShown = false

    private func notifyMissingAccessibilityOnce() {
        DispatchQueue.main.async {
            guard !self.accessibilityAlertShown else { return }
            self.accessibilityAlertShown = true
            self.showAccessibilityHelp()
        }
    }

    private func showAccessibilityHelp() {
        let alert = NSAlert()
        alert.messageText = "Se necesita permiso de Accesibilidad"
        alert.informativeText = "Para alternar el Natural scrolling como Ajustes del Sistema, concede acceso a Natural Scroll Toggle en: Ajustes del Sistema ▸ Privacidad y seguridad ▸ Accesibilidad. Hasta entonces se usará el modo directo (puede no aplicar en caliente)."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Aceptar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: Actions

    /// Manual toggle: disables automatic mode and flips the setting.
    @objc private func toggleManual() {
        autoMode = false
        log("Modo manual (natural -> \(!naturalScrollingEnabled() ? "ON" : "OFF"))")
        requestApply(!naturalScrollingEnabled())
    }

    @objc private func toggleAuto() {
        autoMode = !autoMode
        log("Modo \(autoMode ? "automatico" : "manual")")
        shownState = nil
        refresh()
        if autoMode {
            requestApply(!(watcher?.mouseConnected ?? false))
        }
    }

    // MARK: UI

    private func refresh() {
        let on = naturalScrollingEnabled()
        if on == shownState { return }
        shownState = on
        guard let button = statusItem.button else { return }
        let color: NSColor = on ? .systemGreen : .systemRed
        let symbol = NSImage(systemSymbolName: "arrow.up.arrow.down",
                             accessibilityDescription: "Natural scrolling")
        let configured = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [color]))
        button.image = configured ?? symbol
        button.image?.isTemplate = false
        button.toolTip = on ? "Natural scrolling: activado" : "Natural scrolling: desactivado"
        statusItem.menu = makeMenu(on: on)
    }

    private func makeMenu(on: Bool) -> NSMenu {
        let menu = NSMenu()

        let auto = NSMenuItem(title: "Automático (según ratón)",
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        menu.addItem(auto)

        let toggle = NSMenuItem(title: on ? "Natural scrolling: activado" : "Natural scrolling: desactivado",
                                action: #selector(toggleManual), keyEquivalent: "")
        toggle.target = self
        toggle.state = on ? .on : .off
        toggle.toolTip = "Desactiva el modo automático y alterna manualmente"
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }
}

let controller = StatusController()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
