import SwiftUI
import UIKit

struct FavoriteAsset: Codable, Identifiable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    var url: URL { FavoriteStore.directory.appendingPathComponent(relativePath) }
    var isImage: Bool { API.isImage(name) }
}

struct FavoriteItem: Codable, Identifiable {
    let id: UUID
    let sourceKey: String
    let sourceRemark: String
    let text: String
    let savedAt: Date
    let assets: [FavoriteAsset]
    var synced: Bool? = nil
}

private struct FavoriteSnapshot: Codable {
    let items: [FavoriteItem]
    let deletedIDs: [UUID]
}

@MainActor
final class FavoriteStore: ObservableObject {
    static let shared = FavoriteStore()
    static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Favorites", isDirectory: true)
    @Published private(set) var items: [FavoriteItem] = []
    @Published private(set) var syncing = false
    @Published private(set) var needsLogin = false
    @Published private(set) var syncError: String?
    private var deletedIDs: [UUID] = []
    private var loadingError: Error?
    private var adding = Set<String>()
    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    init() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                if let snapshot = try? JSONDecoder().decode(FavoriteSnapshot.self, from: data) {
                    items = snapshot.items; deletedIDs = snapshot.deletedIDs
                } else {
                    items = try JSONDecoder().decode([FavoriteItem].self, from: data)
                }
            }
        } catch { loadingError = error }
    }

    static func remark(mine: Bool) -> String {
        UserDefaults.standard.string(forKey: mine ? "myNickname" : "assistantRemark") ?? (mine ? "我" : "助手")
    }

    func add(message: Msg, peerName: String? = nil) async throws {
        let mine = message.from == "me"
        try await add(sourceKey: "remote:\(message.id)", remark: mine ? Self.remark(mine: true) : (peerName ?? Self.remark(mine: false)), text: message.displayedText,
                      urls: message.file.map { [API.fileURL($0)] } ?? [])
    }

    func add(messages: [Msg], caption: String, peerName: String? = nil) async throws {
        guard let first = messages.first else { return }
        let mine = first.from == "me"
        try await add(sourceKey: "album:\(first.id)", remark: mine ? Self.remark(mine: true) : (peerName ?? Self.remark(mine: false)), text: caption,
                      urls: messages.compactMap(\.file).map(API.fileURL))
    }

    func add(sourceKey: String, remark: String, text: String, urls: [URL] = []) async throws {
        if let loadingError { throw loadingError }
        guard !items.contains(where: { $0.sourceKey == sourceKey }), !adding.contains(sourceKey) else { return }
        adding.insert(sourceKey)
        defer { adding.remove(sourceKey) }
        let id = UUID()
        let folder = Self.directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var assets: [FavoriteAsset] = []
        do {
            for (index, url) in urls.enumerated() {
                let data: Data
                if url.isFileURL { data = try Data(contentsOf: url) }
                else {
                    let (downloaded, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    data = downloaded
                }
                let filename = "\(index)-\(url.lastPathComponent)"
                try data.write(to: folder.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUnlessOpen])
                assets.append(FavoriteAsset(name: url.lastPathComponent, relativePath: "\(id.uuidString)/\(filename)"))
            }
            let item = FavoriteItem(id: id, sourceKey: sourceKey, sourceRemark: remark, text: text, savedAt: Date(), assets: assets)
            try persist([item] + items)
            Task { await sync() }
        } catch {
            // Only this operation's newly created temporary directory is discarded.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func remove(_ item: FavoriteItem) throws {
        // Keep cached attachments recoverable; only remove the index entry.
        try persist(items.filter { $0.id != item.id }, deleted: Array(Set(deletedIDs + [item.id])))
        Task { await sync() }
    }

    private func persist(_ values: [FavoriteItem], deleted: [UUID]? = nil) throws {
        if let loadingError { throw loadingError }
        let pending = deleted ?? deletedIDs
        try JSONEncoder().encode(FavoriteSnapshot(items: values, deletedIDs: pending)).write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        items = values
        deletedIDs = pending
    }

    func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            if let loadingError { throw loadingError }
            // Verify the existing owner session before uploading any private content.
            _ = try await SharedAlbumsAPI.request("api/favorites")
            needsLogin = false
            var attempted = Set<UUID>()
            var failures: [String] = []
            while true {
                if let id = deletedIDs.first {
                    _ = try await SharedAlbumsAPI.request("api/favorites/remove", body: ["id": id.uuidString])
                    try persist(items, deleted: deletedIDs.filter { $0 != id })
                } else if let item = items.first(where: { $0.synced != true && !attempted.contains($0.id) }) {
                    attempted.insert(item.id)
                    do {
                    let files = item.assets.map { ($0.name, $0.url) }
                    let encoded = try await Task.detached(priority: .utility) {
                        var total = 0
                        let assets: [[String: String]] = try files.map { name, url in
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            total += size
                            guard total <= 24 * 1024 * 1024 else { throw AlbumError.server("单条收藏附件超过 24 MB，已保留本地，暂未同步。") }
                            return ["name": name, "base64": try Data(contentsOf: url).base64EncodedString()]
                        }
                        let record: [String: Any] = ["id": item.id.uuidString, "text": item.text, "sourceRemark": item.sourceRemark, "savedAt": item.savedAt.timeIntervalSince1970 * 1000, "assets": assets]
                        return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
                    }.value
                    _ = try await SharedAlbumsAPI.request("api/favorites/save", body: ["record": encoded])
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        var updated = items; updated[index].synced = true
                        try persist(updated)
                    }
                    } catch {
                        if case AlbumError.authentication = error { throw error }
                        failures.append(error.localizedDescription)
                    }
                } else { break }
            }
            syncError = failures.isEmpty ? nil : "\(failures.count) 条尚未同步：\(failures[0])"
        } catch {
            if case AlbumError.authentication = error { needsLogin = true }
            syncError = error.localizedDescription
        }
    }
}

