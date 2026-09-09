import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, voice, apps, google, coding, keys, permissions, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .apps: return "Apps"
        case .google: return "Google"
        case .coding: return "Coding"
        case .keys: return "Keys"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .voice: return "waveform"
        case .apps: return "square.grid.2x2.fill"
        case .google: return "globe"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .keys: return "key.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
    var item: SidebarItem { SidebarItem(id: rawValue, label: label, icon: icon) }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var page: String = SettingsPage.general.rawValue
}

/// The Settings window: dark glass, left sidebar, 760×560.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var closeObserver: Any?
    private let permissions = PermissionsModel()

    func show(page: SettingsPage? = nil) {
        if let page { SettingsNavigation.shared.page = page.rawValue }
        if window == nil {
            let root = SettingsRootView(nav: SettingsNavigation.shared, settings: Settings.shared,
                                        permissions: permissions, preview: VoicePreview.shared)
            let w = DarkWindow.make(title: "Avo", size: NSSize(width: 760, height: 560), content: root)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.permissions.stop()
                    VoicePreview.shared.stop()
                }
            }
            window = w
        }
        DarkWindow.present(window!)
    }
}

struct SettingsRootView: View {
    @ObservedObject var nav: SettingsNavigation
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var preview: VoicePreview
    @StateObject private var tools = ToolGroupsModel()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(items: SettingsPage.allCases.map(\.item), selection: $nav.page) {
                HStack(spacing: 8) {
                    AvoMark(size: 26)
                    Text("Avo").font(DS.font(15, .semibold)).foregroundStyle(Theme.ink).tracking(-0.2)
                }
            }
            ScrollView(.vertical) {
                page
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.pagePadding)
                    .padding(.top, 36)
                    .padding(.bottom, DS.pagePadding)
            }
            .scrollIndicators(.automatic)
            .id(nav.page)
            .transition(.opacity)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder private var page: some View {
        switch SettingsPage(rawValue: nav.page) ?? .general {
        case .general: GeneralPage(s: settings)
        case .voice: VoicePage(s: settings, preview: preview)
        case .apps: AppsPage(model: tools)
        case .google: GooglePage()
        case .coding: CodingPage(s: settings)
        case .keys: KeysPage()
        case .permissions: PermissionsPage(model: permissions)
        case .about: AboutPage(s: settings)
        }
    }
}
