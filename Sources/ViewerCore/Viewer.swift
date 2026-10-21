// Viewer — gira sull'iMac (Intel, macOS Monterey 12.3+).
// Riceve i tile cambiati (LZ4 senza perdita), li incolla in una texture Metal 5120×2880
// e la copia a schermo pixel per pixel. Riproduce anche l'audio del Mac principale.
// Usato sia da RelayViewer (Terminale) sia dall'app Lazarus5K.

import AppKit
import AVFoundation
import Compression
import Metal
import QuartzCore
import Network
import Shared

// MARK: - Video (Metal)

final class VideoView: NSView {
    let metalLayer = CAMetalLayer()
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var redrawScheduled = false

    init(frame: NSRect, device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = false   // ci serve per la copia blit
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("non usato") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Texture della dimensione del frame remoto (ricreata se cambia).
    func texture(width: Int, height: Int) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = texture, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .managed
        texture = device.makeTexture(descriptor: desc)
        DispatchQueue.main.async { self.metalLayer.drawableSize = CGSize(width: width, height: height) }
        print("Frame remoto: \(width)x\(height)")
        return texture
    }

    /// Chiamabile da qualsiasi thread: accorpa le richieste in un solo disegno.
    func setNeedsRedraw() {
        lock.lock()
        let schedule = !redrawScheduled
        redrawScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.draw() } }
    }

    private func draw() {
        lock.lock()
        redrawScheduled = false
        let source = texture
        lock.unlock()

        guard let source, let drawable = metalLayer.nextDrawable(),
              let commands = commandQueue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        let target = drawable.texture
        let w = min(source.width, target.width)
        let h = min(source.height, target.height)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

final class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Audio

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var queuedFrames = 0
    private var playing = false
    private var attached = false

    private let prebufferSeconds = 0.04  // 40 ms prima di partire
    private let maxQueueSeconds = 0.15   // oltre i 150 ms in coda scartiamo, per non accumulare ritardo

    func play(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let rate = reader.read(UInt32.self), let channels = reader.read(UInt16.self),
              let frames = reader.read(UInt32.self), let start = reader.skip(Int(frames) * Int(channels) * 4),
              channels > 0, frames > 0 else { return }

        let sampleRate = Double(rate)
        let frameCount = Int(frames)
        let inChannels = Int(channels)

        lock.lock()
        if format?.sampleRate != sampleRate { setUp(sampleRate: sampleRate) }
        guard let format else { lock.unlock(); return }
        if Double(queuedFrames) > maxQueueSeconds * sampleRate { lock.unlock(); return }
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        payload.withUnsafeBytes { raw in
            let src = (raw.baseAddress! + start).assumingMemoryBound(to: Float.self)
            for ch in 0..<Int(format.channelCount) {
                let from = min(ch, inChannels - 1)
                for f in 0..<frameCount { out[ch][f] = src[f * inChannels + from] }
            }
        }

        lock.lock()
        queuedFrames += frameCount
        let shouldStart = !playing && Double(queuedFrames) >= prebufferSeconds * sampleRate
        if shouldStart { playing = true }
        lock.unlock()

        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames -= frameCount; self.lock.unlock()
        }
        if shouldStart { player.play() }
    }

    /// Da chiamare con il lock preso.
    private func setUp(sampleRate: Double) {
        player.stop()
        engine.stop()
        if attached { engine.disconnectNodeOutput(player) } else { engine.attach(player); attached = true }
        guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        do {
            try engine.start()
            format = newFormat
            queuedFrames = 0
            playing = false
            print("Audio: \(Int(sampleRate)) Hz stereo")
        } catch {
            print("Impossibile avviare l'audio: \(error)")
        }
    }
}

// MARK: - Ricezione

final class Receiver {
    private let videoView: VideoView
    private let audio = AudioPlayer()
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var active = false
    /// L'Host ha iniziato a inviare lo schermo. Chiamato su una coda qualsiasi.
    var onActive: (() -> Void)?
    /// Tutte le connessioni dell'Host sono chiuse. Chiamato su una coda qualsiasi.
    var onIdle: (() -> Void)?

