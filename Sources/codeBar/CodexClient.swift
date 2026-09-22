import Foundation
import Darwin

/// A short-lived, read-only stdio connection. Codex owns login and credential refresh.
/// Blocking pipe reads run off the main actor and have a bounded timeout.
final class CodexClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let candidates = [environment["AI_USAGE_CODEX_PATH"]].compactMap { $0 }
            + directories.map { $0 + "/codex" }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageFailure.cliMissing
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var childEnvironment = environment
        childEnvironment["PATH"] = directories.joined(separator: ":")
        process.environment = childEnvironment
        process.standardInput = input
        process.standardOutput = output
        // Never persist server logs: they may contain private account/config information.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageFailure.cliMissing }
        do {
            _ = try request("initialize", params: [
                "clientInfo": ["name": "codebar", "title": "codeBar", "version": "0.1.1"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // A misbehaving CLI must not hold the next refresh indefinitely.
            for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output.fileHandleForReading.close()
    }

    func request(_ method: String, params: [String: Any] = [:]) throws -> Data {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageFailure.timeout }
            let line = try readLine(deadline: deadline)
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageFailure.invalidResponse
            }
            guard message["id"] as? Int == id else { continue } // Ignore notifications.
            if let error = message["error"] as? [String: Any] {
                // Do not forward the server's raw message to logs/UI.
                throw (error["code"] as? Int == -32601 ? UsageFailure.unsupported : UsageFailure.accountUnavailable)
            }
            guard let result = message["result"] as? [String: Any] else { throw UsageFailure.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard process.isRunning else { throw UsageFailure.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine(deadline: TimeInterval) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw UsageFailure.timeout }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1_000, 500)))
            if ready < 0 { if errno == EINTR { continue }; throw UsageFailure.disconnected }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageFailure.disconnected }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 8 * 1_024 * 1_024 else { throw UsageFailure.invalidResponse }
        }
    }
}

enum UsageFailure: Error {
    case cliMissing, timeout, disconnected, unsupported, accountUnavailable, invalidResponse

    func message(english: Bool) -> String {
        switch self {
        case .cliMissing: return english ? "Install Codex CLI and sign in with codex login." : "请安装 Codex CLI，并运行 codex login 登录。"
        case .timeout: return english ? "Codex request timed out. Check your network and retry." : "Codex 请求超时，请检查网络后重试。"
        case .disconnected: return english ? "Codex exited. Check CLI configuration and retry." : "Codex 连接中断，请检查 CLI 配置后重试。"
        case .unsupported: return english ? "Update Codex CLI to read account usage." : "请升级 Codex CLI 以读取账户用量。"
        case .accountUnavailable: return english ? "Account usage unavailable. Check codex login status and your network." : "账户用量暂不可用，请检查 codex login status 和网络。"
        case .invalidResponse: return english ? "Unsupported usage response. Update Codex CLI and retry." : "用量返回格式不兼容，请升级 Codex CLI 后重试。"
        }
    }
}
