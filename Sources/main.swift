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
    private var settingsWindow: AXUIElement?

    private var autoMode: Bool {
        get { defaults.object(forKey: "autoMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createStatusItem()
        watcher = MouseWatcher { [weak self] connected in
            guard let self else { return }
            if !self.autoMode {
                log("Transicion ignorada (modo manual): raton \(connected ? "conectado" : "desconectado")")
                return
            }
            self.requestApply(!connected)
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("Iniciado v\(version) pid=\(ProcessInfo.processInfo.processIdentifier) (modo \(autoMode ? "automatico" : "manual"))")
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if osMajor < 26 {
            log("ADVERTENCIA: macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion) no soportado; se requiere macOS 26 o posterior")
            DispatchQueue.main.async { self.showVersionWarning() }
        }
        if let button = statusItem.button {
            log("Icono: frame=\(button.frame) imagen=\(button.image != nil ? "ok" : "ausente")")
        } else {
            log("Icono: SIN BOTON (se reintentara en el proximo refresco)")
        }
        watcher?.reevaluate()

        // Pedir el permiso de Accesibilidad al arrancar si falta: el cambio
        // de scroll solo es efectivo en caliente con este permiso.
        if !AXIsProcessTrustedWithOptions(nil) {
            log("Accesibilidad: sin permiso; solicitandolo")
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        ensureSupportFiles()
    }

    private func ensureSupportFiles() {
        guard !FileManager.default.fileExists(atPath: ignoreFile) else { return }
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let template = """
        # Devices with a dormant "mouse" HID interface that should NOT trigger
        # mouse mode (keyboards, audio interfaces, docks...). One exact product
        # name per line. Detected devices are listed in:
        # \(logFile)

        """
        try? template.write(toFile: ignoreFile, atomically: true, encoding: .utf8)
        log("Creado \(ignoreFile) (editable)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the System Settings window we kept open for reuse.
        if let window = settingsWindow, let close = findCloseButton(of: window) {
            AXUIElementPerformAction(close, "AXPress" as CFString)
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    ///
    /// The System Settings window is opened once (in the background) and
    /// kept open for reuse, so toggling does not flash a new window every
    /// time. It is closed when this app quits (applicationWillTerminate).
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

        // Make sure System Settings is running; open it in the background if not.
        var app = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleID)
            .first
        if app == nil {
            let semaphore = DispatchSemaphore(value: 0)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(trackpadPaneURL, configuration: config) { opened, _ in
                app = opened
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
        }
        guard let app else { return false }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        // Always (re)open the Trackpad pane: with an existing window this
        // navigates it (e.g. away from Privacy > Accessibility, where macOS
        // leaves the window after granting the permission), it does not
        // create a new window.
        let openSemaphore = DispatchSemaphore(value: 0)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(trackpadPaneURL, configuration: config) { _, _ in
            openSemaphore.signal()
        }
        _ = openSemaphore.wait(timeout: .now() + 10)

        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, "AXWindows" as CFString, &windowsRef)
        var window = (windowsRef as? [AXUIElement])?.first
        if window == nil {
            window = waitForWindow(appEl, timeout: 10)
        }
        guard let window else { return false }
        settingsWindow = window
        log("Ventana de Ajustes: titulo='\(axString(window, "AXTitle") ?? "?")' (reutilizada/navigated)")

        Thread.sleep(forTimeInterval: 0.5)

        // Select the "Scroll & Zoom" tab.
        // macOS 26: tab group of 3 AXRadioButton (middle one).
        // macOS 27: the tabs are labeled checkboxes ("Point & Click",
        // "Scroll & Zoom", "More Gestures"); AXActions may not list AXPress,
        // so press by label without consulting the actions attribute.
        let radios = findAll(window, role: "AXRadioButton")
        if !radios.isEmpty {
            let radioLabels = radios.map { elementLabel($0) ?? axString($0, "AXTitle") ?? "?" }
            log("AX: radios=\(radios.count) etiquetas=\(radioLabels.joined(separator: " | "))")
            let targetRadio = zip(radios, radioLabels).first { $0.1.contains("Scroll") }?.0
                ?? (radios.count >= 3 ? radios[1] : nil)
            if let r = targetRadio, checkboxValue(r) != "1" {
                AXUIElementPerformAction(r, "AXPress" as CFString)
                Thread.sleep(forTimeInterval: 0.4)
            }
        }

        func pressScrollTab() -> Bool {
            let labeled = findAll(window, role: "AXCheckBox")
                + findAll(window, role: "AXButton")
                + findAll(window, role: "AXStaticText")
            if let t = labeled.first(where: {
                let l = elementLabel($0) ?? axString($0, "AXTitle") ?? ""
                return l == "Scroll & Zoom"
            }) {
                AXUIElementPerformAction(t, "AXPress" as CFString)
                return true
            }
            return false
        }

        // Wait for the checkbox labeled "Natural scrolling" (the pane loads
        // asynchronously). If the tab press did not take effect, retry it.
        var target: AXUIElement?
        let deadline = Date().addingTimeInterval(10)
        var lastLabels: [String] = []
        var radiosHandledTab = !radios.isEmpty
        var presses = 0
        var lastPress = Date.distantPast
        while Date() < deadline && target == nil {
            let boxes = findAll(window, role: "AXCheckBox")
            lastLabels = boxes.map { elementLabel($0) ?? axString($0, "AXTitle") ?? "?" }
            target = boxes.first(where: { elementLabel($0) == "Natural scrolling" })
                ?? boxes.first(where: { elementLabel($0)?.lowercased().contains("natural") == true })
            if target == nil {
                let canRetry = !radiosHandledTab || (Date().timeIntervalSince(lastPress) > 2.5 && presses < 3)
                if canRetry && pressScrollTab() {
                    if radiosHandledTab { presses += 1 }
                    radiosHandledTab = true
                    lastPress = Date()
                    log("AX: pestana 'Scroll & Zoom' pulsada (intento \(presses + 1))")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard let checkbox = target else {
            log("AX: no aparecio checkbox 'Natural scrolling'. ultimas etiquetas=\(lastLabels.joined(separator: " | "))")
            dumpWindow(window)
            return false
        }
        log("AX: objetivo='Natural scrolling' valor-antes=\(checkboxValue(checkbox) ?? "?")")
        AXUIElementPerformAction(checkbox, "AXPress" as CFString)

        var changed = false
        for _ in 0..<30 where !changed {
            Thread.sleep(forTimeInterval: 0.1)
            changed = naturalScrollingEnabled() != current
        }
        log("AX: valor-despues=\(checkboxValue(checkbox) ?? "?") cambiada=\(changed)")

        // Keep the window for reuse; close it when this app quits.
        settingsWindow = window
        return changed
    }

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func elementLabel(_ el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXTitleUIElement" as CFString, &ref) == .success,
              let obj = ref else { return nil }
        let labelEl = obj as! AXUIElement  // AXTitleUIElement always returns an AXUIElement
        return axString(labelEl, "AXValue")
    }

    /// Diagnostic: dump the window's AX tree (role | label | pressable |
    /// value) to the log, so an unfamiliar macOS layout can be analyzed
    /// from a user's log without extra tools.
    private func dumpWindow(_ window: AXUIElement, limit: Int = 200) {
        log("AXDUMP: begin")
        var queue: [AXUIElement] = [window]
        var visited = 0
        var lines = 0
        while !queue.isEmpty && visited < 4000 && lines < limit {
            let el = queue.removeFirst()
            visited += 1
            let role = axString(el, "AXRole") ?? "?"
            if role == "AXGroup" || role == "AXLayoutItem" || role == "AXUnknown" {
                // skip noisy containers but still descend
            } else {
                let label = elementLabel(el) ?? axString(el, "AXTitle") ?? axString(el, "AXDescription") ?? ""
                var actsRef: CFTypeRef?
                var press = false
                if AXUIElementCopyAttributeValue(el, "AXActions" as CFString, &actsRef) == .success,
                   let actions = actsRef as? [String] {
                    press = actions.contains("AXPress")
                }
                let value = checkboxValue(el) ?? ""
                log("AXDUMP: \(role) | \(label) | press=\(press ? 1 : 0) | val=\(value)")
                lines += 1
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        log("AXDUMP: end (lines=\(lines))")
    }

    private func checkboxValue(_ cb: AXUIElement) -> String? {
        axString(cb, "AXValue")
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

    private func showVersionWarning() {
        let alert = NSAlert()
        alert.messageText = "Versión de macOS no soportada"
        alert.informativeText = "Natural Scroll Toggle requiere macOS 26 o posterior. Este Mac tiene macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion); la app no funcionará correctamente."
        alert.addButton(withTitle: "Aceptar")
        alert.runModal()
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
        let desired = !naturalScrollingEnabled()
        log("Modo manual (natural -> \(desired ? "ON" : "OFF"))")
        // Si falta el permiso, pedirlo interactivamente: asi salta el
        // dialogo del sistema que lleva directo a Ajustes.
        if !AXIsProcessTrustedWithOptions(nil) {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            showAccessibilityHelp()
        }
        requestApply(desired)
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
        // La barra de menús puede retirar el item en algunas condiciones:
        // recrearlo si desaparecio.
        if statusItem == nil || statusItem.button == nil {
            createStatusItem()
            shownState = nil
        }
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
        if button.image == nil {
            // Fallback visible si el simbolo SF no cargara en este Mac
            button.title = on ? "⇅" : "↑↓"
            button.appearance = nil
        } else {
            button.title = ""
        }
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
