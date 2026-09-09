import SwiftUI
import AppKit

/// Root view of the side-notch panel: the slim edge tab when idle, the glass panel when out.
struct SideNotchRoot: View {
    @ObservedObject var model: SideNotchModel
    @ObservedObject private var history = History.shared
    let controller: SideNotch

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SideNotchPanelBody(model: model, history: history, controller: controller)
                .offset(x: model.out ? 0 : SideNotch.panelWidth + 24)
                .opacity(model.out ? 1 : 0)
            SideNotchTab(model: model)
                .opacity(model.out ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .contentShape(Rectangle())
        .onHover { h in controller.setHovered(h) }
        .animation(model.out ? Theme.springOpen : Theme.springClose, value: model.out)
    }
}

/// 6 × 64 tab hugging the right screen edge. Accent while working, amber while a task needs input.
struct SideNotchTab: View {
    @ObservedObject var model: SideNotchModel
    @State private var pulse = false
    private var color: Color { model.needsInput ? Theme.warn : (model.anyRunning ? Theme.accent : Color.white.opacity(0.28)) }
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
            .fill(color)
            .frame(width: SideNotch.tabWidth, height: SideNotch.tabHeight)
            .opacity(model.anyRunning ? (pulse ? 1 : 0.45) : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

/// The glass panel. Rounded only on the screen-side (left) edge.
struct SideNotchPanelBody: View {
    @ObservedObject var model: SideNotchModel
    @ObservedObject var history: History
    let controller: SideNotch

    private var chats: [History.Chat] { history.chats(limit: 20) }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: SideNotch.cornerRadius, bottomLeadingRadius: SideNotch.cornerRadius,
                               bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if model.tab == .tasks { tasks } else { chatList }
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 14)
            .background(GeometryReader { g in Color.clear.preference(key: SideNotchSizeKey.self, value: g.size.height) })
            .animation(Theme.springCard, value: model.working.map(\.id))
            .animation(Theme.springCard, value: model.done.map(\.id))
            .animation(Theme.springQuick, value: model.tab)
        }
        .onPreferenceChange(SideNotchSizeKey.self) { h in controller.contentHeightChanged(h) }
        .frame(width: SideNotch.panelWidth)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow, blending: .behindWindow)
                Theme.glass.opacity(0.84)
                LinearGradient(colors: [Color.white.opacity(0.05), .clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
        )
        .overlay(
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        )
        .foregroundStyle(Theme.ink)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SideTabs(tab: $model.tab, tasksBadge: model.working.count, chatsBadge: nil)
            Spacer()
            Button { controller.retract() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                    .frame(width: 20, height: 20).background(Theme.fill1, in: Circle())
            }.buttonStyle(.plain).help("Hide (esc)")
        }
    }

    @ViewBuilder private var tasks: some View {
        if !model.working.isEmpty {
            SideSectionLabel(text: "Running", count: model.working.count)
            ForEach(model.working) { t in
                WorkingRow(task: t, expanded: model.expandedId == t.id, controller: controller)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        if !model.done.isEmpty {
            HStack {
                SideSectionLabel(text: "Done", count: nil)
                Button("Clear") { controller.clearDone() }
                    .buttonStyle(.plain).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink3)
            }
            VStack(spacing: 2) {
                ForEach(model.done) { t in
                    DoneRow(task: t, expanded: model.expandedId == t.id, controller: controller)
                        .transition(.opacity)
                }
            }
        }
        if model.working.isEmpty && model.done.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing running.").font(Theme.text(13, .medium)).foregroundStyle(Theme.ink2)
                Text("Say “have Claude…” or “have Codex…” to start a task. Tasks show here while they run and after they finish.")
                    .font(Theme.text(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4).padding(.top, 6)
        }
    }

    @ViewBuilder private var chatList: some View {
        if chats.isEmpty {
            Text("No chats yet.").font(Theme.text(12)).foregroundStyle(Theme.ink3).padding(.horizontal, 4)
        } else {
            VStack(spacing: 0) {
                ForEach(chats) { chat in
                    ChatRow(chat: chat) { controller.reopen(chat) }
                    if chat.id != chats.last?.id { Divider().overlay(Theme.line) }
                }
            }
        }
    }
}

