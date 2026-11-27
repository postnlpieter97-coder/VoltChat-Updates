import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private let accent = Color(red: 1, green: 0.835, blue: 0)
private let base = Color(red: 0.035, green: 0.035, blue: 0.035)
private let card = Color(red: 0.09, green: 0.09, blue: 0.09)

struct User: Decodable { let id: UUID }
struct Session: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int; let user: User }
struct Room: Decodable, Identifiable, Hashable { let id: UUID; let owner: UUID; let peer: UUID; let name: String; let accepted: Bool }
struct Profile: Decodable { let user_id: UUID; let display_name: String; let avatar: String?; let bio: String?; let banner: String? }
struct Message: Decodable, Identifiable { let id: UUID; let sender: UUID; let body: String; let created_at: String; let has_image: Bool?; let file_name: String?; let file_size: Int? }
struct ImageRow: Decodable { let image_data: String? }
struct Empty: Decodable {}
struct APIError: LocalizedError { let text: String; var errorDescription: String? { text } }

@MainActor final class Store: ObservableObject {
    @Published var session: Session?
    @Published var rooms: [Room] = []
    @Published var profiles: [UUID: Profile] = [:]
    @Published var messages: [Message] = []
    @Published var error = ""
    @Published var busy = false
    private var expiry = Date.distantPast
    private let host = "https://vdeqcnidluapqnnhzxbp.supabase.co"
    // Public project key only. No service-role credential is included.
    private let key = "sb_publishable_e_r3nyY2ZDvm-0IPCLGMCg_j7rfENbD"
    var me: UUID? { session?.user.id }
    private func raw(_ path: String, method: String, body: [String: Any]? = nil, token: String? = nil) async throws -> Data {
        guard let url = URL(string: host + path) else { throw APIError(text: "Invalid request") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(text: (object?["msg"] as? String) ?? (object?["message"] as? String) ?? "Request failed. Check your connection and account.")
        }
        return data
    }
    private func adopt(_ s: Session) { session = s; expiry = Date().addingTimeInterval(Double(s.expires_in - 60)) }
    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let s = session else { throw APIError(text: "Please sign in again.") }
        if Date() >= expiry {
            do { adopt(try JSONDecoder().decode(Session.self, from: await raw("/auth/v1/token?grant_type=refresh_token", method: "POST", body: ["refresh_token": s.refresh_token]))) }
            catch { clear(); throw APIError(text: "Session expired. Sign in again.") }
        }
        return try await raw("/rest/v1/" + path, method: method, body: body, token: session?.access_token)
    }
    func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = ""
        defer { busy = false }
        do { try await work() } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func login(_ email: String, _ password: String) async throws {
        let data = try await raw("/auth/v1/token?grant_type=password", method: "POST", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        adopt(try JSONDecoder().decode(Session.self, from: data)); try await refreshRooms()
    }
    func clear() { session = nil; expiry = .distantPast; rooms = []; profiles = [:]; messages = [] }
    func logout() async throws {
        defer { clear() }
        if let session { _ = try await raw("/auth/v1/logout", method: "POST", token: session.access_token) }
    }
    func peer(_ r: Room) -> UUID { r.owner == me ? r.peer : r.owner }
    func label(_ r: Room) -> String { profiles[peer(r)]?.display_name ?? "Contact " + peer(r).uuidString.prefix(8) }
    func refreshRooms() async throws {
        let list = try JSONDecoder().decode([Room].self, from: await api("volt_rooms?select=id,owner,peer,name,accepted&order=created_at.desc&limit=200"))
        rooms = list
        let ids = Set(list.filter(\.accepted).map(peer))
        if !ids.isEmpty {
            let filter = ids.map { $0.uuidString }.joined(separator: ",")
            if let data = try? await api("volt_profiles?select=user_id,display_name,avatar,bio,banner&user_id=in.(\(filter))"), let p = try? JSONDecoder().decode([Profile].self, from: data) { profiles = Dictionary(uniqueKeysWithValues: p.map { ($0.user_id, $0) }) }
        } else { profiles = [:] }
    }
    func invite(_ value: String) async throws {
        guard let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)), let me, id != me else { throw APIError(text: "Enter another person's contact ID.") }
        _ = try await api("volt_rooms", method: "POST", body: ["owner": me.uuidString, "peer": id.uuidString, "name": "Private chat"]); try await refreshRooms()
    }
    func accept(_ room: Room) async throws { _ = try await api("volt_rooms?id=eq.\(room.id.uuidString)", method: "PATCH", body: ["accepted": true]); try await refreshRooms() }
    func block(_ room: Room) async throws { guard let me else { return }; _ = try await api("volt_blocks", method: "POST", body: ["owner": me.uuidString, "target": peer(room).uuidString]); try await refreshRooms() }
    func report(_ message: Message) async throws { guard let me else { return }; _ = try await api("volt_reports", method: "POST", body: ["reporter": me.uuidString, "message_id": message.id.uuidString, "reason": "Reported from Volt Chat iOS"]) }
    func load(_ room: Room) async throws { let data = try await api("volt_messages?room_id=eq.\(room.id.uuidString)&select=id,sender,body,created_at,has_image,file_name,file_size&order=created_at.desc&limit=100"); messages = Array(try JSONDecoder().decode([Message].self, from: data).reversed()) }
    func send(_ room: Room, text: String, photo: Data? = nil) async throws {
        guard let me else { return }; let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || photo != nil, trimmed.count <= 2000 else { throw APIError(text: "Enter up to 2000 characters.") }
        var body: [String: Any] = ["room_id": room.id.uuidString, "sender": me.uuidString, "body": trimmed.isEmpty ? "[Picture]" : trimmed]
        if let photo { body["image_data"] = photo.base64EncodedString() }
        _ = try await api("volt_messages", method: "POST", body: body); try await load(room)
    }
    func picture(_ id: UUID) async throws -> UIImage { let rows = try JSONDecoder().decode([ImageRow].self, from: await api("volt_messages?id=eq.\(id.uuidString)&select=image_data")); guard let value = rows.first?.image_data, value.count <= 600000, let data = Data(base64Encoded: value), let image = UIImage(data: data) else { throw APIError(text: "Image unavailable.") }; return image }
}

