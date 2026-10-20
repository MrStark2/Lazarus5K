// RelayHost — versione da Terminale dell'Host (Mac principale, Apple Silicon).
//
// Uso:  ./RelayHost                 → trova l'iMac via Bonjour
//       ./RelayHost 169.254.x.y     → si collega a un IP preciso

import Foundation
import HostCore

let session = HostSession(target: CommandLine.arguments.dropFirst().first)
session.onStateChange = { state in
    if case .failed = state { exit(1) }
}
session.start()
dispatchMain()
