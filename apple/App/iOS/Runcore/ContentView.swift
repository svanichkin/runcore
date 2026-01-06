import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private enum ContactsRoute: Hashable {
    case chat(UUID)
    case profile(UUID)
}

struct ContentView: View {
    @StateObject private var store = AppStore()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        TabView {
            ContactsTabView()
                .environmentObject(store)
                .tabItem { Label("Contacts", systemImage: "person.2") }

            CallsTabView()
                .tabItem { Label("Calls", systemImage: "phone") }

            ChatsTabView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            SettingsTabView()
                .environmentObject(store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .toolbar(removing: .sidebarToggle)
        .background(SidebarToggleHider())
    }
}

private struct ContactsTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var navigationPath = NavigationPath()
    @State private var detailPath = NavigationPath()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    contactsList
                } detail: {
                    NavigationStack(path: $detailPath) {
                        if let contact = store.selectedContact {
                            ChatView(contactID: contact.id)
                                .environmentObject(store)
                        } else {
                            emptySelection
                        }
                    }
                    .navigationDestination(for: ContactsRoute.self) { route in
                        switch route {
                        case .chat:
                            Text("Chat not found")
                        case .profile(let contactID):
                            ContactProfileView(contactID: contactID)
                                .environmentObject(store)
                        }
                    }
                    .onChange(of: store.selectedContactID) { _ in
                        detailPath = NavigationPath()
                    }
                }
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .navigation) { EmptyView() }
                }
                .background(SidebarToggleHider())
            } else {
                NavigationStack(path: $navigationPath) {
                    contactsList
                        .navigationDestination(for: ContactsRoute.self) { route in
                            switch route {
                            case .chat(let id):
                                if let contact = store.contacts.first(where: { $0.id == id }) {
                                    ChatView(contactID: contact.id)
                                        .environmentObject(store)
                                } else {
                                    Text("Chat not found")
                                }
                            case .profile(let contactID):
                                ContactProfileView(contactID: contactID)
                                    .environmentObject(store)
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $store.isPresentingAddContact) {
            AddContactView(
                onCancel: { store.isPresentingAddContact = false },
                onAdd: { displayName, destinationHashHex in
                    store.addContact(displayName: displayName, destinationHashHex: destinationHashHex)
                    store.isPresentingAddContact = false
                },
                resolvePreview: { destHashHex in
                    await store.resolveContactPreview(destHashHex: destHashHex)
                }
            )
        }
    }

    private var contactsList: some View {
        Group {
             if horizontalSizeClass == .regular {
                List(selection: $store.selectedContactID) {
                    ForEach(store.contacts) { contact in
                        contactRow(contact)
                            .tag(contact.id)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            } else {
                List {
                    ForEach(store.contacts) { contact in
                        Button {
                            navigationPath.append(ContactsRoute.chat(contact.id))
                        } label: {
                            contactRow(contact)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.isPresentingAddContact = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func contactRow(_ contact: Contact) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 12) {
            ContactAvatarRoundedRect(avatarData: contact.resolvedAvatarData, name: contact.resolvedDisplayName)
                .modifier(ProfileAvatarSizer())
                .clipShape(shape)
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.resolvedDisplayName)
                    Text(announceText(for: contact) ?? "Last seen unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .contextMenu {
            Button(role: .destructive) {
                store.removeContact(id: contact.id)
            } label: {
                Text("Delete")
            }
        }
    }

    private func announceText(for contact: Contact) -> String? {
        guard let entry = store.announces.first(where: { $0.destinationHashHex.caseInsensitiveCompare(contact.destinationHashHex) == .orderedSame }) else {
            return nil
        }
        return "Last seen \(timeString(from: entry.lastSeen))"
    }

    private func timeString(from unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var emptySelection: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Select a contact")
                .font(.title3)
            Text("Add one with the + button.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContactAvatarRoundedRect: View {
    let avatarData: Data?
    let name: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            if let avatarData, let uiImage = UIImage(data: avatarData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                shape.fill(.secondary.opacity(0.2))
                Text(initials(for: name))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "?" }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if let first = parts.first?.first {
            if let second = parts.dropFirst().first?.first {
                return String([first, second]).uppercased()
            }
            return String(first).uppercased()
        }
        return "?"
    }

}

private struct CallsTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(systemName: "phone")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Calls")
                    .font(.title3)
                Text("Call history will appear here.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Calls")
        }
    }
}

private struct ChatsTabView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Chats")
                    .font(.title3)
                Text("Group chats will appear here.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Chats")
        }
    }
}

private struct SettingsTabView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsView()
            .environmentObject(store)
    }
}

private struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    let contactID: UUID

    @State private var draft = ""

    private var contact: Contact? {
        store.contacts.first(where: { $0.id == contactID })
    }

    private var displayName: String {
        contact?.resolvedDisplayName ?? "Contact"
    }

    private var avatarData: Data? {
        contact?.resolvedAvatarData
    }

    var body: some View {
        Group {
            if contact != nil {
                chatBody
            } else {
                Text("Contact not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if contact != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(value: ContactsRoute.profile(contactID)) {
                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                        ContactAvatarRoundedRect(avatarData: avatarData, name: displayName)
                            .modifier(ProfileAvatarSizer())
                            .clipShape(shape)
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open contact profile")
                }
            }
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages(for: contactID)) { msg in
                            MessageRow(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: store.lastMessageID(for: contactID)) { newID in
                    guard let newID = newID else { return }
                    withAnimation {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button("Send") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.sendMessage(to: contactID, text: trimmed)
                    draft = ""
                }
            }
            .padding(12)
        }
        .navigationTitle(displayName)
    }
}

private struct ContactProfileView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID

    @State private var nameDraft: String = ""
    @State private var lastSavedName: String = ""
    @State private var pickedAvatarItem: PhotosPickerItem?
    @State private var isImportingAvatar = false

    private var contact: Contact? {
        store.contacts.first(where: { $0.id == contactID })
    }

    var body: some View {
        if let contact {
            List {
                avatarPicker(contact: contact)
                    .listRowInsets(EdgeInsets())
                    .clipShape(ContainerRelativeShape())
                    .listRowBackground(Color.clear)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)

                Section("Name") {
                    TextField("Local name", text: $nameDraft)
                        .textInputAutocapitalization(.words)
                }

                Section("Identifier") {
                    HStack(spacing: 8) {
                        Text(contact.destinationHashHex)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = contact.destinationHashHex
                            store.appendLog("copied contact id")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }

                if isDirty(remoteName: contact.displayName) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            saveIfNeeded(remoteName: contact.displayName)
                        }
                    }
                }
            }
            .onAppear {
                let remoteName = contact.displayName
                let localName = contact.localDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let effectiveName = localName.isEmpty ? remoteName : localName
                nameDraft = effectiveName
                lastSavedName = effectiveName
            }
#if !targetEnvironment(macCatalyst)
            .onChange(of: pickedAvatarItem) { newItem in
                guard let newItem else { return }
                Task { @MainActor in
                    defer { pickedAvatarItem = nil }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        store.setContactLocalAvatar(id: contactID, data: data)
                    }
                }
            }
#endif
            .fileImporter(
                isPresented: $isImportingAvatar,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if let url = try? result.get().first,
                   let data = try? Data(contentsOf: url) {
                    store.setContactLocalAvatar(id: contactID, data: data)
                }
            }
        } else {
                Text("Contact not found")
                    .foregroundStyle(.secondary)
                    .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private func avatarPicker(contact: Contact) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
#if targetEnvironment(macCatalyst)
        Button {
            isImportingAvatar = true
        } label: {
            ContactProfileAvatarView(avatarData: contact.resolvedAvatarData, name: contact.resolvedDisplayName)
                .modifier(ProfileAvatarSizer())
                .frame(maxWidth: 280, maxHeight: 280)
        }
        .buttonStyle(.plain)
        .clipShape(shape)
        .overlay(shape.stroke(.secondary.opacity(0.3), lineWidth: 0.5))
#else
        PhotosPicker(selection: $pickedAvatarItem, matching: .images) {
            ContactProfileAvatarView(avatarData: contact.resolvedAvatarData, name: contact.resolvedDisplayName)
                .modifier(ProfileAvatarSizer())
                .frame(maxWidth: 280, maxHeight: 280)
        }
        .clipShape(shape)
        .overlay(shape.stroke(.secondary.opacity(0.3), lineWidth: 0.5))
#endif
    }

    private func isDirty(remoteName: String) -> Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return lastSavedName != remoteName
        }
        return trimmed != lastSavedName
    }

    private func saveIfNeeded(remoteName: String) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == remoteName {
            store.setContactLocalName(id: contactID, name: nil)
            nameDraft = remoteName
            lastSavedName = remoteName
            return
        }
        store.setContactLocalName(id: contactID, name: trimmed)
        lastSavedName = trimmed
    }
}

private struct ContactProfileAvatarView: View {
    let avatarData: Data?
    let name: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .clipShape(shape)
        .clipped()
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

private struct ProfileAvatarSizer: ViewModifier {
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

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(message.direction == .outbound ? "You" : "Them")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !message.title.isEmpty {
                    Text(message.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(message.direction == .outbound ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
