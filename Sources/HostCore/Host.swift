// Host — gira sul Mac principale (Apple Silicon).
// Crea un monitor virtuale Retina 5K ("sembra 2560×1440", 5120×2880 pixel reali),
// lo cattura, confronta ogni frame con l'ultimo inviato e manda all'iMac solo
// i tile 128×128 cambiati, compressi LZ4 senza perdita. Cattura anche l'audio di sistema.
// Usato sia da RelayHost (Terminale) sia dall'app Lazarus5K.

import Foundation
import CoreGraphics
import CoreMedia
import CoreAudio
import ScreenCaptureKit
import Compression
import Network
import IOKit.pwr_mgt
import CGVirtualDisplayPrivate
import Shared

// MARK: - Configurazione

let pixelWidth = 5120
let pixelHeight = 2880
let pointWidth = 2560
let pointHeight = 1440
let fps = 60
let audioSampleRate = 48_000
let audioChannels = 2

// MARK: - Monitor virtuale Retina

func makeVirtualDisplay() -> CGVirtualDisplay? {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = DispatchQueue.main
    descriptor.name = "iMac 5K (RelayLite)"
    descriptor.maxPixelsWide = UInt32(pixelWidth)
    descriptor.maxPixelsHigh = UInt32(pixelHeight)
    descriptor.sizeInMillimeters = CGSize(width: 597, height: 336) // 27" 16:9
    descriptor.vendorID = 0x1234
    descriptor.productID = 0x5678
    descriptor.serialNum = 2

    guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [
        CGVirtualDisplayMode(width: UInt(pointWidth), height: UInt(pointHeight), refreshRate: CGFloat(fps)),
        CGVirtualDisplayMode(width: UInt(pixelWidth), height: UInt(pixelHeight), refreshRate: CGFloat(fps)),
    ]
    guard display.applySettings(settings) else { return nil }
    return display
}

/// Forza la modalità "sembra 2560×1440" con 5120×2880 pixel reali.
func selectRetinaMode(_ displayID: CGDirectDisplayID) {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
    if let retina = modes.first(where: { $0.pixelWidth == pixelWidth && $0.width == pointWidth }) {
        let result = CGDisplaySetDisplayMode(displayID, retina, nil)
        print(result == .success ? "Modalità Retina 5K attiva." : "Impossibile attivare la modalità Retina (\(result.rawValue)).")
    } else {
        print("Modalità Retina 5K non trovata. Modalità disponibili:")
        for m in modes { print("  \(m.width)x\(m.height) punti → \(m.pixelWidth)x\(m.pixelHeight) pixel") }
    }
}

// MARK: - Risparmio energetico

/// Impedisce lo stop per inattività finché RelayHost è in esecuzione.
/// Chiudere il coperchio senza alimentatore e monitor manda comunque il Mac in stop.
func preventIdleSleep() -> IOPMAssertionID? {
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "RelayLite: l'iMac è in uso come monitor" as CFString, &id)
    guard result == kIOReturnSuccess else {
        print("Impossibile impedire lo stop per inattività (\(result)).")
        return nil
    }
    return id
}

/// Avvisa quando il Mac esce dallo stop (per esempio a coperchio chiuso e riaperto).
final class PowerMonitor {
    // Valori di iokit_common_msg(…) in IOKit/IOMessage.h: le macro non arrivano in Swift.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let port else {
            print("Impossibile ricevere le notifiche di stop e risveglio.")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    func stop() {
        guard rootPort != 0 else { return }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let port { IONotificationPortDestroy(port) }
        rootPort = 0
        port = nil
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case PowerMonitor.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case PowerMonitor.systemWillSleep:
            onSleep?()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case PowerMonitor.systemHasPoweredOn:
            onWake?()
        default:
            break
        }
    }
}

// MARK: - Rete

final class Sender {
    private let name: String
    private let maxPending: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NWConnection?
    private var pending = 0
    private var stopped = false
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onDrained: (() -> Void)?

    init(name: String, maxPending: Int) {
        self.name = name
        self.maxPending = maxPending
        self.queue = DispatchQueue(label: "relay.net.\(name)")
    }

