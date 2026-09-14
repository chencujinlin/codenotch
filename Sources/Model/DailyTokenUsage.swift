import Foundation
import CoreFoundation

/// Disjoint buckets: cached input and reasoning must never be counted twice.
struct TokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
             cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

struct TokenEvent: Equatable, Sendable {
    let id: String
    let at: Date
    let counts: TokenCounts
    var model: String = ""
    var project: String = ""
    var messageID: String? = nil
    var sidechain = false
    var signature: String? = nil
}

/// Only usage metadata survives decoding. Conversation text is never retained.
struct TokenLogParser {
    enum Kind: String, Sendable { case claude, codex }

    private(set) var events: [String: TokenEvent] = [:]
    private(set) var incomplete = false
    private var previousCodex: TokenCounts?
    private(set) var sessionID: String?
    private(set) var parentID: String?
    private(set) var eventOrder: [String] = []
    private var model = ""
    private var project = ""
    private let dates = ISO8601DateFormatter()

    mutating func consume(_ line: Data, kind: Kind) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if !line.isEmpty { incomplete = true }
            return
        }
        switch kind {
        case .claude: consumeClaude(json)
        case .codex: consumeCodex(json)
        }
    }

    private func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = dates.date(from: value) { return date }
        dates.formatOptions = [.withInternetDateTime]
        return dates.date(from: value)
    }

    private func number(_ usage: [String: Any], _ key: String) -> Int? {
        guard let n = usage[key] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue >= 0, n.doubleValue < 1e15,
              n.doubleValue.rounded(.down) == n.doubleValue else { return nil }
        return n.intValue
    }

    private func counts(_ usage: [String: Any], kind: Kind) -> TokenCounts? {
        guard let input = number(usage, "input_tokens"),
              let output = number(usage, "output_tokens") else { return nil }
        let readKey = kind == .claude ? "cache_read_input_tokens" : "cached_input_tokens"
        let writeKey = kind == .claude ? "cache_creation_input_tokens" : "cache_write_input_tokens"
        for key in [readKey, writeKey] where usage[key] != nil {
            guard number(usage, key) != nil else { return nil }
        }
        let read = number(usage, readKey) ?? 0
        let write = number(usage, writeKey) ?? 0
        if kind == .codex, read + write > input { return nil }
        return TokenCounts(input: kind == .codex ? input - read - write : input,
                           output: output, cacheRead: read, cacheWrite: write)
    }

    private mutating func consumeClaude(_ json: [String: Any]) {
        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        guard let id = (message["id"] as? String) ?? (json["uuid"] as? String), !id.isEmpty,
              let at = timestamp(json["timestamp"]),
              let counts = counts(usage, kind: .claude) else { incomplete = true; return }
        // Streaming snapshots and tool blocks can repeat a message. Keep the
        // largest snapshot, including when copied into a resumed transcript.
        let key = "claude:\(id):\((json["requestId"] as? String) ?? (json["request_id"] as? String) ?? "")"
        if let old = events[key], old.counts.total > counts.total { return }
        events[key] = TokenEvent(id: key, at: events[key]?.at ?? at, counts: counts,
                                 model: message["model"] as? String ?? "",
                                 project: json["cwd"] as? String ?? "",
                                 messageID: message["id"] as? String,
                                 sidechain: json["isSidechain"] as? Bool ?? false)
    }

    private mutating func consumeCodex(_ json: [String: Any]) {
        if let payload = json["payload"] as? [String: Any] {
            if json["type"] as? String == "session_meta" {
                sessionID = payload["id"] as? String ?? payload["session_id"] as? String
                let source = payload["source"] as? [String: Any]
                let subagent = source?["subagent"] as? [String: Any]
                let spawn = subagent?["thread_spawn"] as? [String: Any]
                parentID = payload["forked_from_id"] as? String ?? spawn?["parent_thread_id"] as? String
            }
            if ["session_meta", "turn_context"].contains(json["type"] as? String ?? "") {
                model = payload["model"] as? String ?? model
                project = payload["cwd"] as? String ?? project
                return
            }
        }
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else { return }
        guard let at = timestamp(json["timestamp"]) else { incomplete = true; return }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap { counts($0, kind: .codex) }
        guard let usage = info["total_token_usage"] as? [String: Any],
              let current = counts(usage, kind: .codex) else {
            incomplete = true
            if let last {
                let key = "last:\(sessionID ?? ""):\(at.timeIntervalSince1970):\(json["ordinal"] ?? eventOrder.count)"
                events[key] = TokenEvent(id: key, at: at, counts: last, model: model, project: project)
                eventOrder.append(key)
            }
            return
        }
        let delta: TokenCounts
        if let previous = previousCodex {
            if previous == current { return }
            // Input is inclusive in Codex. Subtract inclusive counters before
            // removing cache hits, since the uncached bucket may decrease.
            let inputDelta = (current.input + current.cacheRead + current.cacheWrite)
                - (previous.input + previous.cacheRead + previous.cacheWrite)
            let read = current.cacheRead - previous.cacheRead
            let write = current.cacheWrite - previous.cacheWrite
            let output = current.output - previous.output
            if inputDelta >= 0, read >= 0, write >= 0, output >= 0, inputDelta >= read + write {
                delta = TokenCounts(input: inputDelta - read - write, output: output,
                                    cacheRead: read, cacheWrite: write)
            } else {
                // Compaction/reset: only the reported last response is safe.
                incomplete = true
                guard let last else { previousCodex = current; return }
                delta = last
            }
        } else {
            // An excerpt can start halfway through a session. Filing its
            // lifetime total under today's date would invent daily usage.
            guard let last else { previousCodex = current; incomplete = true; return }
            delta = last
            if last != current { incomplete = true }
        }
        previousCodex = current
        guard delta.total > 0 else { return }
        // Forks and archived copies retain the original timestamp/counters.
        let signature = "\(current.input):\(current.output):\(current.cacheRead):\(current.cacheWrite):\(last?.input ?? -1):\(last?.output ?? -1):\(last?.cacheRead ?? -1):\(last?.cacheWrite ?? -1)"
        let key = "codex:\(sessionID ?? ""):\(json["timestamp"] as? String ?? ""):\(signature)"
        events[key] = TokenEvent(id: key, at: at, counts: delta, model: model,
                                 project: project, signature: signature)
        eventOrder.append(key)
    }
}

