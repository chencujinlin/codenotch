import Foundation
import Testing
@testable import Codenotch

@Suite
final class DailyTokenUsageTests {
    private var temporaryDirectories: [URL] = []
    deinit { for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) } }
    private func claude(id: String? = "m1", request: String = "r1", input: Int = 10,
                        output: Int = 5, read: Int = 20, write: Int = 30,
                        sidechain: Bool = false, at: String = "2026-09-14T15:59:00Z") -> String {
        let messageID = id.map { "\"\($0)\"" } ?? "null"
        return """
        {"type":"assistant","uuid":"event-1","timestamp":"\(at)","requestId":"\(request)",
         "isSidechain":\(sidechain),"cwd":"/tmp/project","message":{"id":\(messageID),
         "model":"claude-test","usage":{"input_tokens":\(input),"output_tokens":\(output),
         "cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(write)}}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    private func codex(input: Int, output: Int, cached: Int = 0, write: Int = 0,
                       last: String? = nil, at: String = "2026-09-14T15:59:00Z") -> String {
        let total = """
        {"input_tokens":\(input),"output_tokens":\(output),"cached_input_tokens":\(cached),
        "cache_write_input_tokens":\(write),"reasoning_output_tokens":2}
        """.replacingOccurrences(of: "\n", with: "")
        return """
        {"timestamp":"\(at)","ordinal":42,"type":"event_msg","payload":{"type":"token_count",
         "info":{"total_token_usage":\(total),"last_token_usage":\(last ?? total)}}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    private func meta(_ id: String, parent: String? = nil) -> String {
        let parentField = parent.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        return """
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/project"\(parentField)}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    private func parse(_ lines: [String], kind: TokenLogParser.Kind) -> TokenLogParser {
        var parser = TokenLogParser()
        for line in lines { parser.consume(Data(line.utf8), kind: kind) }
        return parser
    }

    @Test func testClaudeAddsDisjointCacheBuckets() {
        let parser = parse([claude()], kind: .claude)
        #expect(parser.events.values.first?.counts.total == 65)
        #expect(parser.events.values.first?.model == "claude-test")
        #expect(!(parser.incomplete))
    }

    @Test func testClaudeStreamingKeepsLargestSnapshotButDistinctRequestsSurvive() {
        let parser = parse([claude(), claude(output: 10), claude(output: 3),
                            claude(request: "r2")], kind: .claude)
        #expect(parser.events.count == 2)
        #expect(parser.events.values.reduce(0) { $0 + $1.counts.total } == 135)
    }

    @Test func testClaudeFallsBackToUUID() {
        #expect(parse([claude(id: nil), claude(id: nil)], kind: .claude).events.count == 1)
    }

    @Test func testCodexCacheAndReasoningAreNotCountedTwice() {
        let parser = parse([codex(input: 100, output: 10, cached: 60, write: 10)], kind: .codex)
        #expect(parser.events.values.first?.counts == TokenCounts(input: 30, output: 10, cacheRead: 60, cacheWrite: 10))
        #expect(parser.events.values.first?.counts.total == 110)
    }

    @Test func testCodexRepeatedTotalsAreIgnoredAndNewTotalsAreDifferenced() {
        let first = codex(input: 100, output: 10, cached: 60)
        let second = codex(input: 150, output: 20, cached: 90, at: "2026-09-14T16:01:00Z")
        let parser = parse([first, first, second], kind: .codex)
        #expect(parser.events.count == 2)
        #expect(parser.events.values.reduce(0) { $0 + $1.counts.total } == 170)
    }

    @Test func testCodexExcerptDoesNotAssignLifetimeUsageToOneDay() {
        let last = "{\"input_tokens\":20,\"output_tokens\":2}"
        let parser = parse([codex(input: 1000, output: 100, last: last)], kind: .codex)
        #expect(parser.events.values.first?.counts.total == 22)
        #expect(parser.incomplete)
    }

    @Test func testCodexCounterResetUsesOnlyLastResponse() {
        let parser = parse([codex(input: 100, output: 10), codex(input: 10, output: 2)], kind: .codex)
        #expect(parser.events.values.reduce(0) { $0 + $1.counts.total } == 122)
        #expect(parser.incomplete)
    }

    @Test func testInvalidUsageIsNotShownAsZero() {
        let parser = parse(["not JSON", claude(input: -5)], kind: .claude)
        #expect(parser.incomplete)
        #expect(parser.events.isEmpty)
        #expect(parse([codex(input: 10, output: 1, cached: 20)], kind: .codex).events.isEmpty)
    }

    @Test func testCodexModelChangesFollowTurnContext() {
        let parser = parse([meta("s"),
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"model-a\"}}",
            codex(input: 100, output: 10),
            "{\"type\":\"turn_context\",\"payload\":{\"model\":\"model-b\"}}",
            codex(input: 150, output: 20, at: "2026-09-14T16:01:00Z")], kind: .codex)
        let totals = Dictionary(grouping: parser.events.values, by: \.model)
            .mapValues { $0.reduce(0) { $0 + $1.counts.total } }
        #expect(totals == ["model-a": 110, "model-b": 60])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ lines: [String], to directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func source(_ directory: URL, kind: TokenLogParser.Kind = .codex) -> TokenLogSource {
        TokenLogSource(id: kind.rawValue, name: kind.rawValue, kind: kind, directories: [directory])
    }

    private func total(_ report: DailyTokenReport) -> Int {
        report.sources.flatMap { $0.days.values }.reduce(0) { $0 + $1.total }
    }

    @Test func testMidnightUsesLocalCalendarAndRefreshDoesNotDoubleCount() async throws {
        let directory = try temporaryDirectory()
        try write([meta("s"), codex(input: 100, output: 10),
                   codex(input: 150, output: 20, at: "2026-09-14T16:01:00Z")], to: directory, name: "s")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reader = DailyTokenReader()
        let first = await reader.scan(sources: [source(directory)], calendar: calendar)
        let next = await reader.scan(sources: [source(directory)], calendar: calendar)
        #expect(total(first) == 170)
        #expect(total(next) == 170)
        #expect(first.sources[0].days.count == 2)
        let utc = await reader.scan(sources: [source(directory)], calendar: Calendar(identifier: .iso8601))
        // Force UTC explicitly; the machine running the test may be in China.
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let regrouped = await reader.scan(sources: [source(directory)], calendar: utcCalendar)
        #expect(regrouped.sources[0].days.count == 1)
        #expect(total(utc) == 170)
    }

    @Test func testForkReplayWithNewTimestampsIsRemovedButChildUsageRemains() async throws {
        let directory = try temporaryDirectory()
        try write([meta("parent"), codex(input: 100, output: 10)], to: directory, name: "parent")
        try write([meta("child", parent: "parent"),
                   codex(input: 100, output: 10, at: "2026-09-15T01:00:00Z"),
                   codex(input: 150, output: 20, at: "2026-09-15T01:01:00Z")], to: directory, name: "child")
        let report = await DailyTokenReader().scan(sources: [source(directory)])
        #expect(total(report) == 170)
        #expect(report.sources[0].eventCount == 2)
    }

    @Test func testIndependentSessionsWithIdenticalUsageAreKept() async throws {
        let directory = try temporaryDirectory()
        for id in ["one", "two"] {
            try write([meta(id), codex(input: 100, output: 10)], to: directory, name: id)
        }
        let report = await DailyTokenReader().scan(sources: [source(directory)])
        #expect(total(report) == 220)
    }

    @Test func testArchivedCopyDoesNotDoubleCount() async throws {
        let directory = try temporaryDirectory()
        for name in ["original", "archive"] {
            try write([meta("same"), codex(input: 100, output: 10)], to: directory, name: name)
        }
        let report = await DailyTokenReader().scan(sources: [source(directory)])
        #expect(total(report) == 110)
    }

    @Test func testClaudeParentReplacesSidechainReplayButUniqueSubagentCounts() async throws {
        let directory = try temporaryDirectory()
        try write([claude()], to: directory, name: "parent")
        try write([claude(request: "side", input: 500, sidechain: true),
                   claude(id: "child", sidechain: true)], to: directory, name: "subagent")
        let report = await DailyTokenReader().scan(sources: [source(directory, kind: .claude)])
        #expect(total(report) == 130)
    }

    @Test func testAppendPartialLineAndTruncateAreReconciled() async throws {
        let directory = try temporaryDirectory()
        let file = try write([claude()], to: directory, name: "s")
        let reader = DailyTokenReader()
        let input = [source(directory, kind: .claude)]
        let initial = await reader.scan(sources: input)
        #expect(total(initial) == 65)
        let next = claude(id: "m2")
        try (claude() + "\n" + String(next.prefix(50))).write(to: file, atomically: true, encoding: .utf8)
        let partial = await reader.scan(sources: input)
        #expect(total(partial) == 65)
        #expect(partial.sources[0].incomplete)
        try (claude() + "\n" + next).write(to: file, atomically: true, encoding: .utf8)
        let complete = await reader.scan(sources: input)
        #expect(total(complete) == 130)
        #expect(!(complete.sources[0].incomplete))
        try "".write(to: file, atomically: true, encoding: .utf8)
        let truncated = await reader.scan(sources: input)
        #expect(total(truncated) == 0)
    }

    @Test func testEmptyAndMissingSourcesRemainExplicit() async throws {
        let directory = try temporaryDirectory()
        let report = await DailyTokenReader().scan(sources: [source(directory),
            TokenLogSource(id: "missing", name: "Missing", kind: .claude,
                           directories: [directory.appendingPathComponent("missing")])])
        #expect(report.sources.count == 2)
        #expect(report.sources.allSatisfy { $0.eventCount == 0 })
    }

    private func grok(sid: String = "g1", input: Int = 100, output: Int = 20,
                      read: Int = 60, reasoning: Int = 5, loop: Int = 0,
                      at: String = "2026-09-14T15:59:00Z") -> String {
        """
        {"ts":"\(at)","sid":"\(sid)","msg":"shell.turn.inference_done",
         "ctx":{"prompt_tokens":\(input),"completion_tokens":\(output),
         "cached_prompt_tokens":\(read),"reasoning_tokens":\(reasoning),"loop_index":\(loop),"attempts":1}}
        """.replacingOccurrences(of: "\n", with: "")
    }

    @Test func testGrokMatchesTokeiTotalWithoutCountingCacheOrReasoningTwice() {
        let parser = parse([grok()], kind: .grok)
        #expect(parser.events.values.first?.counts == TokenCounts(input: 40, output: 20, cacheRead: 60, reasoning: 5))
        #expect(parser.events.values.first?.counts.total == 120)
        #expect(!parser.incomplete)
    }

    @Test func testGrokUsesPerCallCountsEvenWhenNextCallIsSmaller() {
        let parser = parse([grok(), grok(input: 20, output: 10, read: 10, loop: 1)], kind: .grok)
        #expect(parser.events.values.reduce(0) { $0 + $1.counts.total } == 150)
        #expect(!parser.incomplete)
    }

    @Test func testGrokDeduplicatesCopiesButKeepsIndependentCalls() {
        let parser = parse([grok(), grok(), grok(sid: "g2"), grok(loop: 1),
                            grok(at: "2026-09-14T16:01:00Z")], kind: .grok)
        #expect(parser.events.count == 4)
        #expect(parser.events.values.reduce(0) { $0 + $1.counts.total } == 480)
    }

    @Test func testGrokOldContextAndTurnSummariesNeverBecomeTokenUsage() {
        let context = #"{"timestamp":"2026-09-14T15:59:00Z","params":{"_meta":{"totalTokens":999999},"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":999999,"outputTokens":123}}}}"#
        let old = #"{"ts":"2026-09-14T15:59:00Z","sid":"g1","msg":"shell.turn.inference_done","ctx":{"loop_index":0}}"#
        let parser = parse([context, old], kind: .grok)
        #expect(parser.events.isEmpty)
        #expect(parser.incomplete)
    }

    @Test func testGrokInvalidUsageIsPartialRatherThanZero() {
        let invalid = [grok(input: -1), grok(read: 101), grok(reasoning: 21),
                       grok().replacingOccurrences(of: "\"prompt_tokens\":100", with: "\"prompt_tokens\":true"),
                       grok().replacingOccurrences(of: "\"cached_prompt_tokens\":60", with: "\"cached_prompt_tokens\":1.5"),
                       grok(at: "invalid"), grok(sid: "")]
        for line in invalid {
            let parser = parse([line], kind: .grok)
            #expect(parser.events.isEmpty)
            #expect(parser.incomplete)
        }
    }

    @Test func testGrokMissingOptionalBucketsAndGenuineZeroUsage() {
        let json = #"{"ts":"2026-09-14T15:59:00Z","sid":"g1","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"completion_tokens":0}}"#
        let parser = parse([json], kind: .grok)
        #expect(parser.events.values.first?.counts.total == 0)
        #expect(!parser.incomplete)
    }

    @Test func testGrokLocalMidnightRefreshCopiesAndMetadata() async throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("logs")
        let backup = root.appendingPathComponent("copy")
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fproject/g1")
        for directory in [logs, backup, session] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let summary = session.appendingPathComponent("summary.json")
        try #"{"info":{"id":"g1"},"current_model_id":"grok-test"}"#.write(to: summary, atomically: true, encoding: .utf8)
        let lines = [grok(), grok(input: 200, read: 100, at: "2026-09-14T16:01:00Z")]
        for directory in [logs, backup] { try write(lines, to: directory, name: "unified") }
        // A different JSONL file is not an additional source of billing records.
        try write([grok(sid: "unrelated")], to: logs, name: "updates")
        let source = TokenLogSource(id: "grok", name: "Grok", kind: .grok, directories: [logs, backup])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reader = DailyTokenReader()
        let first = await reader.scan(sources: [source], calendar: calendar)
        #expect(total(first) == 340)
        #expect(first.sources[0].days.count == 2)
        #expect(first.sources[0].events.allSatisfy { $0.model == "grok-test" && $0.project == "/tmp/project" })
        #expect(first.sources[0].days.values.reduce(0) { $0 + $1.reasoning } == 10)
        try #"{"info":{"id":"g1"},"current_model_id":"grok-new"}"#.write(to: summary, atomically: true, encoding: .utf8)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let next = await reader.scan(sources: [source], calendar: calendar)
        #expect(total(next) == 340)
        #expect(next.sources[0].days.count == 1)
        #expect(next.sources[0].events.allSatisfy { $0.model == "grok-new" })
    }

    @Test func testGrokPartialAppendTruncationAndDeletion() async throws {
        let directory = try temporaryDirectory()
        let file = try write([grok()], to: directory, name: "unified")
        let reader = DailyTokenReader()
        let inputs = [source(directory, kind: .grok)]
        #expect(total(await reader.scan(sources: inputs)) == 120)
        let next = grok(loop: 1)
        try (grok() + "\n" + String(next.prefix(30))).write(to: file, atomically: true, encoding: .utf8)
        let partial = await reader.scan(sources: inputs)
        #expect(total(partial) == 120)
        #expect(partial.sources[0].incomplete)
        try (grok() + "\n" + next).write(to: file, atomically: true, encoding: .utf8)
        let complete = await reader.scan(sources: inputs)
        #expect(total(complete) == 240)
        #expect(!complete.sources[0].incomplete)
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(total(await reader.scan(sources: inputs)) == 0)
        try FileManager.default.removeItem(at: file)
        #expect(total(await reader.scan(sources: inputs)) == 0)
    }

    @Test func testGrokSourceDiscoveryHonorsHomeOverride() throws {
        let home = try temporaryDirectory()
        let defaults = DailyTokenStore.localSources(home: home, environment: [:])
        #expect(defaults.first { $0.kind == .grok }?.directories == [home.appendingPathComponent(".grok/logs").resolvingSymlinksInPath()])
        let override = home.appendingPathComponent("custom-grok")
        let sources = DailyTokenStore.localSources(home: home, environment: ["GROK_HOME": override.path])
        #expect(sources.filter { $0.kind == .grok }.count == 1)
        #expect(sources.first { $0.kind == .grok }?.directories == [override.appendingPathComponent("logs").resolvingSymlinksInPath()])
        #expect(sources.contains { $0.kind == .claude } && sources.contains { $0.kind == .codex })
    }
}