    var canSend: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection != nil && pending < maxPending
    }

    /// Fornisce l'indirizzo dell'iMac: viene richiamato a ogni tentativo, così una
    /// riconnessione trova l'iMac anche se nel frattempo ha cambiato indirizzo.
    typealias EndpointProvider = (@escaping (NWEndpoint) -> Void) -> Void
    private var provider: EndpointProvider?

    func start(_ provider: @escaping EndpointProvider) {
        self.provider = provider
        attempt()
    }

    private func attempt() {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped, let provider else { return }
        provider { [weak self] endpoint in self?.connect(to: endpoint) }
    }

    private func connect(to endpoint: NWEndpoint) {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Dopo uno stop o un cavo staccato l'iMac non risponde più: senza keepalive
        // la connessione sembrerebbe aperta per sempre. Così cade in circa 10 secondi.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 10 // stesso limite per i dati inviati e mai confermati
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.wifi] // solo cavo

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[\(self.name)] connesso a \(endpoint)")
                self.setConnection(conn)
                self.onConnected?()
            case .waiting(let error), .failed(let error):
                print("[\(self.name)] connessione non riuscita (\(error)), riprovo tra 2 secondi…")
                self.setConnection(nil)
                conn.cancel()
                self.onDisconnected?()
                self.queue.asyncAfter(deadline: .now() + 2) { self.attempt() }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ message: Data) {
        lock.lock()
        guard let conn = connection else { lock.unlock(); return }
        pending += 1
        lock.unlock()

        conn.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            // Gli invii di una connessione ormai chiusa non contano più.
            guard self.connection === conn else { self.lock.unlock(); return }
            self.pending -= 1
            let drained = self.pending == 0
            self.lock.unlock()
            if let error { print("[\(self.name)] errore di invio: \(error)") }
            if drained { self.onDrained?() }
        })
    }

    /// Chiude la connessione e smette di ricollegarsi.
    func stop() {
        lock.lock()
        stopped = true
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
    }

    private func setConnection(_ conn: NWConnection?) {
        lock.lock(); connection = conn; pending = 0; lock.unlock()
    }
}

func discoverViewer(_ found: @escaping (NWEndpoint) -> Void) -> NWBrowser {
    let params = NWParameters.tcp
    params.prohibitedInterfaceTypes = [.wifi]
    let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
    browser.browseResultsChangedHandler = { results, _ in
        guard let result = results.first else { return }
        browser.cancel()
        found(result.endpoint)
    }
    browser.start(queue: .main)
    return browser
}

// MARK: - Tile: confronto con l'ultimo frame inviato + LZ4

final class TileEncoder {
    private var previous: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private var forceFull = true

    func reset() { forceFull = true }

    /// Restituisce il payload di un messaggio .tiles, oppure nil se non è cambiato nulla.
    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        if w != width || h != height || previous == nil {
            previous?.deallocate()
            previous = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64)
            width = w
            height = h
            forceFull = true
        }
        let prev = previous!
        let prevStride = w * 4
        let full = forceFull
        forceFull = false

        let cols = (w + tileSize - 1) / tileSize
        let rows = (h + tileSize - 1) / tileSize
        let count = cols * rows
        let results = UnsafeMutablePointer<Data?>.allocate(capacity: count)
        results.initialize(repeating: nil, count: count)
        defer { results.deinitialize(count: count); results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            let x = (i % cols) * tileSize
            let y = (i / cols) * tileSize
            let tw = min(tileSize, w - x)
            let th = min(tileSize, h - y)
            let rowBytes = tw * 4

            var changed = full
            if !changed {
                for r in 0..<th where memcmp(base + (y + r) * srcStride + x * 4,
                                             prev + (y + r) * prevStride + x * 4, rowBytes) != 0 {
                    changed = true
                    break
                }
            }
            guard changed else { return }

            // Copia il tile in un buffer contiguo e aggiorna il frame "ultimo inviato".
            let size = rowBytes * th
            let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            let packed = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { raw.deallocate(); packed.deallocate() }
            for r in 0..<th {
                let src = base + (y + r) * srcStride + x * 4
                memcpy(raw + r * rowBytes, src, rowBytes)
                memcpy(prev + (y + r) * prevStride + x * 4, src, rowBytes)
            }

            let packedSize = compression_encode_buffer(packed, size, raw, size, nil, COMPRESSION_LZ4)
            let useLZ4 = packedSize > 0 && packedSize < size

            var tile = Data(capacity: 13 + (useLZ4 ? packedSize : size))
            tile.appendBE(UInt16(x))
            tile.appendBE(UInt16(y))
            tile.appendBE(UInt16(tw))
            tile.appendBE(UInt16(th))
            tile.append((useLZ4 ? TileEncoding.lz4 : TileEncoding.raw).rawValue)
            tile.appendBE(UInt32(useLZ4 ? packedSize : size))
            tile.append(useLZ4 ? packed : raw, count: useLZ4 ? packedSize : size)
            results[i] = tile
        }

        var changedTiles: [Data] = []
        for i in 0..<count { if let t = results[i] { changedTiles.append(t) } }
        guard !changedTiles.isEmpty else { return nil }

        var payload = Data(capacity: 8 + changedTiles.reduce(0) { $0 + $1.count })
        payload.appendBE(UInt16(w))
        payload.appendBE(UInt16(h))
        payload.appendBE(UInt32(changedTiles.count))
        for t in changedTiles { payload.append(t) }
        return payload
    }
}