struct FavoritesView: View {
    @ObservedObject private var store = FavoriteStore.shared
    @State private var query = ""
    @State private var filter = "全部"
    @State private var newNote = false
    @State private var connecting = false
    @Environment(\.scenePhase) private var scenePhase
    private let filters = ["全部", "文字", "图片", "链接", "文件"]
    private var filtered: [FavoriteItem] {
        store.items.filter { item in
            let matches = query.isEmpty || item.text.localizedCaseInsensitiveContains(query) || item.sourceRemark.localizedCaseInsensitiveContains(query)
            let kind: Bool
            switch filter {
            case "文字": kind = item.assets.isEmpty
            case "图片": kind = item.assets.contains(where: \.isImage)
            case "链接": kind = item.text.contains("https://") || item.text.contains("http://")
            case "文件": kind = item.assets.contains { !$0.isImage }
            default: kind = true
            }
            return matches && kind
        }
    }
    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索收藏", text: $query)
                    }.padding(14).modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
                    HStack(spacing: 8) {
                        if store.syncing { ProgressView().controlSize(.small) }
                        Image(systemName: store.needsLogin ? "lock" : "icloud")
                        Text(store.needsLogin ? "验证后共享给助手" : (store.syncing ? "正在同步收藏…" : (store.syncError != nil ? "有收藏尚未同步" : "助手可查看已同步的收藏")))
                            .font(.caption)
                        Spacer(minLength: 0)
                        Button(store.needsLogin ? "验证" : "同步") {
                            if store.needsLogin { connecting = true } else { Task { await store.sync() } }
                        }.font(.caption).disabled(store.syncing)
                    }.foregroundStyle(.secondary)
                    if let error = store.syncError, !store.needsLogin { Text(error).font(.caption2).foregroundStyle(.secondary) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 22) {
                            ForEach(filters, id: \.self) { value in
                                Button(value) { filter = value }
                                    .foregroundStyle(filter == value ? Color.pink : Color.secondary)
                            }
                        }.padding(.vertical, 8)
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "还没有收藏" : "没有找到", systemImage: "star", description: Text("长按聊天消息，点「收藏」保存在这里。"))
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { item in
                            NavigationLink { FavoriteDetailView(item: item) } label: {
                                VStack(alignment: .leading, spacing: 18) {
                                    if !item.text.isEmpty { Text(item.text).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading) }
                                    if let first = item.assets.first {
                                        FavoriteAssetPreview(asset: first).frame(maxHeight: 150, alignment: .leading).clipped()
                                    }
                                    HStack {
                                        Text(item.sourceRemark).lineLimit(1)
                                        Spacer()
                                        Text(item.savedAt.formatted(.dateTime.month().day()))
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if item.synced != true { Text("仅本机 · 待同步").font(.caption2).foregroundStyle(.secondary) }
                                }
                                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(16)
            }
        }
        .navigationTitle("收藏").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { newNote = true } label: { Image(systemName: "plus.circle") }.accessibilityLabel("新建收藏") } }
        .sheet(isPresented: $newNote) { FavoriteNoteComposer() }
        .sheet(isPresented: $connecting) { FavoriteConnectionView() }
        .task { await store.sync() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.sync() } } }
    }
}

private struct FavoriteConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("收藏与相册共用身份验证。连接后，现有和以后的收藏会同步给助手查看，助手不能修改或删除。")
                    SecureField("原朋友圈账号口令", text: $password).textContentType(.password)
                    if let error { Text(error).foregroundStyle(.red) }
                    Button(busy ? "正在连接…" : "验证并同步") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                _ = try await SharedAlbumsAPI.request("api/login", body: ["pw": password])
                                password = ""
                                await FavoriteStore.shared.sync()
                                if FavoriteStore.shared.needsLogin { error = "身份验证未成功" }
                                else { dismiss() }
                            } catch { self.error = "验证失败，请检查口令或网络。" }
                        }
                    }.disabled(password.isEmpty || busy)
                }
            }
            .navigationTitle("连接共享收藏").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct FavoriteAssetPreview: View {
    let asset: FavoriteAsset
    @State private var image: UIImage?
    var body: some View {
        Group {
            if asset.isImage {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { ProgressView() }
            } else { Label(asset.name, systemImage: "doc").lineLimit(2) }
        }.task(id: asset.id) {
            guard asset.isImage else { return }
            let url = asset.url
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            if let data { image = UIImage(data: data) }
        }
    }
}

private struct FavoriteDetailView: View {
    let item: FavoriteItem
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                        Text("来自 \(item.sourceRemark)  \(item.savedAt.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5)
                    }
                    if !item.text.isEmpty { Text(item.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(item.assets) { asset in
                        VStack(alignment: .leading, spacing: 8) {
                            FavoriteAssetPreview(asset: asset)
                            ShareLink(item: asset.url) { Label("分享或保存", systemImage: "square.and.arrow.up") }.font(.caption)
                        }
                    }
                    HStack { Divider(); Text("·").foregroundStyle(.secondary); Divider() }
                }.padding(24)
            }
        }
        .navigationTitle("详情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("复制文字", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
                Button("删除收藏", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: { Image(systemName: "ellipsis") }
        } }
        .confirmationDialog("删除这条收藏？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除收藏", role: .destructive) {
                do { try FavoriteStore.shared.remove(item); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("未能删除", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}

private struct FavoriteNoteComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            TextEditor(text: $text).padding()
                .navigationTitle("新建收藏").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    try await FavoriteStore.shared.add(sourceKey: UUID().uuidString, remark: FavoriteStore.remark(mine: true), text: text)
                                    dismiss()
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }.disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }
}
