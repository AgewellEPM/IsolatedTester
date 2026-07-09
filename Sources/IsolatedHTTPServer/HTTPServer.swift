import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import IsolatedServerCore

@main
struct IsolatedHTTPServer {
    static func main() async throws {
        let port = Int(ProcessInfo.processInfo.environment["IST_PORT"] ?? "7100") ?? 7100
        // Bug 1 fix: read the IST_TOKEN env var so the handler can enforce auth
        let token = ProcessInfo.processInfo.environment["IST_TOKEN"]
        let corsEnv = ProcessInfo.processInfo.environment["IST_CORS_ORIGINS"]
        let allowedOrigins = corsEnv?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ?? ["http://localhost:*", "http://127.0.0.1:*"]

        let rateBurst = Double(ProcessInfo.processInfo.environment["IST_RATE_BURST"] ?? "100") ?? 100
        let rateLimit = Double(ProcessInfo.processInfo.environment["IST_RATE_LIMIT"] ?? "10") ?? 10
        let rateLimiter = RateLimiter(maxTokens: rateBurst, refillRate: rateLimit)

        let manager = SessionManager()
        await manager.startCleanupLoop()

        // Advertise for editor discovery
        try? DiscoveryService.advertise(info: .init(httpPort: port))

        let router = Router(sessionManager: manager)

        // Handle graceful shutdown.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            // Begin graceful shutdown: reject new requests
            router.beginShutdown()
            let shutdownSemaphore = DispatchSemaphore(value: 0)
            Task {
                await manager.stopAll()
                DiscoveryService.remove()
                shutdownSemaphore.signal()
            }
            _ = shutdownSemaphore.wait(timeout: .now() + 5)
            exit(0)
        }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            try? group.syncShutdownGracefully()
            DiscoveryService.remove()
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    // Bug 1 fix: pass the token down to each handler instance
                    channel.pipeline.addHandler(HTTPHandler(router: router, token: token, allowedOrigins: allowedOrigins, rateLimiter: rateLimiter))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        FileHandle.standardError.write(Data("IsolatedTester HTTP server running on http://127.0.0.1:\(port)\n".utf8))

        try await channel.closeFuture.get()
    }
}