// MARK: - Audio: CMSampleBuffer → Float32 interleaved

func makeAudioPayload(_ sample: CMSampleBuffer) -> Data? {
    guard let fmt = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          asbd.mBitsPerChannel == 32 else { return nil }

    let frames = CMSampleBufferGetNumSamples(sample)
    let channels = Int(asbd.mChannelsPerFrame)
    guard frames > 0, channels > 0 else { return nil }

    let list = AudioBufferList.allocate(maximumBuffers: channels)
    defer { free(list.unsafeMutablePointer) }
    var block: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
        bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
    guard status == noErr else { return nil }

    var pcm = Data(count: frames * channels * 4)
    pcm.withUnsafeMutableBytes { raw in
        let dst = raw.bindMemory(to: Float.self)
        if list.count == 1, let src = list[0].mData {
            // Già interleaved (o mono).
            memcpy(dst.baseAddress!, src, min(Int(list[0].mDataByteSize), raw.count))
        } else {
            // Un buffer per canale: intreccia.
            for ch in 0..<min(channels, list.count) {
                guard let src = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames { dst[f * channels + ch] = src[f] }
            }
        }
    }

    var payload = Data(capacity: 10 + pcm.count)
    payload.appendBE(UInt32(asbd.mSampleRate))
    payload.appendBE(UInt16(channels))
    payload.appendBE(UInt32(frames))
    payload.append(pcm)
    return payload
}

