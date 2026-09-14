import Combine
import Foundation

@MainActor
final class DailyTokenStore: ObservableObject {
    @Published private(set) var report: DailyTokenReport?
    @Published private(set) var isRefreshing = false
    private let reader = DailyTokenReader()
    private let sources: [TokenLogSource]

    init(sources: [TokenLogSource] = DailyTokenStore.localSources()) {
        self.sources = sources
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        report = await reader.scan(sources: sources)
        isRefreshing = false
    }

    /// Token history needs no sign-in. Discover profiles by their log paths,
    /// independently of the quota providers' credential discovery.
    nonisolated static func localSources(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> [TokenLogSource] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).sorted()
        var sources: [TokenLogSource] = []
        var roots = Set<URL>()
        for kind in [TokenLogParser.Kind.claude, .codex] {
            let prefix = ".\(kind.rawValue)"
            var candidates = [home.appendingPathComponent(prefix)]
            candidates += names.filter { $0.hasPrefix(prefix + "-") }.map { home.appendingPathComponent($0) }
            let key = kind == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            if let path = environment[key], !path.isEmpty {
                candidates.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            }
            for (index, candidate) in candidates.enumerated() {
                let root = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard roots.insert(root).inserted else { continue }
                let directories = (kind == .claude ? ["projects"] : ["sessions", "archived_sessions"])
                    .map { root.appendingPathComponent($0) }
                if index != 0, !directories.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { continue }
                let name = kind == .claude ? "Claude Code" : "Codex"
                let suffix = candidate.lastPathComponent.hasPrefix(prefix + "-")
                    ? String(candidate.lastPathComponent.dropFirst(prefix.count + 1)) : candidate.lastPathComponent
                sources.append(TokenLogSource(id: root.path, name: index == 0 ? name : "\(name) (\(suffix))",
                                              kind: kind, directories: directories))
            }
        }
        return sources
    }
}