    init(videoView: VideoView) {
        self.videoView = videoView
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Se il Mac principale va in stop senza chiudere le connessioni, qui ce ne
        // accorgiamo in una decina di secondi invece di aspettare per sempre.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.prohibitedInterfaceTypes = [.wifi] // solo cavo

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: defaultPort)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "iMac", type: serviceType)
        listener.stateUpdateHandler = { state in print("In ascolto: \(state)") }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: DispatchQueue(label: "relay.listener"))
        self.listener = listener
    }

    // L'Host apre due connessioni (video e audio): ognuna ha la sua coda,
    // così un frame pesante non fa gracchiare l'audio.
    private func accept(_ conn: NWConnection) {
        lock.lock(); connections[ObjectIdentifier(conn)] = conn; lock.unlock()
        conn.stateUpdateHandler = { state in print("Connessione \(conn.endpoint): \(state)") }
        conn.start(queue: DispatchQueue(label: "relay.conn"))
        readHeader(conn)
    }

    private func readHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 5 else { return self.closed(conn) }
            var reader = ByteReader(data)
            let type = reader.read(UInt8.self)!
            let length = Int(reader.read(UInt32.self)!)
            self.readBody(conn, type: type, length: length)
        }
    }

    private func readBody(_ conn: NWConnection, type: UInt8, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else { return self.closed(conn) }
            switch MessageType(rawValue: type) {
            case .tiles: self.applyTiles(data)
            case .audio: self.audio.play(data)
            case nil: print("Messaggio sconosciuto (tipo \(type))")
            }
            self.readHeader(conn)
        }
    }

    private func closed(_ conn: NWConnection) {
        print("Connessione chiusa (\(conn.endpoint)), resto in attesa…")
        conn.cancel()
        lock.lock()
        connections[ObjectIdentifier(conn)] = nil
        let becameIdle = connections.isEmpty && active
        if becameIdle { active = false }
        lock.unlock()
        if becameIdle { onIdle?() }
    }

    private struct Tile {
        let x, y, w, h: Int
        let encoding: TileEncoding
        let offset: Int
        let length: Int
    }

    private func applyTiles(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let fw = reader.read(UInt16.self), let fh = reader.read(UInt16.self),
              let count = reader.read(UInt32.self) else { return }

        var tiles: [Tile] = []
        tiles.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let x = reader.read(UInt16.self), let y = reader.read(UInt16.self),
                  let w = reader.read(UInt16.self), let h = reader.read(UInt16.self),
                  let enc = reader.read(UInt8.self).flatMap(TileEncoding.init(rawValue:)),
                  let len = reader.read(UInt32.self), let offset = reader.skip(Int(len)) else {
                print("Pacchetto tile malformato"); return
            }
            tiles.append(Tile(x: Int(x), y: Int(y), w: Int(w), h: Int(h),
                              encoding: enc, offset: offset, length: Int(len)))
        }
        guard let texture = videoView.texture(width: Int(fw), height: Int(fh)) else { return }

        lock.lock()
        let becameActive = !active
        active = true
        lock.unlock()
        if becameActive { onActive?() }

        // Decompressione in parallelo su tutti i core…
        let decoded = UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>.allocate(capacity: tiles.count)
        decoded.initialize(repeating: nil, count: tiles.count)
        defer {
            for i in 0..<tiles.count { decoded[i]?.deallocate() }
            decoded.deallocate()
        }
        payload.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
                let t = tiles[i]
                let size = t.w * t.h * 4
                let out = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                switch t.encoding {
                case .lz4:
                    let n = compression_decode_buffer(out, size, base + t.offset, t.length, nil, COMPRESSION_LZ4)
                    guard n == size else { out.deallocate(); return }
                case .raw:
                    guard t.length == size else { out.deallocate(); return }
                    memcpy(out, base + t.offset, size)
                }
                decoded[i] = out
            }
        }

        // …poi copia nella texture, un tile alla volta.
        for (i, t) in tiles.enumerated() {
            guard let bytes = decoded[i] else { continue }
            texture.replace(region: MTLRegionMake2D(t.x, t.y, t.w, t.h), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: t.w * 4)
        }
        videoView.setNeedsRedraw()
    }
}

