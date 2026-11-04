import Foundation

/// The agent-facing door into SOURCR: routes `/state` and friends to `AgentReportBuilder`.
@MainActor
final class AgentEndpoint {
    static let port: UInt16 = 47615
    static let baseURL = "http://127.0.0.1:\(port)"

    private let appState: AppState
    private let builder: AgentReportBuilder
    private var server: AgentEndpointServer?

    init(appState: AppState) {
        self.appState = appState
        builder = AgentReportBuilder(appState: appState)
    }

    func start() {
        let server = AgentEndpointServer(
            port: Self.port,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.statusChanged(status) }
            },
            handler: { [weak self] request in
                guard let self else { return .text("SOURCR is shutting down.\n", status: 503) }
                return await self.handle(request)
            }
        )
        self.server = server
        server.start()
    }

    private func statusChanged(_ status: AgentEndpointServer.Status) {
        switch status {
        case .listening(let port):
            appState.agentEndpointError = nil
            AppDiagnostics.info(.lifecycle, "agent endpoint listening url=http://127.0.0.1:\(port)/state bind=loopback")
        case .failed(let message):
            // The server retries every few seconds; log only when the reason changes.
            guard appState.agentEndpointError != message else { return }
            appState.agentEndpointError = message
            AppDiagnostics.error(.lifecycle, "agent endpoint unavailable port=\(Self.port) error=\(message) retrying=true")
        }
    }

    private func handle(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        let started = Date()
        let response = await route(request)
        // Paths and option values only: never file names, diffs or tokens.
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AppDiagnostics.info(.appState, "agent endpoint request method=\(request.method) path=\(request.path) options=\(request.query.keys.sorted().joined(separator: ",")) status=\(response.status) bytes=\(response.body.count) ms=\(elapsed)")
        return response
    }

    private func route(_ request: AgentHTTPRequest) async -> AgentHTTPResponse {
        switch request.path {
        case "/", "/help":
            return .text(Self.helpText)
        case "/health":
            return .text("ok version=\(AppDiagnostics.appVersion) build=\(AppDiagnostics.buildVersion)\n")
        case "/state":
            return await state(request, format: nil)
        case "/state.txt":
            return await state(request, format: .text)
        case "/state.md":
            return await state(request, format: .markdown)
        case "/state.json":
            return await state(request, format: .json)
        default:
            return .text("Unknown path \(request.path).\n\n\(Self.helpText)", status: 404)
        }
    }

    private func state(_ request: AgentHTTPRequest, format: AgentReportFormat?) async -> AgentHTTPResponse {
        switch AgentReportOptions.parse(query: request.query, formatFromPath: format) {
        case .failure(let error):
            return .text("\(error.message).\n\n\(Self.helpText)", status: 400)
        case .success(let options):
            let report = await builder.build(options)
            // Off the main actor: a large report must not stall the panel while it renders.
            let body = await Task.detached(priority: .utility) {
                AgentReportRenderer.render(report, as: options.format)
            }.value
            return .text(body, contentType: options.format.contentType)
        }
    }

    static let helpText = """
    SOURCR agent endpoint: everything the SOURCR menu-bar app shows, as text.
    Read-only, this Mac only. SOURCR must be running.

    GET /state        Plain text report (same as /state.txt)
    GET /state.md     Markdown report
    GET /state.json   JSON report, with every field
    GET /health       Liveness and version
    GET /help         This text

    /state contains a summary, then for each watched local repository the branch, changed
    and untracked files with diffs and contents, then for each watched GitHub repository
    all branches with divergence, PRs, workflow runs and job steps for running and failed runs.

    Options, all optional:
      view=all|diff|branches      Only part of the report. Default all.
      repo=TEXT                   Only repositories whose name, path or owner/repo contains TEXT.
      diffs=0                     File lists without diffs or contents.
      refresh=live|cached|force   live (default): GitHub data at most 10s old, branch metadata
                                  at most 45s. cached: never contact GitHub. force: fetch all now.
      full=1                      Lift the size limits (200 KB per file, 2 MB and 300 files per
                                  repository, 25 run details, 30s of git per repository) and add
                                  jobs for every run.
      format=text|md|json         Alternative to the path suffix.

    Local git state is always read live. Truncated or omitted source says so in a Note line.
    A request that takes over 3 minutes gets HTTP 504; 503 means four are already running.
    Text blocks end only at a line carrying the report's id, stated at the top of the report.

    Examples:
      curl -s \(baseURL)/state
      curl -s '\(baseURL)/state.md?repo=SOURCR&view=diff'
      curl -s '\(baseURL)/state.json?view=branches&refresh=cached'
    From devbox:
      ssh mac curl -s \(baseURL)/state

    """
}
