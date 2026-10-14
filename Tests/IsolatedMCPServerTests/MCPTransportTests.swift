import Foundation
import XCTest
import IsolatedServerCore
@testable import IsolatedMCPServer

final class MCPTransportTests: XCTestCase {
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String: Any]] = []
        func append(_ reply: [String: Any]) { lock.lock(); values.append(reply); lock.unlock() }
        var snapshot: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        func suspend(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
        func release() {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume()
        }
    }

    func testListAndPingRespondDuringStalledCaptureWhileActionsStayOrdered() async throws {
        let input = Pipe(), output = Pipe()
        let manager = SessionManager()
        let handlers = MCPToolHandlers(sessionManager: manager)
        let gate = Gate(), replies = Replies()
        let started = expectation(description: "capture blocked")
        let listed = expectation(description: "session inventory bypasses capture")
        let pinged = expectation(description: "ping bypasses capture")
        let resource = expectation(description: "session resource bypasses capture")
        let drained = expectation(description: "stdout reader exits")
        let action = expectation(description: "queued action runs after capture")
        let transport = MCPTransport(sessionManager: manager, input: input.fileHandleForReading,
                                     output: output.fileHandleForWriting) { name, args in
            if name == "screenshot" {
                await withCheckedContinuation {
                    gate.suspend($0)
                    started.fulfill()
                }
                // Exercise responses larger than a pipe's atomic-write limit.
                return (String(repeating: "x", count: 256 * 1024), false)
            }
            if name == "stop_session" { action.fulfill() }
            return await handlers.callTool(name: name, arguments: args)
        }

        // Dedicated blocking reader: never consumes a Swift cooperative worker.
        let reader = Thread {
            defer { drained.fulfill() }
            var buffer = Data()
            // read(upToCount:) may wait to fill the requested size on macOS.
            // Short JSON replies must be observed before the blocked capture
            // is released, so use the pipe's currently available bytes.
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        XCTFail("interleaved or malformed response"); continue
                    }
                    replies.append(reply)
                    switch reply["id"] as? Int {
                    case 2: listed.fulfill()
                    case 3: pinged.fulfill()
                    case 4: resource.fulfill()
                    default: break
                    }
                }
            }
            XCTAssertTrue(buffer.isEmpty)
        }
        reader.start()
        let server = Task { await transport.run() }
        func send(_ request: [String: Any]) throws {
            var body = try JSONSerialization.data(withJSONObject: request)
            body.append(10)
            try input.fileHandleForWriting.write(contentsOf: body)
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "screenshot", "arguments": [:]]])
        await fulfillment(of: [started], timeout: 2)
        try send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "stop_session", "arguments": ["sessionId": "missing"]]])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "list_sessions", "arguments": [:]]])
        try send(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        try send(["jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": "isolated://sessions"]])
        await fulfillment(of: [listed, pinged, resource], timeout: 2)
        XCTAssertEqual(Set(replies.snapshot.compactMap { $0["id"] as? Int }), [2, 3, 4])
        gate.release()
        // Race further status replies against the large worker response.
        for id in 10..<30 { try send(["jsonrpc": "2.0", "id": id, "method": "ping"]) }
        try input.fileHandleForWriting.close()
        await server.value
        try output.fileHandleForWriting.close()
        await fulfillment(of: [action, drained], timeout: 2)
        let responses = replies.snapshot
        XCTAssertEqual(responses.count, 25)
        let inventory = try XCTUnwrap(responses.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])
        XCTAssertEqual((inventory["content"] as? [[String: String]])?.first?["text"], "[]")
        XCTAssertNil(inventory["isError"])
        let orderedIDs = responses.compactMap { $0["id"] as? Int }.filter { $0 == 1 || $0 == 5 }
        XCTAssertEqual(orderedIDs, [1, 5])
        try input.fileHandleForReading.close()
        try output.fileHandleForReading.close()
    }
}