/// NIO channel handler that routes HTTP requests.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    // Bug 1 fix: store the token so every request can be checked
    private let token: String?
    private let allowedOrigins: [String]
    private let rateLimiter: RateLimiter

    // Bug 2 fix: 10 MB body size limit constant
    private static let maxBodySize = 10 * 1024 * 1024  // 10 MB

    // Bug 3 fix: capture head+body together in a struct so that a second
    // pipelined request arriving before the Task fires cannot overwrite them.
    private struct PendingRequest {
        var head: HTTPRequestHead
        var body: Data
    }
    private var pending: PendingRequest?

    init(router: Router, token: String?, allowedOrigins: [String], rateLimiter: RateLimiter) {
        self.router = router
        self.token = token
        self.allowedOrigins = allowedOrigins
        self.rateLimiter = rateLimiter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            // Bug 3 fix: start a fresh PendingRequest for each new request head,
            // instead of using two separate instance vars that can be interleaved.
            pending = PendingRequest(head: head, body: Data())

        case .body(var buf):
            guard pending != nil else { return }

            // Bug 2 fix: enforce the 10 MB body limit before accumulating bytes
            let incomingBytes = buf.readableBytes
            let currentSize = pending!.body.count
            if currentSize + incomingBytes > HTTPHandler.maxBodySize {
                // Respond with 413 and close the connection
                sendSimpleResponse(
                    context: context,
                    version: pending!.head.version,
                    status: .payloadTooLarge,
                    body: "{\"error\":\"Payload Too Large\"}"
                )
                pending = nil
                context.close(promise: nil)
                return
            }
            if let bytes = buf.readBytes(length: incomingBytes) {
                pending!.body.append(contentsOf: bytes)
            }

        case .end:
            // Bug 3 fix: capture the current pending request into a local
            // immutable copy before launching the Task.  If a new pipelined
            // request arrives and resets `pending` while the Task is running,
            // it will operate on its own distinct snapshot rather than the
            // shared instance variable.
            guard let snapshot = pending else { return }
            pending = nil
            let ctx = context
            let capturedToken = token

            let capturedRateLimiter = rateLimiter
            Task {
                // Generate or preserve request ID for tracing
                let requestId = snapshot.head.headers.first(name: "X-Request-ID") ?? UUID().uuidString
                let requestOrigin = snapshot.head.headers.first(name: "Origin")

                // Rate limiting (skip for health checks and OPTIONS)
                let method = snapshot.head.method
                let uri = snapshot.head.uri
                let path = uri.components(separatedBy: "?").first ?? uri
                let parts = path.split(separator: "/").map(String.init)
                let isHealthCheck = method == .GET && (parts.isEmpty || parts == ["health"])
                let isMetrics = method == .GET && parts == ["metrics"]
                let isOptions = method == .OPTIONS

                if !isOptions && !isHealthCheck && !isMetrics {
                    let clientIP = ctx.remoteAddress?.description ?? "unknown"
                    if !capturedRateLimiter.allow(clientIP: clientIP) {
                        let retryAfter = capturedRateLimiter.retryAfter(clientIP: clientIP)
                        let tooMany = Router.HTTPResponse.error(.tooManyRequests, "Rate limit exceeded. Retry after \(retryAfter) seconds.")
                        ctx.eventLoop.execute {
                            var headers = HTTPHeaders()
                            headers.add(name: "Retry-After", value: "\(retryAfter)")
                            self.sendResponse(context: ctx, version: snapshot.head.version, response: tooMany, requestOrigin: requestOrigin, requestId: requestId)
                        }
                        return
                    }
                }

                // Bug 1 fix: enforce token auth for every non-OPTIONS, non-health
                // request when IST_TOKEN is configured.
                if let required = capturedToken, !required.isEmpty, !isOptions, !isHealthCheck {
                    let authHeader = snapshot.head.headers.first(name: "Authorization") ?? ""
                    let expectedBearer = "Bearer \(required)"
                    if authHeader != expectedBearer {
                        let unauthorized = Router.HTTPResponse.error(.unauthorized, "Invalid or missing token")
                        ctx.eventLoop.execute {
                            self.sendResponse(context: ctx, version: snapshot.head.version, response: unauthorized, requestOrigin: requestOrigin, requestId: requestId)
                        }
                        return
                    }
                }

                let response = await router.handle(
                    method: method,
                    uri: uri,
                    body: snapshot.body,
                    headers: snapshot.head.headers
                )

                // Send response on the event loop
                ctx.eventLoop.execute {
                    self.sendResponse(context: ctx, version: snapshot.head.version, response: response, requestOrigin: requestOrigin, requestId: requestId)
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Write a fully-formed HTTPResponse onto the channel.
    private func sendResponse(context: ChannelHandlerContext, version: HTTPVersion, response: Router.HTTPResponse, requestOrigin: String? = nil, requestId: String? = nil) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: "\(response.body.count)")

        // CORS: match against allowed origins instead of returning *
        if let origin = requestOrigin, matchesCORSOrigin(origin) {
            headers.add(name: "Access-Control-Allow-Origin", value: origin)
            headers.add(name: "Vary", value: "Origin")
        }
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, DELETE, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")

        // Security headers
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "X-Frame-Options", value: "DENY")
        headers.add(name: "Content-Security-Policy", value: "default-src 'none'")

        // Request ID for tracing
        if let rid = requestId {
            headers.add(name: "X-Request-ID", value: rid)
        }

        let responseHead = HTTPResponseHead(version: version, status: response.status, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Write a minimal error response synchronously (used before we have a Router.HTTPResponse).
    private func sendSimpleResponse(
        context: ChannelHandlerContext,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        body: String
    ) {
        let bodyBytes = Array(body.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(bodyBytes.count)")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: bodyBytes.count)
        buffer.writeBytes(bodyBytes)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// Check if an origin matches the allowed origins list.
    /// Supports wildcard port matching: `http://localhost:*` matches `http://localhost:3000`.
    private func matchesCORSOrigin(_ origin: String) -> Bool {
        for allowed in allowedOrigins {
            if allowed == "*" || allowed == origin { return true }
            if allowed.hasSuffix(":*") {
                let prefix = String(allowed.dropLast(1)) // "http://localhost:"
                if origin.hasPrefix(prefix) { return true }
                // Also match without port (e.g., "http://localhost" matches "http://localhost:*")
                let basePrefix = String(allowed.dropLast(2)) // "http://localhost"
                if origin == basePrefix { return true }
            }
        }
        return false
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