/// Tasks | Chats segmented control.
struct SideTabs: View {
    @Binding var tab: SideNotchModel.Tab
    var tasksBadge: Int
    var chatsBadge: Int?
    var body: some View {
        HStack(spacing: 2) {
            seg("Tasks", .tasks, badge: tasksBadge)
            seg("Chats", .chats, badge: chatsBadge ?? 0)
        }
        .padding(2)
        .background(Theme.fill1, in: Capsule())
    }
    private func seg(_ label: String, _ t: SideNotchModel.Tab, badge: Int) -> some View {
        Button { withAnimation(Theme.springQuick) { tab = t } } label: {
            HStack(spacing: 5) {
                Text(label).font(Theme.text(12, .semibold))
                if badge > 0 { Text("\(badge)").font(Theme.text(10, .bold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(Theme.accent, in: Capsule()) }
            }
            .foregroundStyle(tab == t ? Theme.ink : Theme.ink3)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tab == t ? Theme.fill2 : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct SideSectionLabel: View {
    var text: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).tracking(0.7)
            if let c = count { Text("\(c)").font(Theme.text(10, .semibold)).foregroundStyle(Theme.ink3).padding(.horizontal, 5).padding(.vertical, 1).background(Theme.fill2, in: Capsule()) }
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Working

struct WorkingRow: View {
    var task: CodingTask
    var expanded: Bool
    let controller: SideNotch
    @State private var reply = ""
    private var waiting: Bool { task.status == "waiting" }
    private var tint: Color { task.agent == "codex" ? CardBrand.codex : CardBrand.claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                AppTile(icon: task.agent == "codex" ? CodingTools.codexIcon : CodingTools.claudeIcon, tint: tint, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(Theme.text(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                    Text("\(task.agentLabel) · \(task.projectName)").font(Theme.text(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(task.createdAt, style: .timer).font(Theme.text(11, .medium).monospacedDigit()).foregroundStyle(Theme.ink3)
                    if waiting { NeedsInputBadge() }
                }
            }
            if waiting, let q = task.activity.last {
                Text(q).font(Theme.text(12)).foregroundStyle(Theme.warn).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(task.activity.last ?? "Starting…")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink2).lineLimit(expanded ? 3 : 1)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(task.activity.suffix(14).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if waiting || expanded {
                SideReplyField(placeholder: waiting ? "Answer…" : "Tell it something…", text: $reply) {
                    controller.reply(task.id, reply); reply = ""
                }
            }
            HStack(spacing: 6) {
                ModelChip(agent: task.agent, model: task.model, effort: task.effort) { m, e in controller.switchModel(task.id, model: m, effort: e) }
                    .scaleEffect(0.92, anchor: .leading)
                Spacer()
                SideSmallPill(label: "Open") { controller.open(task.id) }
                SideSmallPill(label: "Stop") { controller.stop(task.id) }
            }
        }
        .padding(10)
        .background(Theme.fill1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(waiting ? Theme.warn.opacity(0.5) : Theme.line, lineWidth: 0.8))
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleExpanded(task.id) }
    }
}

/// Amber pill that breathes while a permission or question is waiting.
struct NeedsInputBadge: View {
    @State private var pulse = false
    var body: some View {
        Text("Needs input").font(Theme.text(10, .semibold)).foregroundStyle(Theme.warn)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.warn.opacity(pulse ? 0.3 : 0.12), in: Capsule())
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct SideReplyField: View {
    var placeholder: String
    @Binding var text: String
    var send: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(Theme.text(12.5))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.fill1, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.8))
                .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { send() } }
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(text.isEmpty ? Theme.ink4 : Theme.accent, in: Circle())
            }.buttonStyle(.plain).disabled(text.isEmpty)
        }
    }
}

// MARK: - Done

struct DoneRow: View {
    var task: CodingTask
    var expanded: Bool
    let controller: SideNotch
    @State private var reply = ""
    @State private var hover = false
    private var ok: Bool { task.status == "done" }
    private var color: Color { ok ? Theme.good : (task.status == "stopped" ? Theme.ink3 : Theme.bad) }
    private var preview: String {
        let r = (task.result ?? "").markdownStripped
        return r.isEmpty ? (ok ? "Finished." : task.status.capitalized) : r
    }
    private static let rel: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; f.dateTimeStyle = .named; return f }()
    private var when: String {
        let f = task.finishedAt ?? task.createdAt
        if Date().timeIntervalSince(f) < 60 { return "just now" }
        return Self.rel.localizedString(for: f, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(task.title).font(Theme.text(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text(when).font(Theme.text(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                if hover || expanded {
                    Button { controller.dismiss(task.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
                            .frame(width: 16, height: 16).background(Theme.fill2, in: Circle())
                    }.buttonStyle(.plain).help("Dismiss")
                }
            }
            if expanded {
                MarkdownView(source: task.result ?? preview, baseFontSize: 12).lineLimit(30).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
                SideReplyField(placeholder: "Follow up…", text: $reply) { controller.reply(task.id, reply); reply = "" }
                    .padding(.leading, 14)
                HStack(spacing: 6) {
                    ModelChip(agent: task.agent, model: task.model, effort: task.effort) { m, e in controller.switchModel(task.id, model: m, effort: e) }
                        .scaleEffect(0.92, anchor: .leading)
                    Spacer()
                    SideSmallPill(label: "Open") { controller.open(task.id) }
                    SideSmallPill(label: "Folder") { controller.openFolder(task.id) }
                }
                .padding(.leading, 14)
            } else {
                Text(preview).font(Theme.text(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(hover || expanded ? Theme.fill1 : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleExpanded(task.id) }
        .onHover { h in withAnimation(Theme.springQuick) { hover = h } }
    }
}

// MARK: - Earlier

struct ChatRow: View {
    var chat: History.Chat
    var action: () -> Void
    @State private var hover = false
    private static let rel: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    private var meta: String {
        let when = Self.rel.localizedString(for: chat.lastAt, relativeTo: Date())
        let n = chat.turnCount
        return n == 1 ? when : "\(n) turns · \(when)"
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(Theme.text(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(meta).font(Theme.text(11)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(hover ? Theme.fill1 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.springQuick) { hover = h } }
    }
}

// MARK: - Bits

struct SideSmallPill: View {
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.text(11, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.fill2, in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct SideNotchSizeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
