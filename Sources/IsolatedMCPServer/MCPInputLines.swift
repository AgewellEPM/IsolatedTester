import Foundation

/// Keep blocking pipe reads off Foundation's async-byte machinery and the
/// cooperative executor used by native capture callbacks.
enum MCPInputLines {
    static func read(_ input: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let reader = Thread {
                var buffer = Data()
                while true {
                    let data = input.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        continuation.yield(String(decoding: buffer.prefix(upTo: newline), as: UTF8.self))
                        buffer.removeSubrange(...newline)
                    }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                continuation.finish()
            }
            reader.name = "isolated-mcp.stdin"
            reader.start()
        }
    }
}
