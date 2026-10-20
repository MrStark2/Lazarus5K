import Foundation

// Protocollo RelayLite v2 tra Host e Viewer.
// Ogni messaggio: [1 byte tipo][4 byte lunghezza big-endian][payload]
//
// .tiles  → [UInt16 larghezza frame][UInt16 altezza frame][UInt32 numero tile]
//           poi per ogni tile: [UInt16 x][UInt16 y][UInt16 w][UInt16 h][UInt8 codifica][UInt32 byte][dati]
//           codifica 0 = BGRA grezzo, 1 = LZ4 (framework Compression di Apple)
// .audio  → [UInt32 sample rate][UInt16 canali][UInt32 frame][Float32 interleaved]

public let serviceType = "_relaylite._tcp"
public let defaultPort: UInt16 = 50505
public let tileSize = 128

public enum MessageType: UInt8 {
    case tiles = 3
    case audio = 4
}

public enum TileEncoding: UInt8 {
    case raw = 0
    case lz4 = 1
}

public func makeMessage(_ type: MessageType, _ payload: Data) -> Data {
    var out = Data(capacity: payload.count + 5)
    out.append(type.rawValue)
    out.appendBE(UInt32(payload.count))
    out.append(payload)
    return out
}

public extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

/// Lettore sequenziale di interi big-endian da un Data.
public struct ByteReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        for i in 0..<size { value = (value << 8) | T(data[offset + i]) }
        offset += size
        return value
    }

    /// Salta `count` byte e restituisce l'offset (relativo all'inizio del Data) dove iniziavano.
    public mutating func skip(_ count: Int) -> Int? {
        guard remaining >= count else { return nil }
        let start = offset - data.startIndex
        offset += count
        return start
    }
}