// MARK: - Cattura

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "relay.capture")
    private let audioQueue = DispatchQueue(label: "relay.audio")
    private let tiles = TileEncoder()
    private let video: Sender
    private let audio: Sender
    private var stream: SCStream?
    private var lastFrame: CVPixelBuffer?
    private var frameWaiting = false
    // Stato di avvio e riavvio: si usa solo dalla coda principale.
    private var displayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var hasStarted = false
    private var restartPending = false
    private var generation = 0 // ogni riavvio annulla i tentativi di avvio ancora in corso
    private var stopped = false
    /// Errore al primo avvio (permesso mancante, monitor non trovato…). Coda principale.
    var onFatal: ((String) -> Void)?
    /// Cattura partita (anche dopo un riavvio). Coda principale.
    var onCapturing: (() -> Void)?

    init(video: Sender, audio: Sender) {
        self.video = video
        self.audio = audio
    }

    private static let maxDisplayRetries = 10

    /// Al primo avvio un errore è definitivo; dopo, la cattura viene riavviata.
    private func fail(_ message: String) {
        print(message)
        if hasStarted {
            restart(reason: "nuovo tentativo", delay: 5)
        } else {
            stop()
            onFatal?(message)
        }
    }

    /// Ferma tutto e annulla riavvii e tentativi in corso. Coda principale.
    func stop() {
        stopped = true
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
    }

    /// Ferma la cattura e la riavvia (dopo il risveglio o un'interruzione). Coda principale.
    func restart(reason: String, delay: TimeInterval = 2) {
        guard hasStarted, !restartPending, !stopped else { return }
        restartPending = true
        generation += 1
        let generation = self.generation
        print("Riavvio la cattura (\(reason)) tra \(Int(delay)) secondi…")
        stream?.stopCapture { _ in }
        stream = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.restartPending = false
            guard generation == self.generation else { return }
            selectRetinaMode(self.displayID)
            self.start(displayID: self.displayID)
        }
    }

    func start(displayID: CGDirectDisplayID, retry: Int = 0) {
        guard !stopped else { return }
        self.displayID = displayID
        let generation = self.generation
        // Un display in duplicazione non compare tra quelli catturabili da ScreenCaptureKit.
        let mirrored = CGDisplayMirrorsDisplay(displayID)
        if mirrored != kCGNullDirectDisplay {
            print("Il monitor virtuale duplica il display \(mirrored): disattivo la duplicazione…")
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                let result = CGCompleteDisplayConfiguration(config, .permanently)
                if result != .success { print("Disattivazione duplicazione fallita (\(result.rawValue))") }
            }
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                self.configure(content: content, error: error, displayID: displayID,
                               retry: retry, generation: generation)
            }
        }
    }

    /// Coda principale.
    private func configure(content: SCShareableContent?, error: Error?,
                           displayID: CGDirectDisplayID, retry: Int, generation: Int) {
        guard let content else {
            print("ScreenCaptureKit: \(error?.localizedDescription ?? "errore sconosciuto")")
            return fail("Permesso mancante: Impostazioni di Sistema › Privacy e sicurezza › Registrazione schermo e audio di sistema. Abilita il Terminale o Lazarus5K, poi riaprilo.")
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            if retry < Capturer.maxDisplayRetries {
                print("Monitor virtuale non ancora catturabile, riprovo (\(retry + 1)/\(Capturer.maxDisplayRetries))…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard generation == self.generation else { return }
                    self.start(displayID: displayID, retry: retry + 1)
                }
                return
            }
            print("Schermi catturabili:")
            for d in content.displays {
                print("  ID \(d.displayID): \(d.width)x\(d.height)")
            }
            print("CGDisplayIsOnline(\(displayID)) = \(CGDisplayIsOnline(displayID))")
            print("CGDisplayMirrorsDisplay(\(displayID)) = \(CGDisplayMirrorsDisplay(displayID))")
            return fail("Monitor virtuale (ID \(displayID)) non trovato tra gli schermi catturabili.")
        }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 5
        config.showsCursor = true
        if #available(macOS 13.0, *) {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = audioSampleRate
            config.channelCount = audioChannels
        } else if !hasStarted {
            print("Audio non disponibile: serve macOS 13 o successivo sul Mac principale.")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            if #available(macOS 13.0, *) {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
            }
        } catch {
            return fail("addStreamOutput: \(error)")
        }
        self.stream = stream
        stream.startCapture { error in
            DispatchQueue.main.async {
                guard self.stream === stream else { // superato da un altro riavvio
                    stream.stopCapture { _ in }
                    return
                }
                if let error { return self.fail("Avvio cattura fallito: \(error)") }
                let isRestart = self.hasStarted
                self.hasStarted = true
                print("Cattura avviata: \(pixelWidth)x\(pixelHeight) @ \(fps) fps + audio")
                // Dopo un riavvio l'iMac potrebbe mostrare un'immagine vecchia: rimandala tutta.
                if isRestart { self.sendFullFrame() }
                self.onCapturing?()
            }
        }
    }

    /// iMac (ri)collegato: ritrasmetti tutto lo schermo.
    func sendFullFrame() {
        queue.async {
            self.tiles.reset()
            self.frameWaiting = true
            self.sendIfPossible()
        }
    }

    /// Da chiamare sulla coda di cattura. Se la rete è ancora occupata aspetta:
    /// il confronto è sempre con l'ultimo frame *inviato*, quindi non si perde niente.
    func sendIfPossible() {
        guard frameWaiting, let frame = lastFrame, video.canSend else { return }
        frameWaiting = false
        if let payload = tiles.encode(frame) {
            video.send(makeMessage(.tiles, payload))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            // I frame "idle" (nessun cambiamento) non hanno immagine.
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lastFrame = pixelBuffer
            frameWaiting = true
            sendIfPossible()
        } else if #available(macOS 13.0, *), type == .audio {
            guard audio.canSend, let payload = makeAudioPayload(sampleBuffer) else { return }
            audio.send(makeMessage(.audio, payload))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            print("Cattura interrotta: \(error)")
            if self.hasStarted {
                self.restart(reason: "cattura interrotta")
            } else {
                self.fail("Cattura interrotta prima di partire.")
            }
        }
    }
}

// MARK: - Sessione

public enum HostState: Equatable {
    case starting
    case searching      // cerco l'iMac via Bonjour
    case connecting     // indirizzo IP indicato a mano
    case connected
    case reconnecting
    case failed(String)
    case stopped
}

