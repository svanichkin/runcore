import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private enum ContactsRoute: Hashable {
    case chat(UUID)
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        TabView {
            ContactsTabView()
                .tabItem { Label("Contacts", systemImage: "person.2") }

            CallsTabView()
                .tabItem { Label("Calls", systemImage: "phone") }

            ChatsTabView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            SettingsTabView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .toolbar(removing: .sidebarToggle)
        .background(SidebarToggleHider())
        .sheet(
            item: Binding(get: { store.inboundPrompt }, set: { _ in }),
            content: { prompt in
                InboundPromptSheet(prompt: prompt)
                    .interactiveDismissDisabled()
            }
        )
    }
}

private struct InboundPromptSheet: View {
    @EnvironmentObject private var store: AppStore
    let prompt: AppStore.InboundPrompt

    var body: some View {
        let name = store.inboundPromptDisplayName ?? store.displayNameForDestinationHashHex(prompt.destHashHex)
        VStack(spacing: 14) {
            Text(name)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            ZStack {
                RoundedSquareAvatarView(avatarData: store.inboundPromptAvatarData, name: name, cornerRadius: 18)
                    .frame(maxWidth: 280, maxHeight: 280)

                if store.inboundPromptIsLoadingAvatar {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)

            Text(prompt.destHashHex)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            GeometryReader { proxy in
                ScrollView {
                    VStack {
                        Spacer(minLength: 0)
                        Text(prompt.content)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: proxy.size.height)
                }
            }

            HStack(spacing: 10) {
                Button("Accept") { store.acceptInboundPrompt(prompt) }
                    .buttonStyle(.borderedProminent)

                Button("Decline", role: .cancel) { store.declineInboundPrompt(prompt) }
                    .buttonStyle(.bordered)

                Button("Block", role: .destructive) { store.blockInboundPrompt(prompt) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .presentationDetents([.large])
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
                },
                announces: store.announces
            )
        }
    }

    private var contactsList: some View {
        Group {
            if horizontalSizeClass == .regular {
               List {
                   ForEach(store.contacts) { contact in
                       Button {
                           store.selectedContactID = contact.id
                       } label: {
                           contactRow(contact)
                       }
                       .buttonStyle(.plain)
                       .listRowInsets(EdgeInsets())
                       .listRowBackground(rowBackground(for: contact))
                       .listRowSeparator(.hidden)
                   }
               }
               .listStyle(.plain)
               .listRowSeparator(.hidden)
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
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
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

    @ViewBuilder
    private func rowBackground(for contact: Contact) -> some View {
        let isSelected = horizontalSizeClass == .regular && store.selectedContactID == contact.id
        if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
        } else {
            Color.clear
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
            .navigationBarTitleDisplayMode(.inline)
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
            .navigationBarTitleDisplayMode(.inline)
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

    @State private var isImportingAttachment = false
    @State private var importingAttachmentError: String?
    #if !targetEnvironment(macCatalyst)
    @State private var pickedAttachmentItem: PhotosPickerItem?
    #endif

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
                    NavigationLink {
                        ContactProfileView(contactID: contactID)
                            .environmentObject(store)
                    } label: {
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



    @ViewBuilder
    private var attachmentPicker: some View {
        #if targetEnvironment(macCatalyst)
        Button {
            importingAttachmentError = nil
            isImportingAttachment = true
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .fileImporter(
            isPresented: $isImportingAttachment,
            allowedContentTypes: [UTType.image],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let data = try Data(contentsOf: url)
                let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                store.sendImageAttachment(to: contactID, data: data, suggestedName: url.lastPathComponent, caption: caption)
                draft = ""
            } catch {
                importingAttachmentError = String(describing: error)
            }
        }
        #else
        PhotosPicker(selection: $pickedAttachmentItem, matching: .images) {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .onChange(of: pickedAttachmentItem) { newItem in
            guard let newItem else { return }
            Task { @MainActor in
                defer { pickedAttachmentItem = nil }
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.sendImageAttachment(to: contactID, data: data, suggestedName: nil, caption: caption)
                    draft = ""
                }
            }
        }
        #endif
    }
    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.messages(for: contactID)) { msg in
                            MessageRow(message: msg, contactDestHashHex: contact?.destinationHashHex ?? "")
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
                .onChange(of: store.lastMessageID(for: contactID)) { _ in
                    store.markChatRead(contactID: contactID)
                }
            }

            Divider()

            HStack(spacing: 8) {
                attachmentPicker

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
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
        .onAppear {
            store.markChatRead(contactID: contactID)
        }
    }
}

private struct ContactProfileView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID

    @State private var nameDraft: String = ""
    @State private var lastSavedName: String = ""

    private var contact: Contact? {
        store.contacts.first(where: { $0.id == contactID })
    }

    var body: some View {
        if let contact {
            ProfileEditorList(
                nameDraft: $nameDraft,
                namePlaceholder: "Local name",
                identifier: contact.destinationHashHex,
                onCopyIdentifier: {
                    UIPasteboard.general.string = contact.destinationHashHex
                    store.appendLog("copied contact id")
                },
                avatar: {
                    avatarPicker(contact: contact)
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
        AvatarPicker(
            avatarData: contact.resolvedAvatarData,
            name: contact.resolvedDisplayName,
            maxSide: 280,
            cornerRadius: 18,
            onAvatarData: { data in
                store.setContactLocalAvatar(id: contactID, data: data)
            }
        )
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
	    let contactDestHashHex: String
	    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

	    var body: some View {
	        let isOutgoing = message.direction == .outbound
	        let maxBubbleWidth: CGFloat = (horizontalSizeClass == .regular) ? 520 : 280
	        let title = message.title.trimmingCharacters(in: .whitespacesAndNewlines)

	        HStack {
	            if isOutgoing { Spacer(minLength: 0) }

	            if let attachment = message.attachment {
	                imageBubble(attachment: attachment, isOutgoing: isOutgoing, maxBubbleWidth: maxBubbleWidth)
	            } else {
	                textBubble(title: title, isOutgoing: isOutgoing, maxBubbleWidth: maxBubbleWidth)
	            }

	            if !isOutgoing { Spacer(minLength: 0) }
	        }
	    }

	    @ViewBuilder
	    private func textBubble(title: String, isOutgoing: Bool, maxBubbleWidth: CGFloat) -> some View {
	        VStack(alignment: .leading, spacing: 4) {
	            if !title.isEmpty && title.lowercased() != "msg" && title.lowercased() != "img" {
	                Text(title)
	                    .font(.caption)
	                    .foregroundStyle(isOutgoing ? .white.opacity(0.85) : .secondary)
	            }

	            Text(message.text)
	                .foregroundStyle(isOutgoing ? .white : .primary)
	                .textSelection(.enabled)

	            HStack(spacing: 6) {
	                Spacer(minLength: 0)
	                Text(message.timestamp, style: .time)
	                    .font(.caption2)
	                    .foregroundStyle(isOutgoing ? .white.opacity(0.75) : .secondary)
	                if isOutgoing {
	                    receiptMarks
	                }
	            }
	        }
	        .padding(.horizontal, 12)
	        .padding(.vertical, 9)
	        .background(isOutgoing ? Color.accentColor : Color.gray.opacity(0.14))
	        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
	        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
	    }

	    private func imageBubble(attachment: MessageAttachment, isOutgoing: Bool, maxBubbleWidth: CGFloat) -> some View {
	        let maxSide: CGFloat = 240
	        let maxW: CGFloat = min(maxBubbleWidth, maxSide)
	        let maxH: CGFloat = maxSide
	        let bubbleShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

	        if let path = resolvedAttachmentPath(attachment),
	           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
	           let uiImage = UIImage(data: data) {
	            let imgSize = uiImage.size
	            let aspect = (imgSize.height > 0) ? (imgSize.width / imgSize.height) : 1
	            let fitted = fittedAttachmentSize(imageSize: imgSize, maxW: maxW, maxH: maxH)

	            return AnyView(
	                ZStack(alignment: .bottomTrailing) {
	                    Image(uiImage: uiImage)
	                        .resizable()
	                        .aspectRatio(aspect, contentMode: .fit)
	                        .frame(width: fitted.width, height: fitted.height)

	                    HStack(spacing: 6) {
	                        Text(message.timestamp, style: .time)
	                            .font(.caption2)
	                            .foregroundStyle(.white.opacity(0.9))
	                        if isOutgoing {
	                            receiptMarks
	                        }
	                    }
	                    .padding(.horizontal, 8)
	                    .padding(.vertical, 6)
	                    .background(.black.opacity(0.35))
	                    .clipShape(Capsule())
	                    .padding(8)
	                }
	                .frame(width: fitted.width, height: fitted.height, alignment: .bottomTrailing)
	                .clipShape(bubbleShape)
	            )
	        }

	        return AnyView(
	            ZStack {
	                bubbleShape.fill(Color.gray.opacity(0.18))
	                Image(systemName: "photo")
	                    .font(.system(size: 22))
	                    .foregroundStyle(.secondary)
	            }
	            .frame(width: maxW, height: maxH)
	        )
	    }

		    @ViewBuilder
		    private func attachmentPreview(_ attachment: MessageAttachment, maxWidth: CGFloat) -> some View {
		        let maxSide: CGFloat = 240
		        let maxW: CGFloat = min(maxWidth, maxSide)
		        let maxH: CGFloat = maxSide
	        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

	        if let path = resolvedAttachmentPath(attachment),
	           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
	           let uiImage = UIImage(data: data) {
	            let imgSize = uiImage.size
	            let aspect = (imgSize.height > 0) ? (imgSize.width / imgSize.height) : 1
	            let fitted = fittedAttachmentSize(imageSize: imgSize, maxW: maxW, maxH: maxH)

	            Image(uiImage: uiImage)
	                .resizable()
	                .aspectRatio(aspect, contentMode: .fit)
	                .frame(width: fitted.width, height: fitted.height)
	                .clipShape(shape)
	        } else {
	            ZStack {
	                shape.fill(Color.gray.opacity(0.18))
	                Image(systemName: "photo")
	                    .font(.system(size: 22))
	                    .foregroundStyle(.secondary)
	            }
	            .frame(width: maxW, height: maxH)
	        }
	    }

	    private func fittedAttachmentSize(imageSize: CGSize, maxW: CGFloat, maxH: CGFloat) -> CGSize {
	        let aspect = (imageSize.height > 0) ? (imageSize.width / imageSize.height) : 1
	        let safeAspect = max(aspect, 0.01)
	        var width = maxW
	        var height = width / safeAspect
	        if height > maxH {
	            height = maxH
	            width = height * safeAspect
	        }
	        // Avoid tiny bubbles for very narrow images.
	        width = max(120, min(width, maxW))
	        height = max(120, min(height, maxH))
	        return CGSize(width: width, height: height)
	    }

    private func resolvedAttachmentPath(_ attachment: MessageAttachment) -> String? {
        let fm = FileManager.default
        if let p = attachment.localPath, !p.isEmpty, fm.fileExists(atPath: p) {
            return p
        }
        let hash = attachment.hashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !hash.isEmpty else { return nil }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("Runcore", isDirectory: true)

        switch message.direction {
        case .outbound:
            return base.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("out", isDirectory: true)
                .appendingPathComponent("\(hash).bin")
                .path
        case .inbound:
            let remote = contactDestHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !remote.isEmpty else { return nil }
            return base.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("in", isDirectory: true)
                .appendingPathComponent(remote, isDirectory: true)
                .appendingPathComponent("\(hash).bin")
                .path
        }
    }

    @ViewBuilder
    private var receiptMarks: some View {
        switch message.outboundStatus {
        case .delivered:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
        case .read:
            HStack(spacing: 1) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        case .pending, .none:
            EmptyView()
        }
    }
}
