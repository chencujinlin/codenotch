import Charts
import SwiftUI

/// Uses the settings window's existing materials and typography. The notch's
/// quota ring keeps its meaning; daily consumption has its own dated view.
struct DailyTokensView: View {
    @StateObject private var store = DailyTokenStore()
    @State private var sourceID = ""
    @State private var days = 7
    @State private var selectedDate = Date()

    private var calendar: Calendar { store.report?.calendar ?? .current }
    private var sources: [DailyTokenReport.Source] {
        (store.report?.sources ?? []).filter { sourceID.isEmpty || $0.id == sourceID }
    }
    private var hasHistory: Bool { sources.contains { $0.eventCount > 0 } }
    private var dates: [Date] {
        let today = calendar.startOfDay(for: store.report?.updatedAt ?? Date())
        return (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
    private func counts(on date: Date) -> TokenCounts {
        store.report?.totals(on: date, sourceID: sourceID.isEmpty ? nil : sourceID) ?? TokenCounts()
    }
    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(L10n.locale))
    }
    private func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(L10n.locale))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker(L10n.t("Account"), selection: $sourceID) {
                        Text(L10n.t("All accounts")).tag("")
                        ForEach(store.report?.sources ?? []) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label(L10n.t("Refresh now"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
                if store.report == nil {
                    ProgressView(L10n.t("Reading local token history…"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    overview
                    if hasHistory {
                        history
                        breakdown
                    }
                    sourceStatus
                    Text(L10n.t("Totals = uncached input + output + cache reads + cache writes. Codex and Grok reasoning is already included in output. Dates use this Mac's time zone."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.t("Only locally recorded usage is included, including subagents and archived Codex sessions. Deleted logs, other devices and unrecorded usage cannot be recovered from quota percentages."))
                        .font(.caption).foregroundStyle(.secondary)
                    if sources.contains(where: { $0.name == "Grok" }) {
                        Text(L10n.t("Grok logs do not report cache writes. Grok totals include only reported tokens."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let report = store.report {
                        Text(L10n.t("Updated \(report.updatedAt.formatted(.dateTime.hour().minute().second().locale(L10n.locale))) · refreshes every 30 seconds while open"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .textSelection(.enabled)
        .task {
            await store.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                await store.refresh()
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("Daily tokens")).font(.headline)
                Spacer()
                DatePicker(L10n.t("Date"), selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .labelsHidden().environment(\.locale, L10n.locale)
            }
            Text(hasHistory ? number(counts(on: selectedDate).total) : "—")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
                .accessibilityLabel(L10n.t("Total tokens"))
                .accessibilityValue(hasHistory ? number(counts(on: selectedDate).total) : "—")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                metric(L10n.t("Uncached input"), counts(on: selectedDate).input)
                metric(L10n.t("Output"), counts(on: selectedDate).output)
                metric(L10n.t("Cache reads"), counts(on: selectedDate).cacheRead)
                metric(L10n.t("Cache writes"), counts(on: selectedDate).cacheWrite,
                       available: !sources.allSatisfy { $0.name == "Grok" })
                if sources.contains(where: { $0.name == "Grok" }) {
                    metric(L10n.t("Grok reasoning (included in output)"), counts(on: selectedDate).reasoning,
                           available: sources.contains { $0.name == "Grok" && $0.eventCount > 0 })
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ title: String, _ value: Int, available: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(hasHistory && available ? number(value) : "—").monospacedDigit()
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L10n.t("History"), selection: $days) {
                Text(L10n.t("Last 7 days")).tag(7)
                Text(L10n.t("Last 30 days")).tag(30)
            }
            .pickerStyle(.segmented)
            Chart(dates, id: \.self) { date in
                BarMark(x: .value(L10n.t("Date"), date, unit: .day),
                        y: .value(L10n.t("Tokens"), counts(on: date).total))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel(dateText(date))
                    .accessibilityValue(number(counts(on: date).total))
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : 7)) }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) { Text(LimitWindow.compact(tokens)) }
                    }
                }
            }
            .frame(height: 130)
            ForEach(dates.reversed(), id: \.self) { date in
                Button {
                    selectedDate = date
                } label: {
                    HStack {
                        Text(dateText(date))
                        Spacer()
                        Text(number(counts(on: date).total)).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.t("Show token breakdown for this date"))
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("Models on selected date")).font(.headline)
            let events = sources.flatMap(\.events).filter { calendar.isDate($0.at, inSameDayAs: selectedDate) }
            let models = Dictionary(grouping: events, by: { $0.model.isEmpty ? L10n.t("Unknown model") : $0.model })
                .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.counts.total }) }
                .sorted { $0.total > $1.total }
            ForEach(models, id: \.name) { model in
                HStack {
                    Text(model.name).lineLimit(2)
                    Spacer()
                    Text(number(model.total)).monospacedDigit()
                }.font(.caption)
            }
            if models.isEmpty { Text(L10n.t("No recorded tokens on this date.")).foregroundStyle(.secondary) }
        }
    }

    private var sourceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sources) { source in
                HStack(alignment: .top) {
                    Image(systemName: source.eventCount > 0 ? "checkmark.circle" : "info.circle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).fontWeight(.medium)
                        Text(source.eventCount > 0 ? L10n.t("Local token records loaded") : L10n.t("No local token records found. Run this agent on this Mac to create usage history."))
                            .foregroundStyle(.secondary)
                        if source.incomplete || source.unreadableFiles > 0 {
                            Text(L10n.t("Partial history: some records are incomplete or could not be read. Totals include only available usage."))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }.font(.caption)
    }
}