/// Monitor virtuale, cattura e connessioni verso l'iMac. Da usare dalla coda principale.
public final class HostSession {
    public var onStateChange: ((HostState) -> Void)?
    public private(set) var state: HostState = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var isRunning: Bool { virtualDisplay != nil }

    private let target: String?
    private var virtualDisplay: CGVirtualDisplay?
    private var videoSender: Sender?
    private var audioSender: Sender?
    private var capturer: Capturer?
    private var browser: NWBrowser?
    private var powerMonitor: PowerMonitor?
    private var sleepAssertion: IOPMAssertionID?
    private var run = 0 // ogni stop invalida le richieste ancora in volo della sessione precedente

    /// `target`: indirizzo IP dell'iMac; nil per trovarlo via Bonjour.
    public init(target: String? = nil) {
        self.target = target
    }

    public func start() {
        guard virtualDisplay == nil else { return }
        run += 1
        let run = self.run
        state = .starting

        guard let display = makeVirtualDisplay() else {
            print("Impossibile creare il monitor virtuale.")
            return fail("Impossibile creare il monitor virtuale.")
        }
        virtualDisplay = display
        print("Monitor virtuale creato (ID \(display.displayID)). Sistemalo in Impostazioni › Monitor.")

        let video = Sender(name: "video", maxPending: 2)
        let audio = Sender(name: "audio", maxPending: 50)
        let capturer = Capturer(video: video, audio: audio)
        videoSender = video
        audioSender = audio
        self.capturer = capturer

        video.onConnected = { [weak self, weak capturer] in
            capturer?.sendFullFrame()
            DispatchQueue.main.async {
                guard let self, self.run == run else { return }
                self.state = .connected
            }
        }
        video.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.run == run else { return }
                self.state = .reconnecting
            }
        }
        video.onDrained = { [weak capturer] in
            guard let capturer else { return }
            capturer.queue.async { capturer.sendIfPossible() }
        }
        capturer.onFatal = { [weak self] message in
            guard let self, self.run == run else { return }
            self.fail(message)
        }

        sleepAssertion = preventIdleSleep()
        let power = PowerMonitor()
        power.onSleep = { print("Il Mac va in stop…") }
        power.onWake = { [weak capturer] in
            print("Il Mac si è risvegliato.")
            capturer?.restart(reason: "risveglio dallo stop")
        }
        power.start()
        powerMonitor = power

        // Diamo a macOS un attimo per registrare il monitor, poi Retina e cattura.
        let displayID = display.displayID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.run == run else { return }
            selectRetinaMode(displayID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.run == run else { return }
                self.capturer?.start(displayID: displayID)
            }
        }

        let connectAll: (@escaping Sender.EndpointProvider) -> Void = { provider in
            video.start(provider)
            audio.start(provider)
        }
        if let target {
            state = .connecting
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(target),
                                               port: NWEndpoint.Port(rawValue: defaultPort)!)
            connectAll { $0(endpoint) }
        } else {
            print("Cerco l'iMac via Bonjour (sul cavo)…")
            state = .searching
            browser = discoverViewer { [weak self] endpoint in
                guard let self, self.run == run else { return }
                self.browser = nil
                guard case let .service(name, type, domain, _) = endpoint else {
                    return connectAll { $0(endpoint) }
                }
                connectAll { done in
                    // Il servizio va risolto sul cavo; se non risponde, prova la risoluzione normale.
                    DispatchQueue.main.async {
                        CableResolver.resolve(name: name, type: type, domain: domain) { done($0 ?? endpoint) }
                    }
                }
            }
        }
    }

    /// Chiude le connessioni e rimuove il monitor virtuale.
    public func stop() {
        tearDown()
        state = .stopped
    }

    private func fail(_ message: String) {
        tearDown()
        state = .failed(message)
    }

    private func tearDown() {
        run += 1
        browser?.cancel()
        browser = nil
        capturer?.stop()
        capturer = nil
        videoSender?.stop()
        videoSender = nil
        audioSender?.stop()
        audioSender = nil
        powerMonitor?.stop()
        powerMonitor = nil
        if let id = sleepAssertion { IOPMAssertionRelease(id) }
        sleepAssertion = nil
        if virtualDisplay != nil { print("Monitor virtuale rimosso.") }
        virtualDisplay = nil
    }
}
