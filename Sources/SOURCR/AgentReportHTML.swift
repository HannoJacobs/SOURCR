import Foundation

/// The browser view of the same snapshot served by the text and JSON formats.
enum AgentReportHTML {
    static func render(_ report: AgentReport) -> String {
        let app = report.app
        let ui = report.interface
        let summary = report.summary
        var sections: [String] = []
        if let repos = report.githubRepos {
            sections.append("""
            <section><header class="line"><h2>Branches</h2><span class="grow">\(count(repos.count, "repository", plural: "repositories"))</span>
            <span class="pill running">\(summary.runningBranches) running</span><span class="pill failed">\(summary.failedBranches) failed</span></header>
            \(repos.isEmpty ? "<p>No watched GitHub repositories in this scope.</p>" : repos.map(gitHubRepo).joined())
            </section>
            """)
        }
        if let repos = report.diffRepos {
            sections.append("""
            <section><header class="line"><h2>Diff</h2><span class="grow">\(summary.dirtyRepos) dirty · \(summary.changedFiles) changed · \(summary.untrackedFiles) untracked</span></header>
            \(repos.isEmpty ? "<p>No watched local repositories in this scope.</p>" : repos.map(diffRepo).joined())
            </section>
            """)
        }
        if let review = ui.pullRequestReview {
            let files = review.files.map { file in
                let caption = "\(file.filename) · \(file.status) · +\(file.additions) / −\(file.deletions)"
                return fileRow(caption, source: file.patch, note: file.note)
            }.joined()
            sections.append("""
            <section><h2>PR review</h2>\(disclosure(link(review.url, "PR #\(review.number) · \(review.title)"), body:
                (review.loading ? notice("Loading…") : "") + notice(review.error)
                + (review.fileLimitReached ? notice("File limit reached.") : "") + files,
                className: "repo", open: true))</section>
            """)
        }
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer"><title>SOURCR state</title>
        <style>\(style)</style></head>
        <body><main>
        <header class="line page-header"><h1>SOURCR</h1><span>v\(escape(app.version)) · \(escape(report.generatedAt)) · GitHub \(escape(report.githubData))</span></header>
        \(notice(report.scope))
        \(sections.joined(separator: "\n"))
        \(notice(ui.statusMessage))
        <footer>Build \(escape(app.build)) · \(escape(ui.mode.capitalized)) mode · Panel \(ui.panelVisible ? "open" : "closed")</footer>
        </main></body></html>
        """
    }

    private static func gitHubRepo(_ repo: AgentReport.GitHubRepo) -> String {
        let visible = repo.branches.filter { $0.hiddenReason == nil }
        let hidden = repo.branches.filter { $0.hiddenReason != nil }
        let running = visible.filter { $0.checks == "running" }.count
        let failed = visible.filter { $0.checks == "failed" }.count
        var caption = "<strong>\(escape(repo.name))</strong><span class=\"grow\"></span>"
        if running > 0 { caption += "<span class=\"pill running\">\(running) running</span>" }
        if failed > 0 { caption += "<span class=\"pill failed\">\(failed) failed</span>" }
        if running == 0, failed == 0, visible.contains(where: { $0.checks == "passed" }) {
            caption += statusIcon("passed")
        }
        caption += "<span class=\"muted\">\(count(visible.count, "branch", plural: "branches"))</span>"

        var body = notice(repo.error) + visible.map(branch).joined()
        if !hidden.isEmpty {
            body += disclosure("\(count(hidden.count, "hidden branch", plural: "hidden branches"))",
                               body: hidden.map(branch).joined(), className: "hidden")
        }
        return disclosure(caption, body: body, className: "repo", open: !repo.collapsedInPanel)
    }

    private static func branch(_ branch: AgentReport.Branch) -> String {
        var badges = ""
        if branch.isDefault { badges += "<span class=\"pill\">default</span>" }
        if let behind = branch.behind, let ahead = branch.ahead {
            badges += "<span class=\"metric\" aria-label=\"\(behind) behind, \(ahead) ahead\">\(behind) ↓ &nbsp; \(ahead) ↑</span>"
        }
        if let reason = branch.hiddenReason {
            badges += "<span class=\"pill\">\(reason == "merged" ? "merged" : "hidden until updated")</span>"
        }
        if let pr = branch.pullRequest, !pr.badgeHidden {
            badges += "<span class=\"pill\" title=\"\(escape(pr.title))\">\(link(pr.url, "PR #\(pr.number)"))</span>"
        }

        let active = branch.runs.filter { $0.state == "running" || $0.state == "failed" }
        let history = branch.runs.filter { $0.state != "running" && $0.state != "failed" }
        let completed = history.isEmpty ? "" : disclosure(count(history.count, "completed run"),
                                                          body: history.map(run).joined(), className: "history")
        return """
        <div class="branch"><div class="line branch-heading">
        \(statusIcon(branch.checks))<span class="grow branch-name" title="\(escape(branch.name))">\(escape(branch.name))</span>\(badges)</div>
        \(active.map(run).joined())\(completed)</div>
        """
    }

    private static func run(_ run: AgentReport.Run) -> String {
        let attention = run.jobs?.filter {
            ["in_progress", "queued", "waiting", "pending", "requested"].contains($0.status)
                || ["failure", "timed_out", "action_required", "startup_failure"].contains($0.conclusion ?? "")
        } ?? []
        let current = attention.map { job in
            let step = job.steps.first { $0.status == "in_progress" }
                ?? job.steps.first { $0.conclusion == "failure" }
            return "<div class=\"current\">\(escape(step?.name ?? job.name))</div>"
        }.joined()
        let jobs = run.jobs.flatMap { jobs in
            jobs.isEmpty ? nil : disclosure(count(jobs.count, "job"), body: jobs.map(job).joined(), className: "jobs")
        } ?? ""
        return """
        <div class="run"><div class="line">\(statusIcon(run.state))<span class="grow">\(link(run.url, run.workflow))</span>
        \(duration(run.elapsedSeconds))</div>\(current)\(jobs)\(notice(run.detailNote))</div>
        """
    }

    private static func job(_ job: AgentReport.Job) -> String {
        let caption = "\(statusIcon(job.status, conclusion: job.conclusion)) \(link(job.url, job.name)) \(duration(job.elapsedSeconds))"
        let steps = job.steps.map { step in
            "<div class=\"step\">\(statusIcon(step.status, conclusion: step.conclusion)) \(escape(step.name)) \(duration(step.elapsedSeconds))</div>"
        }.joined()
        return disclosure(caption, body: steps, className: "job")
    }

    private static func diffRepo(_ repo: AgentReport.DiffRepo) -> String {
        let files = (repo.changes + repo.untracked).map { file in
            let path = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
            return fileRow("\(path) · \(file.status)", source: file.diff ?? file.content, note: file.note)
        }.joined()
        let branch = repo.branch.map { "<span class=\"metric\">\(escape($0))</span>" } ?? ""
        return disclosure("<strong>\(escape(repo.name))</strong><span class=\"grow\"></span>\(branch)"
                          + "<span class=\"muted\">\(count(repo.changes.count + repo.untracked.count, "file"))</span>",
                          body: notice(repo.error) + files, className: "repo", open: !repo.collapsedInPanel)
    }

    private static func fileRow(_ caption: String, source: String?, note: String?) -> String {
        let label = "<code>\(escape(caption))</code>"
        if let source {
            return disclosure(label, body: "<pre><code>\(escape(source))</code></pre>" + notice(note), className: "file")
        }
        return "<div class=\"file\">\(label)\(notice(note))</div>"
    }

    private static func disclosure(_ caption: String, body: String, className: String, open: Bool = false) -> String {
        "<details class=\"\(className)\"\(open ? " open" : "")><summary>\(caption)</summary>\(body)</details>"
    }

    private static func notice(_ message: String?) -> String {
        message.map { "<p class=\"notice\">\(escape($0))</p>" } ?? ""
    }

    private static func count(_ number: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }

    private static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        return "<span class=\"metric\">\(seconds / 60)m \(String(format: "%02d", seconds % 60))s</span>"
    }

    private static func statusIcon(_ status: String, conclusion: String? = nil) -> String {
        let status = conclusion.flatMap { $0.isEmpty ? nil : $0 } ?? status
        let (symbol, tone): (String, String) = switch status {
        case "running", "in_progress": ("◉", "running")
        case "failed", "failure", "timed_out", "action_required", "startup_failure": ("×", "failed")
        case "passed", "success": ("✓", "passed")
        case "queued", "waiting", "pending", "requested": ("○", "running")
        case "cancelled", "skipped": ("–", "muted")
        default: ("·", "muted")
        }
        return "<span class=\"icon \(tone)\" role=\"img\" aria-label=\"\(escape(status))\" title=\"\(escape(status))\">\(symbol)</span>"
    }

    private static func link(_ url: String?, _ label: String) -> String {
        let text = escape(label)
        guard let url, let target = URLComponents(string: url),
              target.scheme == "https", target.host?.lowercased() == "github.com",
              target.user == nil, target.password == nil, target.port == nil else { return text }
        return "<a href=\"\(escape(url))\" target=\"_blank\" rel=\"noopener noreferrer\">\(text)</a>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let style = """
    :root { color-scheme: light dark; }
    body { margin: 0; color: var(--foreground, CanvasText); font: 13px var(--font-sans, system-ui); }
    main { max-width: 65rem; margin: 0 auto; padding: 8px; }
    h1, h2, p { margin: 0; }
    h1 { font-size: 17px; } h2 { font-size: 15px; }
    section { margin: 15px 0; }
    a { color: inherit; text-underline-offset: 2px; }
    summary { cursor: pointer; overflow-wrap: anywhere; }
    .line { display: flex; align-items: baseline; gap: 7px; }
    header.line { flex-wrap: wrap; margin: 0 0 8px; }
    .page-header { color: var(--foreground, CanvasText); }
    .repo { border: 1px solid var(--border, color-mix(in srgb, CanvasText 19%, Canvas)); border-radius: 7px;
            background: var(--card, Canvas); margin: 6px 0; overflow: hidden; }
    .repo > summary { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; padding: 8px 10px;
                      background: var(--secondary, color-mix(in srgb, CanvasText 7%, Canvas)); }
    .repo > summary::before { content: "▸"; } .repo[open] > summary::before { content: "▾"; }
    .branch, .file { border-top: 1px solid var(--border, color-mix(in srgb, CanvasText 15%, Canvas)); padding: 8px 10px; }
    .grow { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    .branch-name, .metric, code, pre { font-family: var(--font-mono, ui-monospace, monospace); }
    .branch-name { overflow-wrap: anywhere; }
    .metric { white-space: nowrap; font-size: 11px; }
    .pill { border: 1px solid var(--border, color-mix(in srgb, CanvasText 19%, Canvas)); border-radius: 12px;
            padding: 0 6px; white-space: nowrap; font-size: 11px; }
    .icon { display: inline-block; width: 12px; text-align: center; flex: none; }
    .running { color: var(--warning, light-dark(#985000, #ffb454)); }
    .failed { color: var(--destructive, light-dark(#b42318, #ff8a85)); }
    .passed { color: var(--success, light-dark(#086b3d, #61d89a)); }
    .muted, .metric, footer, .notice, .current { color: var(--muted-foreground, light-dark(#555, #bbb)); }
    .run, .history, .jobs, .current, .step, .job { margin: 4px 0 3px 17px; }
    .current, .jobs, .history, .hidden, .notice, footer { font-size: 12px; overflow-wrap: anywhere; }
    .hidden > summary, .notice { padding: 4px 10px; }
    .file code { overflow-wrap: anywhere; }
    pre { margin: 8px 0 0; overflow-x: auto; tab-size: 4;
          background: var(--code-background, color-mix(in srgb, CanvasText 6%, Canvas)); padding: 8px; }
    """
}
