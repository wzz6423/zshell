import Foundation

nonisolated enum PTYMuxObserverFrame {
    enum Kind: UInt8 { case output = 1, reset = 2, resize = 3, ready = 4 }

    static func encode(kind: Kind, data: Data = Data()) -> Data {
        let length = UInt32(data.count + 1)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 255),
                     UInt8((length >> 8) & 255), UInt8(length & 255), kind.rawValue]) + data
    }

    static func next(in buffer: Data) throws -> (kind: Kind, data: Data, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...256 * 1024).contains(length) else {
            throw PTYMuxError.message("Invalid PTY observer frame size.")
        }
        guard buffer.count >= length + 4 else { return nil }
        guard let kind = Kind(rawValue: buffer[buffer.startIndex + 4]) else {
            throw PTYMuxError.message("Invalid PTY observer frame kind.")
        }
        return (kind, Data(buffer.dropFirst(5).prefix(length - 1)), length + 4)
    }
}
