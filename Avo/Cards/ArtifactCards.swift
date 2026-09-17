import SwiftUI
import AppKit

/// Table, JSON tree, code, markdown document, or chart produced by a `present_*` tool.
struct ArtifactCardView: View {
    var card: ArtifactCard
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppTile(icon: card.icon, tint: Theme.accent, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(Theme.text(14, .semibold)).foregroundStyle(Theme.ink)
                    if let s = card.subtitle, !s.isEmpty {
                        Text(s).font(Theme.text(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(card.kindLabel)
                    .font(Theme.text(10, .semibold))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.fill2, in: Capsule())
                Button(action: copy) {
                    Text(copied ? "Copied" : "Copy")
                        .font(Theme.text(11, .semibold))
                        .foregroundStyle(copied ? Theme.good : Theme.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.fill2, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy artifact")
            }

            switch card.kind {
            case .table:
                if let table = card.table {
                    MarkdownTableView(headers: table.columns, rows: table.rows,
                                      alignments: Array(repeating: .left, count: table.columns.count),
                                      fontSize: 12)
                }
            case .json:
                if let node = JSONNode.parse(text: card.body) {
                    JSONTreeView(node: node, name: nil, depth: 0)
                } else {
                    CodeBlockView(language: "json", code: card.body)
                }
            case .code:
                CodeBlockView(language: card.language, code: card.body)
            case .markdown:
                MarkdownView(source: card.body, baseFontSize: 13)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .chart:
                ArtifactChartView(kind: card.chartKind, items: card.chartItems)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.copyText, forType: .string)
        copied = true
        Sounds.shared.play(.tick)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

struct JSONTreeView: View {
    var node: JSONNode
    var name: String?
    var depth: Int
    @State private var expanded: Bool

    init(node: JSONNode, name: String?, depth: Int) {
        self.node = node
        self.name = name
        self.depth = depth
        _expanded = State(initialValue: depth < 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if node.isContainer {
                    Button {
                        withAnimation(Theme.springQuick) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 10, height: 8)
                }
                if let name {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(":")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.ink4)
                }
                if !node.isContainer || !expanded {
                    Text(leaf)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(leafColor)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? 8 : 1)
                }
            }
            if expanded {
                switch node {
                case .object(let pairs):
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        JSONTreeView(node: pair.1, name: pair.0, depth: depth + 1)
                    }
                    .padding(.leading, 14)
                case .array(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { i, child in
                        JSONTreeView(node: child, name: "\(i)", depth: depth + 1)
                    }
                    .padding(.leading, 14)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var leaf: String {
        switch node {
        case .string(let s): return "“\(s)”"
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return node.preview
        }
    }

    private var leafColor: Color {
        switch node {
        case .string: return Color(red: 0.55, green: 0.86, blue: 0.62)
        case .number: return Color(red: 1.0, green: 0.72, blue: 0.38)
        case .bool: return Color(red: 0.78, green: 0.55, blue: 1.0)
        case .null: return Theme.ink3
        case .object, .array: return Theme.ink2
        }
    }
}

struct ArtifactChartView: View {
    var kind: ArtifactCard.ChartKind
    var items: [ArtifactCard.ChartItem]

    var body: some View {
        switch kind {
        case .stats:
            HStack(spacing: 14) {
                ForEach(items.prefix(4)) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(short(s.value)).font(Theme.font(22, .semibold)).foregroundStyle(Theme.ink)
                        Text(s.label).font(Theme.text(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                    if s.id != items.prefix(4).last?.id { Spacer(minLength: 0) }
                }
            }
        case .bars:
            let maxV = items.map(\.value).max() ?? 1
            VStack(spacing: 7) {
                ForEach(items) { it in
                    HStack(spacing: 8) {
                        Text(it.label).font(Theme.text(11)).foregroundStyle(Theme.ink3)
                            .frame(width: 72, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            Capsule().fill(Theme.fill2).overlay(alignment: .leading) {
                                Capsule().fill(Theme.accent)
                                    .frame(width: g.size.width * CGFloat(maxV > 0 ? it.value / maxV : 0))
                            }
                        }
                        .frame(height: 8)
                        Text(short(it.value)).font(Theme.text(11, .medium)).foregroundStyle(Theme.ink2)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        case .line:
            ArtifactLineChart(items: items)
                .frame(height: 120)
        }
    }

    private func short(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
    }
}

struct ArtifactLineChart: View {
    var items: [ArtifactCard.ChartItem]

    var body: some View {
        GeometryReader { g in
            let maxV = max(items.map(\.value).max() ?? 1, 0.0001)
            let minV = min(items.map(\.value).min() ?? 0, 0)
            let span = max(maxV - minV, 0.0001)
            let pts: [CGPoint] = items.enumerated().map { i, it in
                let x = items.count == 1 ? g.size.width / 2
                    : CGFloat(i) / CGFloat(items.count - 1) * g.size.width
                let y = g.size.height - CGFloat((it.value - minV) / span) * (g.size.height - 16) - 8
                return CGPoint(x: x, y: y)
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    for pt in pts { p.addLine(to: pt) }
                    if let last = pts.last {
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    }
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                    Circle().fill(Theme.ink).frame(width: 5, height: 5).position(pt)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.2).frame(width: 5, height: 5).position(pt))
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            HStack {
                ForEach(items) { it in
                    Text(it.label).font(Theme.text(10)).foregroundStyle(Theme.ink3).lineLimit(1)
                    if it.id != items.last?.id { Spacer(minLength: 0) }
                }
            }
        }
    }
}