// MARK: - Finestra a schermo intero

public enum ViewerState: Equatable {
    case waiting    // nessun Mac collegato
    case showing    // schermo del Mac principale visibile
    case dismissed  // collegato, ma nascosto con Esc
}

public struct ViewerError: Error, CustomStringConvertible {
    public let description: String
}

/// Da usare dalla coda principale, con NSApplication già creata.
public final class ViewerController {
    public enum Mode {
        /// Subito a schermo intero; Esc chiude il programma.
        case standalone
        /// Nascosto finché il Mac principale non invia lo schermo; Esc lo nasconde
        /// fino alla prossima connessione.
        case background
    }

    public var onStateChange: ((ViewerState) -> Void)?
    public private(set) var state: ViewerState = .waiting {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let mode: Mode
    private var window: BorderlessWindow?
    private var videoView: VideoView?
    private var receiver: Receiver?
    private var keyMonitor: Any?
    private var visible = false

    public init(mode: Mode) {
        self.mode = mode
    }

    public func start() throws {
        guard receiver == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ViewerError(description: "Metal non disponibile.")
        }
        guard let screen = NSScreen.screens.first else {
            throw ViewerError(description: "Nessuno schermo?")
        }
        if screen.backingScaleFactor < 2 {
            print("Attenzione: l'iMac non è in una modalità Retina. Per il 5K pixel per pixel usa \"Predefinito per il monitor\" (2560x1440) in Preferenze di Sistema › Monitor.")
        }

        let window = BorderlessWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
        let videoView = VideoView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        window.contentView = videoView
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Sopra la barra dei menu e il Dock dell'iMac: le opzioni di presentazione che li
        // nascondono valgono solo se l'app riesce a passare in primo piano, e un'app lanciata
        // in background all'accesso non sempre ci riesce.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        videoView.metalLayer.contentsScale = screen.backingScaleFactor
        self.window = window
        self.videoView = videoView

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event } // Esc
            switch self.mode {
            case .standalone:
                NSApp.terminate(nil)
            case .background:
                self.dismiss()
            }
            return nil
        }

        let receiver = Receiver(videoView: videoView)
        receiver.onActive = { [weak self] in
            DispatchQueue.main.async { self?.hostDidStartSending() }
        }
        receiver.onIdle = { [weak self] in
            DispatchQueue.main.async { self?.hostDidLeave() }
        }
        do {
            try receiver.start()
        } catch {
            throw ViewerError(description: "Impossibile mettersi in ascolto: \(error)")
        }
        self.receiver = receiver

        if mode == .standalone { show() }
    }

    /// Nasconde lo schermo del Mac finché resta collegato (Esc).
    func dismiss() {
        guard state == .showing else { return }
        hide()
        state = .dismissed
    }

    /// Rimostra lo schermo nascosto con Esc, se il Mac principale è ancora collegato.
    public func reveal() {
        guard state == .dismissed else { return }
        show()
        state = .showing
    }

    private func hostDidStartSending() {
        guard state != .dismissed else { return }
        show()
        state = .showing
    }

    private func hostDidLeave() {
        if mode == .background { hide() }
        state = .waiting
    }

    private func show() {
        guard !visible, let window else { return }
        visible = true
        if let screen = NSScreen.screens.first {
            window.setFrame(screen.frame, display: true)
            videoView?.metalLayer.contentsScale = screen.backingScaleFactor
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless() // anche se l'app non è riuscita a passare in primo piano
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
    }

    private func hide() {
        guard visible, let window else { return }
        visible = false
        window.orderOut(nil)
        NSApp.presentationOptions = []
        NSCursor.unhide()
    }
}
