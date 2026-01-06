import SwiftUI
import UIKit

struct AddContactView: View {
    @State private var destinationHashHex = ""
    @State private var isResolvingName = false
    @State private var resolvedName: String = ""
    @State private var resolvedAvatarData: Data?
    @State private var resolveTask: Task<Void, Never>?

    let onCancel: () -> Void
    let onAdd: (_ displayName: String, _ destinationHashHex: String) -> Void
    let resolvePreview: ((_ destinationHashHex: String) async -> ContactPreview?)?
    let announces: [AnnounceEntry]

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Destination hash (hex)", text: $destinationHashHex)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                }
                Section("Preview") {
                    HStack {
                        Text("Name")
                        Spacer(minLength: 12)
                        Text(resolvedName.isEmpty ? "Unknown" : resolvedName)
                            .foregroundStyle(resolvedName.isEmpty ? .secondary : .primary)
                    }
                    HStack {
                        Spacer()
                        AddContactAvatarCircle(avatarData: resolvedAvatarData, name: resolvedName.isEmpty ? destinationHashHex : resolvedName)
                            .frame(width: 96, height: 96)
                        Spacer()
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dest = destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(name, dest)
                    }
                    .disabled(destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay(alignment: .bottom) {
                if isResolvingName {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Resolving preview…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                }
            }
        }
        .onChange(of: destinationHashHex) { _ in
            schedulePreviewResolveIfNeeded()
        }
        .onDisappear {
            resolveTask?.cancel()
            resolveTask = nil
        }
    }

    private func schedulePreviewResolveIfNeeded() {
        resolvedName = ""
        resolvedAvatarData = nil
        isResolvingName = false
        resolveTask?.cancel()
        resolveTask = nil

        guard let resolvePreview else { return }

        let dest = destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidDestinationHashHex(dest) else { return }

        applyAnnouncedName(for: dest)

        resolveTask = Task { @MainActor in
            isResolvingName = true
            defer { isResolvingName = false }

            // Debounce typing/pasting so we don't spam the network.
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }

            // If user changed the value again, abort.
            let currentDest = destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if currentDest != dest { return }

            let preview = await resolvePreview(dest)
            if Task.isCancelled { return }

            resolvedName = preview?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            resolvedAvatarData = preview?.avatarData
        }
    }

    private func isValidDestinationHashHex(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: // 0-9 A-F a-f
                return true
            default:
                return false
            }
        }
    }

    private func applyAnnouncedName(for dest: String) {
        guard resolvedName.isEmpty else { return }
        guard let entry = announces.first(where: { $0.destinationHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == dest }) else {
            return
        }
        let trimmed = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        resolvedName = trimmed
    }
}

private struct AddContactAvatarCircle: View {
    let avatarData: Data?
    let name: String

    var body: some View {
        Group {
            if let avatarData, let uiImage = UIImage(data: avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                    .overlay(Text(initials(from: name)).font(.headline))
            }
        }
        .clipShape(Circle())
    }

    private func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "?" }
        let parts = trimmed.split(separator: " ").map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        if !letters.isEmpty { return letters.joined() }
        return "?"
    }
}
