import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

// Icono en la barra de menus de macOS para activar/desactivar el
// "Natural scrolling".
// Verde = activado, rojo = desactivado. Clic en el icono y luego en el
// primer elemento del menu para alternar.
//
// El toggle acciona el interruptor real de Ajustes del Sistema (mismo
// efecto que hacerlo a mano): la escritura directa de la preferencia no
// la aplica en caliente en macOS recientes. Requiere permiso de
// Accesibilidad para la app (se solicita una vez). Si no hay permiso o
// falla, se usa la escritura directa como fallback.

final class StatusController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let prefKey = "com.apple.swipescrolldirection" as CFString
    private let settingsBundleID = "com.apple.systempreferences"
    private let trackpadPaneURL = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!
    private var shownState: Bool?
    private var toggling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private var naturalEnabled: Bool {
        CFPreferencesCopyAppValue(prefKey, kCFPreferencesAnyApplication) as? Bool ?? false
    }

    // MARK: - Alternar via Ajustes del Sistema (mismo efecto que a mano)

    @objc private func toggle() {
        guard !toggling else { return }
        toggling = true
        let previous = naturalEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.toggleViaSettingsUI(from: previous)
            if !ok {
                FileHandle.standardError.write(Data("fallback: escritura directa\n".utf8))
                self.setNaturalDirect(!previous)
            }
            Thread.sleep(forTimeInterval: 0.6)
            DispatchQueue.main.async {
                self.shownState = nil
                self.refresh()
                self.toggling = false
            }
        }
    }

    private func toggleViaSettingsUI(from current: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard trusted else {
            DispatchQueue.main.async { self.showAccessibilityHelp() }
            return false
        }

        let settingsWasRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: settingsBundleID)
            .contains { !$0.isTerminated }

        // Abrir el panel Trackpad sin robar el foco
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

        // Pestaña "Scroll & Zoom": radio del medio del grupo de pestanas
        guard let radios = waitForElements(in: window, role: "AXRadioButton", minCount: 3, timeout: 8),
              radios.count >= 3 else { return false }
        AXUIElementPerformAction(radios[1], "AXPress" as CFString)
        Thread.sleep(forTimeInterval: 0.5)

        // Primer checkbox del contenido = "Natural scrolling"
        guard let boxes = waitForElements(in: window, role: "AXCheckBox", minCount: 1, timeout: 8),
              !boxes.isEmpty else { return false }
        AXUIElementPerformAction(boxes[0], "AXPress" as CFString)

        // Verificar que el valor cambio
        var changed = false
        for _ in 0..<30 where !changed {
            Thread.sleep(forTimeInterval: 0.1)
            changed = naturalEnabled != current
        }

        // Cerrar la ventana solo si la abrimos nosotros
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

    // MARK: - Fallback: escritura directa de la preferencia

    private func setNaturalDirect(_ enabled: Bool) {
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

    // MARK: - Interfaz

    private func refresh() {
        let on = naturalEnabled
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
        let toggle = NSMenuItem(title: on ? "Natural scrolling: activado" : "Natural scrolling: desactivado",
                                action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        toggle.state = on ? .on : .off
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
