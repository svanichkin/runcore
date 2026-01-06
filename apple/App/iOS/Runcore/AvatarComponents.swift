import SwiftUI
import UniformTypeIdentifiers
import UIKit

#if !targetEnvironment(macCatalyst)
import PhotosUI
#endif

private struct AvatarSquareSizer: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            content
                .frame(width: side, height: side)
                .clipped()
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct RoundedSquareAvatarView: View {
    let avatarData: Data?
    let name: String
    var cornerRadius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let avatarData, let uiImage = UIImage(data: avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                shape.fill(Color.accentColor.opacity(0.15))
                Text(initials(from: name))
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.65))
            }
        }
        .modifier(AvatarSquareSizer())
        .clipShape(shape)
        .overlay(shape.stroke(.secondary.opacity(0.3), lineWidth: 0.5))
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

struct AvatarPicker: View {
    let avatarData: Data?
    let name: String
    var maxSide: CGFloat = 280
    var cornerRadius: CGFloat = 18
    let onAvatarData: (Data) -> Void

    @State private var isImportingAvatar = false
#if !targetEnvironment(macCatalyst)
    @State private var pickedAvatarItem: PhotosPickerItem?
#endif

    var body: some View {
#if targetEnvironment(macCatalyst)
        Button {
            isImportingAvatar = true
        } label: {
            RoundedSquareAvatarView(avatarData: avatarData, name: name, cornerRadius: cornerRadius)
                .frame(maxWidth: maxSide, maxHeight: maxSide)
        }
        .buttonStyle(.plain)
        .fileImporter(
            isPresented: $isImportingAvatar,
            allowedContentTypes: [UTType.image],
            allowsMultipleSelection: false
        ) { result in
            if let url = try? result.get().first,
               let data = try? Data(contentsOf: url) {
                onAvatarData(data)
            }
        }
#else
        PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
            RoundedSquareAvatarView(avatarData: avatarData, name: name, cornerRadius: cornerRadius)
                .frame(maxWidth: maxSide, maxHeight: maxSide)
        }
        .onChange(of: pickedAvatarItem) { _, newItem in
            guard let newItem else { return }
            Task { @MainActor in
                defer { pickedAvatarItem = nil }
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    onAvatarData(data)
                }
            }
        }
#endif
    }
}

struct ProfileEditorList<AvatarContent: View>: View {
    @Binding var nameDraft: String
    let namePlaceholder: String
    let identifier: String
    let onCopyIdentifier: () -> Void
    @ViewBuilder let avatar: () -> AvatarContent

    var body: some View {
        List {
            avatar()
                .listRowInsets(EdgeInsets())
                .clipShape(ContainerRelativeShape())
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .padding(.vertical, 8)

            Section("Name") {
                TextField(namePlaceholder, text: $nameDraft)
                    .textInputAutocapitalization(.words)
            }

            Section("Identifier") {
                HStack(spacing: 8) {
                    Text(identifier)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: onCopyIdentifier) {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
