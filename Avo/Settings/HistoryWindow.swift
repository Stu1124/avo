import AppKit
import SwiftUI

/// Conversation history: every turn grouped by day, plus session summaries.
@MainActor
final class HistoryWindow {
    static let shared = HistoryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = DarkWindow.make(title: "History", size: NSSize(width: 600, height: 680), resizable: true,
                                    minSize: NSSize(width: 460, height: 420), content: HistoryView(history: History.shared))
            w.setFrameAutosaveName("AvoHistory")
            window = w
        }
        DarkWindow.present(window!)
    }
}

struct HistoryView: View {
    @ObservedObject var history: History
    @State private var query = ""
    @State private var tab = "turns"
    @State private var confirmClear = false

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
    private static let dayYear: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d, yyyy"; return f
    }()

    private var filtered: [History.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = history.entries.reversed()
        if q.isEmpty { return Array(all) }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private struct DayGroup: Identifiable { let day: Date; let entries: [History.Entry]; var id: Date { day } }

    private var days: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, entries: grouped[$0]!) }
    }

    private var summaries: [History.Summary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = history.summaries.reversed()
        if q.isEmpty { return Array(all) }
        return all.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return cal.isDate(d, equalTo: Date(), toGranularity: .year) ? Self.day.string(from: d) : Self.dayYear.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            if confirmClear { clearBar }
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                if tab == "turns" { turns } else { summaryList }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Text("History").font(DS.font(DS.Size.title, .semibold)).foregroundStyle(Theme.ink).tracking(-0.4)
            Spacer()
            HStack(spacing: 2) {
                segment("Turns", id: "turns", count: history.entries.count)
                segment("Summaries", id: "summaries", count: history.summaries.count)
            }
            .padding(3)
            .background(Capsule().fill(Theme.fill1))
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
            DSPill("Clear", icon: "trash", style: .destructive) {
                withAnimation(Theme.springQuick) { confirmClear = true }
            }
            .disabled(history.entries.isEmpty && history.summaries.isEmpty)
            .opacity(history.entries.isEmpty && history.summaries.isEmpty ? 0.5 : 1)
        }
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    private func segment(_ label: String, id: String, count: Int) -> some View {
        let on = tab == id
        return Button {
            withAnimation(Theme.springQuick) { tab = id }
        } label: {
            HStack(spacing: 5) {
                Text(label).font(DS.font(DS.Size.caption, .semibold))
                Text("\(count)").font(DS.mono(DS.Size.label)).foregroundStyle(on ? Theme.ink2 : Theme.ink3)
            }
            .foregroundStyle(on ? Theme.ink : Theme.ink3)
            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
            .background(Capsule().fill(on ? Theme.fill2 : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
                .font(DS.font(DS.Size.body))
                .foregroundStyle(Theme.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var clearBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            Text("Clear all turns and summaries? This can't be undone.").font(DS.font(DS.Size.body, .medium)).foregroundStyle(Theme.ink)
            Spacer()
            DSPill("Cancel", style: .ghost) { withAnimation(Theme.springQuick) { confirmClear = false } }
            DSPill("Clear everything", style: .destructive) {
                history.clear()
                withAnimation(Theme.springQuick) { confirmClear = false }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).fill(Theme.bad.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous).strokeBorder(Theme.bad.opacity(0.3), lineWidth: 0.8))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder private var turns: some View {
        if days.isEmpty {
            emptyState(query.isEmpty ? "No turns yet. Use your talk key and say something." : "Nothing matches “\(query)”.")
        } else {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(days) { group in
                    Section {
                        ForEach(group.entries) { e in EntryRow(entry: e, time: Self.time.string(from: e.at)) }
                    } header: {
                        dayHeader(dayLabel(group.day))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func dayHeader(_ label: String) -> some View {
        HStack {
            Text(label.uppercased()).font(DS.font(DS.Size.label, .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Theme.glass.opacity(0.92))
    }

    @ViewBuilder private var summaryList: some View {
        if summaries.isEmpty {
            emptyState(query.isEmpty ? "No session summaries yet." : "Nothing matches “\(query)”.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(summaries) { s in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(dayLabel(s.at)).font(DS.mono(DS.Size.label)).foregroundStyle(Theme.ink2)
                            Text(Self.time.string(from: s.at)).font(DS.mono(DS.Size.label)).foregroundStyle(Theme.ink3)
                        }
                        .frame(width: 92, alignment: .trailing)
                        Text(s.text).font(DS.font(DS.Size.body)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                    .background(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).fill(Theme.fill1))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.8))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func emptyState(_ text: String) -> some View {
        EmptyState(icon: "clock.arrow.circlepath", text: text, topPadding: 80)
    }
}

private struct EntryRow: View {
    let entry: History.Entry
    let time: String
    private var isUser: Bool { entry.role.lowercased() == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text(time).font(DS.mono(DS.Size.label)).foregroundStyle(Theme.ink3).frame(width: 60, alignment: .leading).padding(.top, DS.Space.m)
            VStack(alignment: .leading, spacing: 3) {
                Text(isUser ? "You" : "Avo").font(DS.font(DS.Size.label, .semibold)).tracking(0.3)
                    .foregroundStyle(isUser ? Theme.accent : Theme.ink2)
                Group {
                    if isUser {
                        Text(entry.text).font(DS.font(DS.Size.body)).foregroundStyle(Theme.ink)
                    } else {
                        MarkdownView(source: entry.text, baseFontSize: 13)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .fill(isUser ? Theme.accent.opacity(0.12) : Theme.fill1))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous)
                .strokeBorder(isUser ? Theme.accent.opacity(0.25) : Theme.line, lineWidth: 0.8))
        }
    }
}
