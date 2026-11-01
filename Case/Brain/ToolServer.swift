import Foundation
import Network

/// A tiny MCP server (JSON-RPC over HTTP, on 127.0.0.1 only) that gives Claude Code Case's tools.
/// Claude Code connects to it with the `--mcp-config` the session passes, using a secret token,
/// and calls tools like `click` or `write`; this server hands each call to `call` and returns the result.
final class ToolServer {
    struct Tool {
        let name: String
        let description: String
        /// JSON Schema for the arguments.
        let schema: [String: Any]
    }

    nonisolated struct Result: Sendable {
        var text: String
        var imageJPEG: Data?
        var isError = false
    }

    var tools: [Tool] = []
    var call: (_ name: String, _ arguments: [String: Any]) async -> Result = { _, _ in Result(text: "No tools yet.", isError: true) }

    private(set) var port: UInt16?
    private let token = UUID().uuidString
    private var listener: NWListener?
    private var waitingForReady: [CheckedContinuation<Void, Never>] = []

    /// What `claude --mcp-config` needs to reach this server.
    var mcpConfig: String? {
        guard let port else { return nil }
        let server: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]
        let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["case": server]])
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private var failed = false

    private func releaseWaiters() {
        waitingForReady.forEach { $0.resume() }
        waitingForReady = []
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue
                    self?.releaseWaiters()
                case .failed, .cancelled:
                    // Without a server, sessions still start, just without tools.
                    self?.failed = true
                    self?.releaseWaiters()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Waits until the server has a port, so no Claude session starts without tools.
    func ready() async {
        if port != nil || failed || listener == nil { return }
        await withCheckedContinuation { waitingForReady.append($0) }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    /// Bodies can arrive in pieces, so keep reading until the whole request is here.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Request(buffer) {
                    self.handle(request, on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        // Only Claude Code, with the token. Browsers send an Origin header, so web pages are refused.
        guard request.path == "/mcp" else { return send(404, to: connection) }
        guard request.headers["authorization"] == "Bearer \(token)" else { return send(401, to: connection) }
        guard request.headers["origin"] == nil else { return send(403, to: connection) }

        switch request.method {
        case "POST":
            break
        case "DELETE":
            return send(200, to: connection)
        default:
            // Claude Code may ask for an event stream with GET; this server only answers requests.
            return send(405, to: connection)
        }

        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = message["method"] as? String
        else { return send(400, to: connection) }

        // Notifications have no id and get no answer.
        guard let id = message["id"] else { return send(202, to: connection) }
        let params = message["params"] as? [String: Any] ?? [:]

        let work = Task {
            let result = await answer(method, params: params)
            guard !Task.isCancelled else { return }
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch result {
            case .success(let value): reply["result"] = value
            case .failure(let error): reply["error"] = ["code": error.code, "message": error.message]
            }
            send(200, json: reply, to: connection)
        }
        // If Claude Code gives up on a call (say, while a confirm card is up), cancel it,
        // so the action can never happen later. A hang-up only shows while a read is pending.
        connection.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed: work.cancel()
            default: break
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { work.cancel() }
        }
    }

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private func answer(_ method: String, params: [String: Any]) async -> Swift.Result<Any, RPCError> {
        switch method {
        case "initialize":
            return .success([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "case", "version": "0.1"],
            ])
        case "ping":
            return .success([String: Any]())
        case "tools/list":
            return .success(["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
        case "tools/call":
            guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
                return .failure(RPCError(code: -32602, message: "Unknown tool"))
            }
            let result = await call(name, params["arguments"] as? [String: Any] ?? [:])
            var content: [[String: Any]] = [["type": "text", "text": result.text]]
            if let image = result.imageJPEG {
                content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            return .success(["content": content, "isError": result.isError])
        default:
            return .failure(RPCError(code: -32601, message: "Method not found"))
        }
    }

    private func send(_ status: Int, json: [String: Any]? = nil, to connection: NWConnection) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        if status == 405 { head += "Allow: POST, DELETE\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// One HTTP request, once all of it has arrived.
private nonisolated struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }

        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
