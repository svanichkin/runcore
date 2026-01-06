import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case status = "Status"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .status: "info.circle"
        }
    }
}

private enum SettingsDestination: Hashable, Identifiable {
    case profile
    case section(SettingsSection)

    var id: String {
        switch self {
        case .profile:
            return "profile"
        case .section(let s):
            return "section:\(s.id)"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: (() -> Void)?
    @State private var selection: SettingsDestination?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        NavigationSplitView {
            settingsList
        } detail: {
            NavigationStack {
                SettingsDetail(destination: selection)
                    .environmentObject(store)
            }
            .navigationDestination(for: SettingsDestination.self) { dest in
                SettingsDetail(destination: dest)
                    .environmentObject(store)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // On Mac Catalyst, SwiftUI may still inject a sidebar toggle into the titlebar.
            // Overriding the navigation placement removes the button.
            ToolbarItem(placement: .navigation) { EmptyView() }
        }
        .background(SidebarToggleHider())
    }

    private var settingsList: some View {
        List(selection: $selection) {
            Section {
                NavigationLink(value: SettingsDestination.profile) {
                    ProfileRow(
                        profileName: store.profileName,
                        avatarData: store.profileAvatarData,
                        configuredInterfaces: store.configuredInterfaces,
                        runtimeInterfaces: store.interfaceStats.interfaces
                    )
                }
                .tag(SettingsDestination.profile)
            }

            Section {
                ForEach(SettingsSection.allCases) { section in
                    let dest = SettingsDestination.section(section)
                    NavigationLink(value: dest) {
                        Label(section.rawValue, systemImage: section.systemImage)
                    }
                    .tag(dest)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { dest in
            SettingsDetail(destination: dest)
                .environmentObject(store)
        }
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        if !letters.isEmpty { return letters.joined() }
        return "ME"
    }
}

private struct SettingsDetail: View {
    @EnvironmentObject private var store: AppStore
    let destination: SettingsDestination?

    var body: some View {
        switch destination {
        case .profile:
            ProfileDetailView()
                .environmentObject(store)
        case .section(let section):
            switch section {
            case .status:
                StatusView()
                    .environmentObject(store)
            }
        case nil:
            Text("Select an item")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProfileRow: View {
    let profileName: String
    let avatarData: Data?
    let configuredInterfaces: [ConfiguredInterface]
    let runtimeInterfaces: [InterfaceStatsSnapshot.InterfaceEntry]

    var body: some View {
        HStack(spacing: 14) {
            RoundedSquareAvatarView(avatarData: avatarData, name: profileName, cornerRadius: 18)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(profileName.isEmpty ? "Me" : profileName)
                    .font(.headline)
                    .lineLimit(1)

                interfaceIndicators
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var interfaceIndicators: some View {
        let enabled = configuredInterfaces.filter { $0.enabled }
        return HStack(spacing: 6) {
            if enabled.isEmpty {
                Text("No enabled interfaces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(enabled.prefix(8)) { cfg in
                    let state = interfaceState(for: cfg)
                    ZStack {
                        Circle()
                            .fill(state.color)
                            .frame(width: 36, height: 36)
                        Image(systemName: iconName(for: cfg))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityLabel(Text("\(cfg.name): \(state.label)"))
                }
                if enabled.count > 8 {
                    Text("+\(enabled.count - 8)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct IndicatorState {
        let label: String
        let color: Color
    }

    private func interfaceState(for cfg: ConfiguredInterface) -> IndicatorState {
        if let runtime = runtimeInterfaces.first(where: { $0.short_name == cfg.name || $0.name == cfg.name }) {
            if runtime.status == true {
                return IndicatorState(label: "Online", color: .green)
            }
            return IndicatorState(label: "Offline", color: .secondary.opacity(0.6))
        }
        // Enabled in config, but no runtime interface yet -> treat as error.
        return IndicatorState(label: "Error", color: .red)
    }

    private func iconName(for cfg: ConfiguredInterface) -> String {
        let t = (cfg.type ?? "").lowercased()
        if t.contains("ble") {
            return "bolt.horizontal"
        }
        if t.contains("tcp") || t.contains("udp") || t.contains("weave") {
            return "network"
        }
        if t.contains("serial") || t.contains("rnode") {
            return "cable.connector"
        }
        if t.contains("auto") {
            return "antenna.radiowaves.left.and.right"
        }
        return "circle"
    }
}

private struct ProfileDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft: String = ""
    @State private var lastSavedName: String = ""

    var body: some View {
        ProfileEditorList(
            nameDraft: $nameDraft,
            namePlaceholder: "Your name",
            identifier: store.destinationHashHex,
            onCopyIdentifier: {
                UIPasteboard.general.string = store.destinationHashHex
                store.appendLog("copied dest hash")
            },
            avatar: {
                avatarPicker
            }
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }

            if isDirty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        saveIfNeeded()
                    }
                }
            }
        }
        .onAppear {
            nameDraft = store.profileName
            lastSavedName = store.profileName
        }
    }

    @ViewBuilder
    private var avatarPicker: some View {
        AvatarPicker(
            avatarData: store.profileAvatarData,
            name: store.profileName,
            maxSide: 280,
            cornerRadius: 18,
            onAvatarData: { data in
                store.setProfileAvatarData(data)
                store.appendLog("avatar updated")
            }
        )
    }

    private var isDirty: Bool {
        nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != lastSavedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveIfNeeded() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? "Me" : trimmed
        store.profileName = newName
        store.persist()
        store.restartEngineSilently()
        lastSavedName = newName
    }
}

private struct StatusView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showFixAlert = false
    @State private var fixError: String?
    @State private var isToggling: Set<String> = []

    var body: some View {
        List {
            Section("Interfaces") {
                if store.configuredInterfaces.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No interfaces")
                            .foregroundStyle(.secondary)
                        Text("If you just launched the app, wait a second or pull to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let apiError = store.lastConfiguredInterfacesError, !apiError.isEmpty {
                            Text("Engine: \(apiError)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if apiError.localizedCaseInsensitiveContains("shared instance") {
                                Button("Fix: Reset RNS config to defaults") {
                                    do {
                                        try store.resetConfig(.rns)
                                        showFixAlert = true
                                        fixError = nil
                                    } catch {
                                        showFixAlert = true
                                        fixError = String(describing: error)
                                    }
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                Text("After reset, fully quit and reopen the app to apply.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let err = store.lastConfiguredInterfacesError, !err.isEmpty {
                            Text("Parse error: \(err)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !store.lastConfiguredInterfacesJSON.isEmpty {
                            Text(store.lastConfiguredInterfacesJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                } else {
                    ForEach(store.configuredInterfaces) { cfg in
                        let runtime = store.interfaceStats.interfaces.first(where: { $0.short_name == cfg.name })
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(cfg.name)
                                    .font(.headline)
                                Spacer(minLength: 0)
                                if cfg.enabled {
                                    Text((runtime?.status ?? false) ? "Online" : "Offline")
                                        .font(.caption)
                                        .foregroundStyle((runtime?.status ?? false) ? .green : .secondary)
                                } else {
                                    Text("Disabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 12) {
                                Text(cfg.type ?? runtime?.type ?? "Unknown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Toggle("", isOn: Binding(
                                    get: { cfg.enabled },
                                    set: { newValue in
                                        Task { @MainActor in
                                            isToggling.insert(cfg.name)
                                            store.setInterfaceEnabled(name: cfg.name, enabled: newValue)
                                            isToggling.remove(cfg.name)
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .disabled(isToggling.contains(cfg.name))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                NavigationLink {
                    AnnouncesView()
                        .environmentObject(store)
                } label: {
                    Text("Announces")
                }
                NavigationLink {
                    ConfigView()
                        .environmentObject(store)
                } label: {
                    Text("Configurations")
                }
                NavigationLink {
                    LogsView()
                        .environmentObject(store)
                } label: {
                    Text("Logs")
                }
            }
        }
        .navigationTitle("Status")
        .task {
            store.refreshInterfaceStats()
            store.refreshConfiguredInterfaces()
            store.refreshAnnounces()
        }
        .refreshable {
            store.refreshInterfaceStats()
            store.refreshConfiguredInterfaces()
            store.refreshAnnounces()
        }
        .alert(isPresented: $showFixAlert) {
            if let fixError {
                Alert(title: Text("Reset failed"), message: Text(fixError), dismissButton: .default(Text("OK")))
            } else {
                Alert(title: Text("RNS config reset"), message: Text("Now fully quit and reopen the app."), dismissButton: .default(Text("OK")))
            }
        }
    }
}

private struct AnnouncesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Announces") {
                if store.announces.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No announces")
                            .foregroundStyle(.secondary)
                        Text("If you just launched the app, wait a second or pull to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let err = store.lastAnnouncesError, !err.isEmpty {
                            Text("Parse error: \(err)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !store.lastAnnouncesJSON.isEmpty {
                            Text(store.lastAnnouncesJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(8)
                        }
                    }
                } else {
                    ForEach(store.announces) { entry in
                        let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name.isEmpty ? "Unknown" : name)
                                .font(.headline)
                            Text(entry.destinationHashHex)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("Last seen \(timeString(from: entry.lastSeen))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Announces")
        .task {
            store.refreshAnnounces()
        }
        .refreshable {
            store.refreshAnnounces()
        }
    }

    private func timeString(from unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct LogsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section {
                Toggle("Debug logging", isOn: Binding(
                    get: { store.debugLoggingEnabled },
                    set: { store.setDebugLoggingEnabled($0) }
                ))
            } footer: {
                Text("Enables verbose Reticulum logs (level 6). Use this to debug network/discovery issues.")
            }

            ForEach(store.logs.reversed(), id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Copy All") {
                    UIPasteboard.general.string = store.logs.joined(separator: "\n")
                    store.appendLog("logs copied")
                }
            }
        }
    }
}

private struct ConfigView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("Configurations") {
                NavigationLink {
                    ConfigEditorView(kind: .runcore)
                        .environmentObject(store)
                } label: {
                    Text("LXMF")
                }

                NavigationLink {
                    ConfigEditorView(kind: .rns)
                        .environmentObject(store)
                } label: {
                    Text("RNS")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Configurations")
    }
}

private struct ConfigEditorView: View {
    @EnvironmentObject private var store: AppStore
    let kind: AppStore.ConfigKind

    @State private var draft: String = ""
    @State private var baseline: String = ""
    @State private var showResetConfirm = false
    @State private var errorMessage: String?

    private var title: String { kind == .runcore ? "LXMF" : "RNS" }

    private var hasChanges: Bool {
        normalizeConfigText(draft) != normalizeConfigText(baseline)
    }

    var body: some View {
        TextEditor(text: $draft)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if hasChanges {
                        Button("Reset") {
                            showResetConfirm = true
                        }
                        Button("Save") {
                            do {
                                try store.saveConfigText(kind, text: draft)
                                let loaded = store.loadConfigText(kind)
                                let effective = loaded.isEmpty ? store.defaultConfigText(kind) : loaded
                                draft = effective
                                baseline = effective
                                store.restartEngineSilently()
                            } catch {
                                errorMessage = String(describing: error)
                            }
                        }
                        .keyboardShortcut("s", modifiers: [.command])
                    }
                }
            }
            .confirmationDialog(
                "Reset config to defaults?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    do {
                        try store.resetConfig(kind)
                        let loaded = store.loadConfigText(kind)
                        let effective = loaded.isEmpty ? store.defaultConfigText(kind) : loaded
                        draft = effective
                        baseline = effective
                        store.restartEngineSilently()
                    } catch {
                        errorMessage = String(describing: error)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if baseline.isEmpty && draft.isEmpty {
                    let loaded = store.loadConfigText(kind)
                    let effective = loaded.isEmpty ? store.defaultConfigText(kind) : loaded
                    draft = effective
                    baseline = effective
                }
            }
    }

    private func normalizeConfigText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
