import AppKit
import SwiftUI

/// Settings → Apps → MCP servers. Reads and writes `mcp.json` directly; the file stays the source of
/// truth, so a server added by hand and one added here are the same thing.
@MainActor
final class MCPServersModel: ObservableObject {
    typealias Entry = MCPConfigFile.Server

    @Published private(set) var entries: [Entry] = []
    @Published var parseError: String?
    @Published var restarting = false
    @Published var message: String?

    init() { reload() }

    var configPath: String { GeneralPage.shortPath(MCPServers.configURL.path) }

    func reload() {
        parseError = nil
        do {
            entries = try MCPConfigFile.parse(try? Data(contentsOf: MCPServers.configURL))
        } catch {
            entries = []
            parseError = "\(error)"
        }
    }

    func toolCount(_ name: String) -> Int? { MCPServers.shared.toolCounts[name] }
    func error(_ name: String) -> String? { MCPServers.shared.errors[name] }

    /// Adds or replaces one server. Returns an error message, or nil on success.
    func save(_ entry: Entry) -> String? { write { try MCPConfigFile.upsert(entry, into: $0) } }

    func remove(_ name: String) -> String? {
        let failure = write { try MCPConfigFile.remove(name, from: $0) }
        if failure == nil { retire(name) }
        return failure
    }

    func setDisabled(_ name: String, _ disabled: Bool) -> String? {
        let failure = write { try MCPConfigFile.setDisabled(name, disabled, in: $0) }
        guard failure == nil else { return failure }
        if disabled {
            retire(name)
        } else {
            // Back on, but its tools were never listed. Only a discovery pass can put them back.
            restart()
        }
        return nil
    }

    /// Takes one server out of service after its row was removed or switched off. All three steps
    /// matter: writing the file alone left the tools in the registry and the process running, so the
    /// model could still call `mcp_<name>_*` — and `client(for:)` would have found the stale config
    /// and started the server again to serve that call.
    private func retire(_ name: String) {
        ToolRegistry.shared.unregister(group: MCPTool.group(for: name))
        MCPServers.shared.loadConfig()
        Task { await MCPServers.shared.shutdown(name) }
    }

    /// Stops every running server, re-reads mcp.json, starts them again, and swaps the MCP tools in
    /// the registry for the new set — so a removed server's tools go away, and an edited server is
    /// a new process rather than the old one answering `tools/list` again.
    func restart() {
        guard !restarting else { return }
        restarting = true
        message = nil
        Task {
            // Every exit resets the flag: a server that hangs or throws inside this pass must not
            // leave the button disabled for the rest of the session.
            defer { restarting = false }
            ToolRegistry.shared.unregister(groupPrefix: "MCP")
            await MCPServers.shared.shutdownAll()
            let tools = await MCPTools.all()
            ToolRegistry.shared.register(tools)
            reload()
            message = "\(entries.filter { !$0.disabled }.count) server(s), \(max(0, tools.count - 1)) tool(s)."
        }
    }

    /// Runs one edit against the file on disk and writes the result back atomically.
    private func write(_ edit: (Data?) throws -> Data) -> String? {
        do {
            let data = try edit(try? Data(contentsOf: MCPServers.configURL))
            try FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            try data.write(to: MCPServers.configURL, options: .atomic)
        } catch let e as MCPConfigFile.Failure {
            return e.description
        } catch {
            return error.localizedDescription
        }
        reload()
        return nil
    }
}

struct MCPServersSection: View {
    @ObservedObject var model: MCPServersModel
    @State private var adding = false
    @State private var draft = MCPServersModel.Entry(name: "", command: "", args: "", url: "", headers: "", disabled: false)
    @State private var formError: String?

    private var footer: String? {
        model.parseError ?? formError ?? model.message ?? "Stored in \(model.configPath). Servers start on demand and stop after ten minutes idle."
    }

    var body: some View {
        SectionCard(title: "MCP servers", footer: footer) {
            if model.entries.isEmpty && !adding {
                ActionRow(title: "No servers yet",
                          subtitle: "Add a stdio command or an HTTP endpoint and its tools join the list above.",
                          icon: MCPServers.icon) {
                    DSPill("Add server…", icon: "plus", style: .primary) { startAdding() }
                }
            } else {
                for entry in model.entries { AnyView(row(entry)) }
                if !adding {
                    ActionRow(title: "Add a server", subtitle: "stdio command, or a streamable-HTTP URL.") {
                        DSPill("Add server…", icon: "plus") { startAdding() }
                    }
                }
            }
            if adding { form }
            ActionRow(title: "Restart servers", subtitle: "Re-reads the file, restarts every server and reloads its tools.") {
                DSPill("Restart", icon: "arrow.clockwise", busy: model.restarting) { model.restart() }
            }
        }
    }

    private func row(_ entry: MCPServersModel.Entry) -> some View {
        ActionRow(title: entry.name, subtitle: subtitle(entry), icon: MCPServers.icon) {
            Text(entry.transport).font(DS.font(DS.Size.label, .semibold)).foregroundStyle(Theme.ink2)
                .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                .background(Capsule().fill(Theme.fill2))
            Toggle("", isOn: Binding(get: { !entry.disabled },
                                     set: { on in formError = model.setDisabled(entry.name, !on) }))
                .labelsHidden().toggleStyle(DSToggleStyle())
            DSPill("Remove", style: .destructive) { formError = model.remove(entry.name) }
        }
    }

    private func subtitle(_ entry: MCPServersModel.Entry) -> String {
        if let e = model.error(entry.name) { return e }
        if entry.disabled { return "Off · \(entry.detail)" }
        if let n = model.toolCount(entry.name) { return "\(n) tool\(n == 1 ? "" : "s") · \(entry.detail)" }
        return entry.detail
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            RowLabel(title: "New server", subtitle: "Fill the command for a local stdio server, or the URL for a remote one.")
            HStack(spacing: DS.Space.s) {
                Text("Name").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).frame(width: 64, alignment: .leading)
                DSTextField(placeholder: "linear", text: $draft.name)
            }
            HStack(spacing: DS.Space.s) {
                Text("Command").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).frame(width: 64, alignment: .leading)
                DSTextField(placeholder: "npx", text: $draft.command, mono: true)
                DSTextField(placeholder: "-y some-mcp-server", text: $draft.args, mono: true)
            }
            HStack(spacing: DS.Space.s) {
                Text("URL").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).frame(width: 64, alignment: .leading)
                DSTextField(placeholder: "https://example.com/mcp", text: $draft.url, mono: true)
            }
            HStack(alignment: .top, spacing: DS.Space.s) {
                Text("Headers").font(DS.font(DS.Size.caption)).foregroundStyle(Theme.ink3).frame(width: 64, alignment: .leading)
                    .padding(.top, DS.Space.s)
                DSTextEditor(text: $draft.headers, height: 56)
            }
            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                DSPill("Cancel", style: .ghost) { adding = false; formError = nil }
                DSPill("Add", icon: "checkmark", style: .primary) { commit() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func startAdding() {
        draft = MCPServersModel.Entry(name: "", command: "", args: "", url: "", headers: "", disabled: false)
        formError = nil
        withAnimation(Theme.springQuick) { adding = true }
    }

    private func commit() {
        if let e = model.save(draft) { formError = e; Sounds.shared.play(.error); return }
        formError = nil
        withAnimation(Theme.springQuick) { adding = false }
        Sounds.shared.play(.done)
        model.restart()
    }
}