struct TokenLogSource: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: TokenLogParser.Kind
    let directories: [URL]
}

struct DailyTokenReport: Sendable {
    struct Source: Identifiable, Sendable {
        let id: String
        let name: String
        var days: [Date: TokenCounts] = [:]
        var eventCount = 0
        var incomplete = false
        var unreadableFiles = 0
        var events: [TokenEvent] = []
    }

    let sources: [Source]
    let updatedAt: Date
    let calendar: Calendar

    func totals(on date: Date, sourceID: String? = nil) -> TokenCounts {
        let day = calendar.startOfDay(for: date)
        return sources.filter { sourceID == nil || $0.id == sourceID }
            .reduce(TokenCounts()) { $0 + ($1.days[day] ?? TokenCounts()) }
    }
}

/// Runs off the UI thread. Unchanged files cost only metadata reads; changed
/// files are streamed in bounded chunks so a long session cannot fill RAM.
actor DailyTokenReader {
    private struct Cached {
        let size: Int
        let modified: Date
        let events: [String: TokenEvent]
        let incomplete: Bool
        let sessionID: String?
        let parentID: String?
        let order: [String]
    }
    private var cache: [URL: Cached] = [:]

    func scan(sources: [TokenLogSource], now: Date = Date(),
              calendar: Calendar = .current) -> DailyTokenReport {
        var seen = Set<URL>()
        let results = sources.map { source in
            var result = DailyTokenReport.Source(id: source.id, name: source.name)
            var events: [String: TokenEvent] = [:]
            var parsedFiles: [(URL, Cached)] = []
            for directory in source.directories {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in
                        result.unreadableFiles += 1
                        return true
                    }
                ) else { result.unreadableFiles += 1; continue }
                for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                    seen.insert(url)
                    do {
                        let parsed = try read(url, kind: source.kind)
                        result.incomplete = result.incomplete || parsed.incomplete
                        parsedFiles.append((url, parsed))
                    } catch {
                        result.unreadableFiles += 1
                        // Retain the last known counts, but visibly flag the
                        // source as partial instead of silently showing zero.
                        if let cached = cache[url] {
                            parsedFiles.append((url, cached))
                        }
                    }
                }
            }
            // Prefer the longest copy of a session when active and archived
            // directories overlap. Only explicit ancestry permits replay removal.
            let bySession = Dictionary(grouping: parsedFiles.filter { $0.1.sessionID != nil },
                                       by: { $0.1.sessionID! })
                .mapValues { $0.max { $0.1.order.count < $1.1.order.count }! }
            for (url, parsed) in parsedFiles {
                if let sid = parsed.sessionID, bySession[sid]?.0 != url { continue }
                var dropped = Set<String>()
                if let parentID = parsed.parentID {
                    if let parent = bySession[parentID]?.1 {
                        let ancestorSignatures = Set(parent.events.values.compactMap(\.signature))
                        for key in parsed.order {
                            guard let signature = parsed.events[key]?.signature,
                                  ancestorSignatures.contains(signature) else { break }
                            dropped.insert(key)
                        }
                    } else { result.incomplete = true }
                }
                for (id, event) in parsed.events where !dropped.contains(id) {
                    if let old = events[id], old.counts.total >= event.counts.total { continue }
                    events[id] = event
                }
            }
            let mainMessages = Set(events.values.filter { !$0.sidechain }.compactMap(\.messageID))
            events = events.filter { !($0.value.sidechain && $0.value.messageID.map(mainMessages.contains) == true) }
            result.events = Array(events.values)
            result.eventCount = events.count
            for event in events.values {
                let day = calendar.startOfDay(for: event.at)
                result.days[day] = (result.days[day] ?? TokenCounts()) + event.counts
            }
            return result
        }
        cache = cache.filter { seen.contains($0.key) }
        return DailyTokenReport(sources: results, updatedAt: now, calendar: calendar)
    }

    private func read(_ url: URL, kind: TokenLogParser.Kind) throws -> Cached {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        if let cached = cache[url], cached.size == size, cached.modified == modified { return cached }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var parser = TokenLogParser()
        var buffer = Data()
        var skipping = false
        var oversized = false
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for part in chunk.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                if part.offset > 0 {
                    if !skipping { parser.consume(buffer, kind: kind) }
                    buffer.removeAll(keepingCapacity: true)
                    skipping = false
                }
                if !skipping {
                    if buffer.count + part.element.count > 16 * 1024 * 1024 {
                        buffer.removeAll(keepingCapacity: false)
                        skipping = true
                        oversized = true
                    } else { buffer.append(contentsOf: part.element) }
                }
            }
        }
        // A trailing record can be mid-write. Retry it on the next file change.
        // Valid JSON without a trailing newline is still a complete record.
        if !skipping, !buffer.isEmpty {
            if (try? JSONSerialization.jsonObject(with: buffer)) != nil {
                parser.consume(buffer, kind: kind)
            } else { oversized = true }
        }
        let cached = Cached(size: size, modified: modified, events: parser.events,
                            incomplete: parser.incomplete || oversized,
                            sessionID: parser.sessionID, parentID: parser.parentID, order: parser.eventOrder)
        cache[url] = cached
        return cached
    }
}
