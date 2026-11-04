import Foundation
import Network

struct AgentHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Names are lowercased.
    let headers: [String: String]

    /// Parses the request line and headers; the body is ignored because only GET and HEAD are served.
    static func parse(_ data: Data) -> AgentHTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), parts[1].hasPrefix("/"),
              let components = URLComponents(string: "http://local\(parts[1])") else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "1" }
        return AgentHTTPRequest(method: String(parts[0]), path: components.path, query: query, headers: headers)
    }

    /// Binding to loopback keeps other machines out; this keeps web pages out. Without it a
    /// site could reach the endpoint through the browser or DNS rebinding and read source.
    func rejection(boundPort: UInt16) -> AgentHTTPResponse? {
        guard method == "GET" || method == "HEAD" else {
            return .text("SOURCR is read-only: only GET and HEAD are served.\n", status: 405, extraHeaders: ["Allow": "GET, HEAD"])
        }
        let allowedHosts = ["127.0.0.1", "localhost", "[::1]"].map { "\($0):\(boundPort)" }
        guard let host = headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .text("Host must be 127.0.0.1:\(boundPort).\n", status: 403)
        }
        let crossSite = headers["sec-fetch-site"].map { $0 != "none" && $0 != "same-origin" } ?? false
        guard headers["origin"] == nil, !crossSite else {
            return .text("Browser requests are not served.\n", status: 403)
        }
        return nil
    }
}

struct AgentHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8",
                     extraHeaders: [String: String] = [:]) -> AgentHTTPResponse {
        AgentHTTPResponse(status: status, contentType: contentType, body: Data(text.utf8), extraHeaders: extraHeaders)
    }

    func serialized(omitBody: Bool) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 503: "Service Unavailable", 504: "Gateway Timeout"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + (omitBody ? Data() : body)
    }
}

/// A minimal HTTP/1.1 server on the loopback interface: one request per connection, closed after
/// the reply. Hand-rolled on Network.framework so the app keeps its zero-dependency build.
final class AgentEndpointServer: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case listening(UInt16)
        case failed(String)
    }

    typealias Handler = @Sendable (AgentHTTPRequest) async -> AgentHTTPResponse

    private static let maxRequestBytes = 16 * 1024
    private static let requestReadTimeout: TimeInterval = 10
    private static let retryDelay: TimeInterval = 5
    private static let maxConcurrentRequests = 4
    private let requestDeadline: TimeInterval

    private let queue = DispatchQueue(label: "com.sourcr.agent-endpoint")
    private let requestedPort: UInt16
    private let handler: Handler
    private let onStatus: @Sendable (Status) -> Void
    // Everything below is touched only on `queue`.
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var inFlight = 0
    private var isStopped = true

    /// Pass port 0 to let the system choose one.
    init(port: UInt16, requestDeadline: TimeInterval = 180,
         onStatus: @escaping @Sendable (Status) -> Void = { _ in }, handler: @escaping Handler) {
        requestedPort = port
        self.requestDeadline = requestDeadline
        self.onStatus = onStatus
        self.handler = handler
    }

    func start() {
        queue.async {
            self.isStopped = false
            self.startListener()
        }
    }

    func stop() {
        queue.sync {
            self.isStopped = true
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func startListener() {
        guard !isStopped, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
            )
            // Lets a relaunch rebind at once instead of waiting out TIME_WAIT.
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.boundPort = listener.port?.rawValue ?? self.requestedPort
                    self.onStatus(.listening(self.boundPort))
                case .failed(let error), .waiting(let error):
                    self.listenerFailed(listener, error: error)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onStatus(.failed(error.localizedDescription))
            scheduleRetry()
        }
    }

    /// Usually another process holding the port; keep trying so SOURCR recovers once it is free.
    private func listenerFailed(_ failed: NWListener, error: NWError) {
        guard failed === listener else { return }
        failed.cancel()
        listener = nil
        onStatus(.failed(error.localizedDescription))
        scheduleRetry()
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in self?.startListener() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that connects and goes quiet must not hold the socket open.
        let readTimeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout, execute: readTimeout)
        read(connection, buffer: Data(), readTimeout: readTimeout)
    }

    private func read(_ connection: NWConnection, buffer: Data, readTimeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = AgentHTTPRequest.parse(buffer) {
                readTimeout.cancel()
                self.respond(to: request, on: connection)
            } else if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || buffer.count >= Self.maxRequestBytes || isComplete {
                readTimeout.cancel()
                self.send(.text("Malformed request.\n", status: 400), to: connection, omitBody: false)
            } else if error != nil {
                readTimeout.cancel()
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer, readTimeout: readTimeout)
            }
        }
    }

    private func respond(to request: AgentHTTPRequest, on connection: NWConnection) {
        let omitBody = request.method == "HEAD"
        if let rejection = request.rejection(boundPort: boundPort) {
            send(rejection, to: connection, omitBody: omitBody)
            return
        }
        // /health stays answerable when the slots are full, so a jam can be diagnosed.
        guard inFlight < Self.maxConcurrentRequests || request.path == "/health" else {
            send(.text("Busy: \(Self.maxConcurrentRequests) requests are already running. Retry shortly.\n", status: 503,
                       extraHeaders: ["Retry-After": "1"]), to: connection, omitBody: omitBody)
            return
        }
        inFlight += 1
        let handler = self.handler
        // A panel-hidden accessory app is a prime App Nap candidate; do not let it slow a reply.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "SOURCR agent endpoint request")
        // Whichever comes first answers. The slot stays held until the work really ends,
        // so timed-out requests cannot pile up past the limit; a timeout also cancels it.
        var isAnswered = false
        let answer: @Sendable (AgentHTTPResponse) -> Void = { [self] response in
            guard !isAnswered else { return }
            isAnswered = true
            send(response, to: connection, omitBody: omitBody)
        }
        let work = Task.detached { [self] in
            let response = await handler(request)
            queue.async { [self] in
                ProcessInfo.processInfo.endActivity(activity)
                inFlight -= 1
                answer(response)
            }
        }
        queue.asyncAfter(deadline: .now() + requestDeadline) {
            answer(.text("Timed out building the report.\n", status: 504))
            work.cancel()
        }
    }

    private func send(_ response: AgentHTTPResponse, to connection: NWConnection, omitBody: Bool) {
        connection.send(content: response.serialized(omitBody: omitBody), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
