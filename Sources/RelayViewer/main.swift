// RelayViewer — versione da Terminale del Viewer (iMac, Intel, macOS Monterey 12.3+).
// Va subito a schermo intero. Esc per uscire.

import AppKit
import ViewerCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let viewer = ViewerController(mode: .standalone)
do {
    try viewer.start()
} catch {
    print(error)
    exit(1)
}

app.activate(ignoringOtherApps: true)
app.run()
