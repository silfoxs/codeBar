import Foundation

/// Local-device estimate, not an account billing ledger. Cache parsed totals so
/// a 10-second refresh does not repeatedly read unchanged conversation files.
final class CodexLocalUsageReader: @unchecked Sendable {
    private struct Entry {
        let size: Int
        let modified: Date
        let records: [String: Int]
    }
    private let root: URL
    private let lock = NSLock()
    private var cachedDay: Date?
    private var cache: [URL: Entry] = [:]

    init(root: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.root = root ?? home
    }

    func todayTokens(reference: Date = .now, calendar: Calendar = .current) throws -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let start = calendar.startOfDay(for: reference)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        if cachedDay != start { cache.removeAll(); cachedDay = start }
        var records: [String: Int] = [:]
        var foundDirectory = false
        var visited: Set<URL> = []
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            foundDirectory = true
            var enumerationError: Error?
            guard let files = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw CocoaError(.fileReadNoPermission) }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = attributes.contentModificationDate, modified >= start else { continue }
                let size = attributes.fileSize ?? 0
                visited.insert(url)
                let entry: Entry
                if let saved = cache[url], saved.size == size, saved.modified == modified {
                    entry = saved
                } else {
                    entry = Entry(size: size, modified: modified,
                                  records: try Self.read(url, start: start, end: end))
                    cache[url] = entry
                }
                for (id, tokens) in entry.records { records[id] = max(records[id] ?? 0, tokens) }
            }
            if let enumerationError { throw enumerationError }
        }
        cache = cache.filter { visited.contains($0.key) }
        // No usable records means unknown, not proof that today's usage is zero.
        return foundDirectory && !records.isEmpty ? records.values.reduce(0, +) : nil
    }

    private static func read(_ url: URL, start: Date, end: Date) throws -> [String: Int] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var modern: [String: Int] = [:]
        var legacy: [String: Int] = [:]
        var hasModernRecords = false
        var previousTotal: Int?
        var buffer = Data()
        func consume(_ line: Data) {
            // Avoid decoding messages, prompts and tool output.
            guard let text = String(data: line, encoding: .utf8),
                  text.contains("\"token_usage_record\"") || text.contains("\"token_count\""),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else { return }
            if object["type"] as? String == "token_usage_record" {
                hasModernRecords = true
                guard date >= start, date < end,
                      let id = payload["response_id"] as? String, !id.isEmpty,
                      let usage = payload["usage"] as? [String: Any],
                      let tokens = usage["total_tokens"] as? Int, tokens >= 0 else { return }
                modern[id] = max(modern[id] ?? 0, tokens)
            } else if object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any],
                      let total = usage["total_tokens"] as? Int, total >= 0 {
                let last = (info["last_token_usage"] as? [String: Any])?["total_tokens"] as? Int
                let delta: Int
                if let previousTotal, total >= previousTotal { delta = total - previousTotal }
                else { delta = max(0, last ?? 0) }
                previousTotal = total
                guard date >= start, date < end, delta > 0 else { return }
                // Copied/forked history retains timestamps; don't count it twice.
                legacy["legacy/\(timestamp)/\(total)"] = delta
            }
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                consume(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
        }
        // A live writer may leave a partial final line; retry it on the next refresh.
        return hasModernRecords ? modern : legacy
    }
}