@main struct VoltChatApp: App {
    @StateObject private var store = Store()
    var body: some Scene { WindowGroup { RootView().environmentObject(store).preferredColorScheme(.dark).tint(accent) } }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View { Group { if store.session == nil { LoginView() } else { RoomsView() } }.background(base).alert("Volt Chat", isPresented: Binding(get: { !store.error.isEmpty }, set: { if !$0 { store.error = "" } })) { Button("OK", role: .cancel) { store.error = "" } } message: { Text(store.error) } }
}
struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var email = ""
    @State private var password = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "bolt.fill").font(.system(size: 54, weight: .bold)).foregroundStyle(accent)
            Text("Volt Chat").font(.largeTitle.bold()); Text("Sign in with your existing account.").foregroundStyle(.secondary)
            TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().padding().background(card, in: RoundedRectangle(cornerRadius: 12))
            SecureField("Password", text: $password).textContentType(.password).padding().background(card, in: RoundedRectangle(cornerRadius: 12))
            Button { Task { await store.perform { try await store.login(email, password); password = "" } } } label: { HStack { Spacer(); if store.busy { ProgressView() }; Text("Sign in").bold(); Spacer() }.padding() }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(store.busy || email.isEmpty || password.isEmpty)
            Text("This first mobile build uses your existing verified Volt Chat account.").font(.footnote).foregroundStyle(.secondary)
        }.padding(28).padding(.top, 65) }.background(base)
    }
}
struct Avatar: View {
    let profile: Profile?
    var body: some View { Group { if let value = profile?.avatar, let bytes = Data(base64Encoded: value), let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFill() } else { ZStack { Circle().fill(card); Image(systemName: "person.fill").foregroundStyle(accent) } } }.frame(width: 42, height: 42).clipShape(Circle()) }
}
struct RoomsView: View {
    @EnvironmentObject var store: Store
    @State private var invite = false
    @State private var contact = ""
    var body: some View {
        NavigationStack { List {
            Section("Your account") { Button { if let me = store.me { UIPasteboard.general.string = me.uuidString.lowercased() } } label: { Label("Copy my contact ID", systemImage: "doc.on.doc") } }
            Section("Direct messages") {
                if store.rooms.filter(\.accepted).isEmpty { Text("No accepted contacts yet").foregroundStyle(.secondary) }
                ForEach(store.rooms.filter(\.accepted)) { room in NavigationLink { ChatView(room: room) } label: { HStack { Avatar(profile: store.profiles[store.peer(room)]); Text(store.label(room)) } } }
            }
            Section("Requests") { ForEach(store.rooms.filter { !$0.accepted }) { room in VStack(alignment: .leading, spacing: 8) { Text("Contact " + store.peer(room).uuidString.prefix(8)); if room.peer == store.me { Button("Accept request") { Task { await store.perform { try await store.accept(room) } } } } else { Text("Awaiting acceptance").foregroundStyle(.secondary) }; Button("Block contact", role: .destructive) { Task { await store.perform { try await store.block(room) } } } } } }
            Section { Button("Sign out", role: .destructive) { Task { await store.perform { try await store.logout() } } } }
        }.scrollContentBackground(.hidden).background(base).navigationTitle("Volt Chat").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { invite = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Add contact") } }.refreshable { await store.perform { try await store.refreshRooms() } }.alert("Add a contact", isPresented: $invite) { TextField("Contact ID", text: $contact); Button("Send request") { Task { await store.perform { try await store.invite(contact); contact = "" } } }; Button("Cancel", role: .cancel) {} } message: { Text("Only add someone you recognize.") } }
    }
}
struct ChatView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let room: Room
    @State private var text = ""
    @State private var picker: PhotosPickerItem?
    @State private var draft: Data?
    @State private var blockConfirm = false
    @State private var image: UIImage?
    @State private var imageOpen = false
    @State private var reportTarget: Message?
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 14) { ForEach(store.messages) { msg in VStack(alignment: .leading, spacing: 6) { HStack { Text(msg.sender == store.me ? "You" : store.label(room)).font(.caption.bold()).foregroundStyle(accent); Spacer(); Text(String(msg.created_at.prefix(16)).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(.secondary) }; Text(msg.body).textSelection(.enabled); if msg.has_image == true { Button("View picture", systemImage: "photo") { Task { await store.perform { image = try await store.picture(msg.id); imageOpen = true } } } }; if let name = msg.file_name { Label(name + " · Open on Windows", systemImage: "doc").font(.caption) } }.padding(12).background(card, in: RoundedRectangle(cornerRadius: 12)).contextMenu { Button("Report message", role: .destructive) { reportTarget = msg } }.id(msg.id) } }.padding() }.onChange(of: store.messages.last?.id) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } } }
            if let draft, let photo = UIImage(data: draft) { HStack { Image(uiImage: photo).resizable().scaledToFit().frame(height: 70); Text("Picture ready"); Spacer(); Button { self.draft = nil; picker = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove picture") }.padding(.horizontal) }
            HStack { PhotosPicker(selection: $picker, matching: .images) { Image(systemName: "photo.badge.plus").font(.title2) }.accessibilityLabel("Attach picture"); TextField("Message", text: $text, axis: .vertical).lineLimit(1...4).padding(10).background(card, in: RoundedRectangle(cornerRadius: 12)); Button { Task { await store.perform { try await store.send(room, text: text, photo: draft); text = ""; draft = nil; picker = nil } } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.accessibilityLabel("Send message").disabled(store.busy || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft == nil)) }.padding()
        }.background(base).navigationTitle(store.label(room)).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu { Button("Block contact", role: .destructive) { blockConfirm = true } } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Conversation actions") } }.confirmationDialog("Block this contact?", isPresented: $blockConfirm, titleVisibility: .visible) { Button("Block", role: .destructive) { Task { await store.perform { try await store.block(room); dismiss() } } } }.alert("Report this message?", isPresented: Binding(get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } })) { Button("Report", role: .destructive) { if let target = reportTarget { Task { await store.perform { try await store.report(target) } } }; reportTarget = nil }; Button("Cancel", role: .cancel) { reportTarget = nil } }.sheet(isPresented: $imageOpen) { if let image { VStack { Image(uiImage: image).resizable().scaledToFit(); Button("Close") { imageOpen = false } }.padding() } }.task { store.messages = []; await store.perform { try await store.load(room) }; while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { await store.perform { try await store.load(room) } } } }.onChange(of: picker) { item in guard let item else { return }; Task { do { guard let bytes = try await item.loadTransferable(type: Data.self), let ui = UIImage(data: bytes) else { throw APIError(text: "Invalid picture") }; let ratio = min(1, 1280 / max(ui.size.width, ui.size.height)); let size = CGSize(width: ui.size.width * ratio, height: ui.size.height * ratio); let format = UIGraphicsImageRendererFormat(); format.scale = 1; let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }; guard let compressed = [0.75, 0.55, 0.35, 0.2].compactMap({ resized.jpegData(compressionQuality: $0) }).first(where: { $0.count <= 450000 }) else { throw APIError(text: "Picture is too large") }; if picker == item { draft = compressed } } catch { store.error = error.localizedDescription } } }
    }
}