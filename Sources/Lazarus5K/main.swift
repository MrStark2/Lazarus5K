// Lazarus5K — un'unica app per i due Mac, con un'icona nella barra dei menu.
// Sul Mac Apple Silicon fa da Host: crea il monitor virtuale e lo invia all'iMac.
// Sull'iMac Intel fa da Viewer in background: si mostra a schermo intero da solo
// quando il Mac principale si collega e sparisce quando si scollega.
// Il ruolo si può forzare con --host o --viewer.

import AppKit
import HostCore
import ViewerCore

enum Role {
    case host, viewer

    static func detect(_ arguments: [String]) -> Role {
        if arguments.contains("--host") { return .host }
        if arguments.contains("--viewer") { return .viewer }
        #if arch(arm64)
        return .host
        #else
        return .viewer
        #endif
    }
}

// MARK: - Avvio all'accesso (iMac)

/// LaunchAgent dell'utente: SMAppService richiede macOS 13, l'iMac è fermo a Monterey.
enum LoginItem {
    static let label = "io.github.mrstark2.lazarus5k.viewer"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Scrive (o aggiorna, se l'app è stata spostata) il LaunchAgent. Vale dal prossimo accesso.
    static func enable() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--viewer"],
            "RunAtLoad": true,
            // Riapre l'app solo se si chiude per un errore, non quando la chiudi tu.
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let role: Role
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggleItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var host: HostSession?
    private var viewer: ViewerController?

    init(role: Role) {
        self.role = role
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "display", accessibilityDescription: "Lazarus5K") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "5K"
        }
        statusItem = item

        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: role == .host ? "Lazarus5K · Mac principale" : "Lazarus5K · iMac",
                               action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        switch role {
        case .host: setUpHost(menu)
        case .viewer: setUpViewer(menu)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Esci da Lazarus5K", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        statusItem?.button?.toolTip = "Lazarus5K: \(text)"
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: Host

    private func setUpHost(_ menu: NSMenu) {
        let toggle = NSMenuItem(title: "", action: #selector(toggleHost), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        // Indirizzo fisso facoltativo, se Bonjour non trova l'iMac:
        // defaults write io.github.mrstark2.lazarus5k imacAddress 169.254.x.y
        let address = UserDefaults.standard.string(forKey: "imacAddress")
        let session = HostSession(target: address?.isEmpty == false ? address : nil)
        session.onStateChange = { [weak self] state in self?.hostStateChanged(state) }
        host = session
        startHost()
    }

    private func startHost() {
        guard let host else { return }
        // Al primo avvio macOS chiede il permesso; vale solo dopo aver riaperto l'app.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            setStatus("Manca il permesso Registrazione schermo")
            updateToggle()
            showAlert("Serve il permesso Registrazione schermo",
                      "Apri Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema, abilita Lazarus5K, poi chiudi e riapri l'app.")
            return
        }
        host.start()
    }

    @objc private func toggleHost() {
        guard let host else { return }
        if host.isRunning { host.stop() } else { startHost() }
    }

    private func updateToggle() {
        toggleItem?.title = host?.isRunning == true ? "Disattiva monitor iMac" : "Attiva monitor iMac"
    }

    private func hostStateChanged(_ state: HostState) {
        switch state {
        case .starting: setStatus("Avvio…")
        case .searching: setStatus("Cerco l'iMac sul cavo…")
        case .connecting: setStatus("Mi collego all'iMac…")
        case .connected: setStatus("Collegato all'iMac")
        case .reconnecting: setStatus("Collegamento perso, riprovo…")
        case .stopped: setStatus("Monitor iMac disattivato")
        case .failed(let message):
            setStatus("Errore: monitor disattivato")
            // Fuori dalla notifica di stato: l'avviso blocca finché non lo chiudi.
            DispatchQueue.main.async { self.showAlert("Lazarus5K si è fermato", message) }
        }
        updateToggle()
    }

    // MARK: Viewer

    private func setUpViewer(_ menu: NSMenu) {
        let reveal = NSMenuItem(title: "Mostra lo schermo del Mac", action: #selector(revealViewer), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = false
        menu.addItem(reveal)
        revealItem = reveal

        let login = NSMenuItem(title: "Avvia all'accesso", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginMenuItem = login

        // Al primo avvio l'avvio automatico si attiva da solo; poi decide il menu.
        let defaults = UserDefaults.standard
        do {
            if !defaults.bool(forKey: "loginItemConfigured") {
                try LoginItem.enable()
                defaults.set(true, forKey: "loginItemConfigured")
            } else if LoginItem.isEnabled {
                try LoginItem.enable() // aggiorna il percorso se l'app è stata spostata
            }
        } catch {
            print("Avvio all'accesso non configurato: \(error)")
        }
        updateLoginItem()

        let controller = ViewerController(mode: .background)
        controller.onStateChange = { [weak self] state in self?.viewerStateChanged(state) }
        do {
            try controller.start()
        } catch {
            setStatus("Errore: \(error)")
            showAlert("Lazarus5K non può ricevere lo schermo", "\(error)")
            return
        }
        viewer = controller
        viewerStateChanged(controller.state)
    }

    @objc private func revealViewer() {
        viewer?.reveal()
    }

    @objc private func toggleLoginItem() {
        do {
            if LoginItem.isEnabled { try LoginItem.disable() } else { try LoginItem.enable() }
        } catch {
            showAlert("Impossibile cambiare l'avvio all'accesso", "\(error)")
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        loginMenuItem?.state = LoginItem.isEnabled ? .on : .off
    }

    private func viewerStateChanged(_ state: ViewerState) {
        switch state {
        case .waiting: setStatus("In attesa del Mac principale…")
        case .showing: setStatus("Collegato: schermo visibile")
        case .dismissed: setStatus("Collegato: schermo nascosto (Esc)")
        }
        revealItem?.isEnabled = state == .dismissed
    }
}

// MARK: - Avvio

let app = NSApplication.shared

// Una sola copia alla volta: il Viewer occupa la porta di rete, l'Host il monitor virtuale.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if !others.isEmpty {
        print("Lazarus5K è già aperto.")
        exit(0)
    }
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate(role: Role.detect(CommandLine.arguments))
app.delegate = delegate
app.run()
