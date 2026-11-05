// Runs one prompt through the Claude Code CLI and the login it already has, walled off from everything else Claude Code
// can do. It has no tools, so text in the prompt can at worst change the answer. Safe mode keeps the person's hooks,
// plugins, MCP servers and CLAUDE.md out, and no session is saved, so these runs don't fill `claude --resume`.
//
// Dia opened from the Dock has no shell environment. The CLI is looked for where its installers put it, and macOS's
// proxy settings, which Dia itself goes through, are passed on as HTTPS_PROXY, since the CLI only reads the environment.
import CFNetwork
import Foundation

struct DPClaudeError: Error { let message: String }

private let DPClaudeTimeout: TimeInterval = 120

// The inherited PATH first, for a Dia opened from Terminal, then where the native installer, Homebrew and npm put it.
func DPClaudePath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
    let installed = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    return (inherited + installed).first { FileManager.default.isExecutableFile(atPath: $0) }
}

// macOS's HTTPS proxy, or its HTTP one, as a URL, with the hosts that skip it.
private func DPSystemProxy() -> (url: String, exceptions: [String])? {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
    let kinds = [(kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort),
                 (kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort)]
    for (enable, host, port) in kinds {
        guard settings[enable as String] as? Int == 1, let host = settings[host as String] as? String, !host.isEmpty else { continue }
        let port = (settings[port as String] as? Int).map { ":\($0)" } ?? ""
        return ("http://\(host)\(port)", settings[kCFNetworkProxiesExceptionsList as String] as? [String] ?? [])
    }
    return nil
}

private func DPClaudeEnvironment(_ claude: String) -> [String: String] {
    // A Dia started from inside a Claude Code session would otherwise pass that session on to the CLI.
    var environment = ProcessInfo.processInfo.environment.filter {
        !$0.key.hasPrefix("DYLD_") && $0.key != "CLAUDECODE" && $0.key != "CLAUDE_CODE_ENTRYPOINT"
    }
    // An npm install is a script run by `env node`, which sits beside it.
    let directory = (claude as NSString).deletingLastPathComponent
    environment["PATH"] = [directory, environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
    environment["DISABLE_AUTOUPDATER"] = "1"  // Updates are for the person's own sessions to start, not these runs.
    let named = Set(environment.keys.map { $0.lowercased() })
    if named.isDisjoint(with: ["https_proxy", "http_proxy", "all_proxy"]), let proxy = DPSystemProxy() {
        environment["HTTPS_PROXY"] = proxy.url
        environment["HTTP_PROXY"] = proxy.url
        environment["NO_PROXY"] = (["localhost", "127.0.0.1"] + proxy.exceptions).joined(separator: ",")
    }
    return environment
}

// Runs the CLI to the end with `input` on stdin, and gives back what it printed.
private func DPClaudeRun(_ claude: String, _ arguments: [String], _ input: String) throws -> (status: Int32, out: Data, err: Data) {
    let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: claude)
    process.arguments = arguments
    process.environment = DPClaudeEnvironment(claude)
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
    // If the CLI exits before reading its input, writing would raise SIGPIPE and take Dia down with it.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()
    // Both pipes are drained at once, so neither fills up and stalls the CLI.
    var out = Data(), err = Data()
    let reading = DispatchGroup()
    DispatchQueue.global().async(group: reading) { out = stdout.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: reading) { err = stderr.fileHandleForReading.readDataToEndOfFile() }
    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    // The pipes close once the CLI, and anything it left running, has exited. If that doesn't happen in time, the tidy
    // gives up rather than leave the broom busy.
    guard reading.wait(timeout: .now() + DPClaudeTimeout) == .success else {
        process.terminate()
        throw DPClaudeError(message: "Claude took too long to answer.")
    }
    process.waitUntilExit()
    return (process.terminationStatus, out, err)
}

/// `input` answered by `model` under the `system` prompt, as JSON that fits `schema`. Blocks, so it's called off the main queue.
func DPClaudeAnswer(_ claude: String, model: String, system: String, schema: String, input: String) throws -> [String: Any] {
    let arguments = ["-p", "--safe-mode", "--no-session-persistence", "--tools", "", "--output-format", "json",
                     "--model", model, "--effort", "low", "--system-prompt", system, "--json-schema", schema]
    let run = try DPClaudeRun(claude, arguments, input)
    guard let result = try? JSONSerialization.jsonObject(with: run.out) as? [String: Any] else {
        let lines = String(decoding: run.err, as: UTF8.self).split(whereSeparator: \.isNewline)
        throw DPClaudeError(message: "Claude Code stopped with an error: \(lines.last.map(String.init) ?? "exit status \(run.status)")")
    }
    if result["is_error"] as? Bool == true {
        throw DPClaudeError(message: "Claude couldn’t answer: \(result["result"] as? String ?? "unknown error")")
    }
    let text = (result["result"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    guard let answer = result["structured_output"] as? [String: Any] ?? text as? [String: Any] else {
        throw DPClaudeError(message: "Claude’s answer wasn’t in the expected form.")
    }
    return answer
}
