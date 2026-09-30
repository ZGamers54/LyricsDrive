import Foundation

@main
struct BridgeFrameTests {
    static func main() throws {
        var frame = BridgeFrame()
        precondition(tryAppend(&frame, Data("{\"title\":\"é".utf8)) == nil)
        precondition(tryAppend(&frame, Data("té\"}".utf8)) == nil)
        precondition(tryAppend(&frame, Data([10])) == Data("{\"title\":\"été\"}".utf8))
        var empty = BridgeFrame()
        precondition(tryAppend(&empty, Data("{}\n".utf8)) == Data("{}".utf8))
        var small = BridgeFrame(maximumSize: 3)
        do { _ = try small.append(Data("1234".utf8), isComplete: false); fatalError("Size limit ignored") }
        catch BridgeFrame.FrameError.tooLarge { }
        var truncated = BridgeFrame()
        do { _ = try truncated.append(Data("{".utf8), isComplete: true); fatalError("Truncation ignored") }
        catch BridgeFrame.FrameError.truncated { }
        var splitUnicode = BridgeFrame()
        let bytes = Data("été\n".utf8)
        for byte in bytes.dropLast() { precondition(tryAppend(&splitUnicode, Data([byte])) == nil) }
        precondition(tryAppend(&splitUnicode, Data([10])) == Data("été".utf8))
        print("PASS: fragmented JSON, split UTF-8, empty state, size limit, truncated stream")
    }

    static func tryAppend(_ frame: inout BridgeFrame, _ data: Data) -> Data? {
        try! frame.append(data, isComplete: false)
    }
}
