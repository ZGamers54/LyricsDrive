import Foundation

// TCP is a byte stream: decode only after the newline terminator, never after an arbitrary packet.
struct BridgeFrame {
    private var buffer = Data()
    let maximumSize: Int

    init(maximumSize: Int = 1_500_000) { self.maximumSize = maximumSize }

    enum FrameError: Error { case tooLarge, truncated }

    mutating func append(_ data: Data?, isComplete: Bool) throws -> Data? {
        if let data { buffer.append(data) }
        guard buffer.count <= maximumSize else { throw FrameError.tooLarge }
        if let newline = buffer.firstIndex(of: 10) { return Data(buffer[..<newline]) }
        if isComplete { throw FrameError.truncated }
        return nil
    }
}
