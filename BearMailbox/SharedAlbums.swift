import SwiftUI
import PhotosUI
import UIKit

struct SharedPhoto: Codable, Identifiable {
    let id: String
    let caption: String
    let author: String
    let createdAt: Double
}
struct SharedAlbum: Codable, Identifiable {
    let id: String
    let name: String
    let photos: [SharedPhoto]
    var coverPhotoId: String? = nil
    /// Explicit cover if it still exists, otherwise the newest photo.
    var coverPhoto: SharedPhoto? { photos.first { $0.id == coverPhotoId } ?? photos.last }
}
private struct SharedAlbumResponse: Decodable { let albums: [SharedAlbum] }
enum AlbumError: LocalizedError {
    case authentication
    case server(String)
    var errorDescription: String? {
        switch self {
        case .authentication: return "请验证相册访问身份"
        case .server(let value): return value
        }
    }
}
enum SharedAlbumsAPI {
    /// Moments/albums/favorites server; nil when no server address is configured.
    static var base: URL? { ServerConfig.momentsBase }
    static func request(_ path: String, body: [String: String]? = nil) async throws -> Data {
        guard let base else { throw AlbumError.server("未设置服务器地址") }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        BeardenAuth.authorize(&request)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw AlbumError.authentication }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AlbumError.server(error ?? "相册请求失败（\(http.statusCode)）")
        }
        return data
    }
    static func albums(_ action: String? = nil, body: [String: String]? = nil) async throws -> [SharedAlbum] {
        let path = "api/albums" + (action.map { "/" + $0 } ?? "")
        return try JSONDecoder().decode(SharedAlbumResponse.self, from: await request(path, body: body)).albums
    }
}

@MainActor
private final class SharedAlbumStore: ObservableObject {
    @Published var albums: [SharedAlbum] = []
    @Published var needsLogin = false
    @Published var error: String?
    @Published var loading = false
    func refresh() async {
        loading = true
        defer { loading = false }
        do { albums = try await SharedAlbumsAPI.albums(); needsLogin = false; error = nil }
        catch { handle(error) }
    }
    func change(_ action: String, body: [String: String]) async throws {
        do { albums = try await SharedAlbumsAPI.albums(action, body: body); error = nil }
        catch { handle(error); throw error }
    }
    func handle(_ value: Error) {
        if case AlbumError.authentication = value { needsLogin = true; albums = [] }
        error = value.localizedDescription
    }
}

struct SharedAlbumsView: View {
    @StateObject private var store = SharedAlbumStore()
    @State private var creating = false
    @State private var albumName = ""
    @State private var password = ""
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 18) {
                    if store.needsLogin { loginCard }
                    else {
                        if let error = store.error {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试") { Task { await store.refresh() } }
                        }
                        if store.loading { ProgressView() }
                        if store.albums.isEmpty && !store.loading && store.error == nil {
                            ContentUnavailableView("建一本共同的相册", systemImage: "photo.stack", description: Text("你和助手都可以上传照片、查看照片和修改相册名称。"))
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                            ForEach(store.albums) { album in
                                NavigationLink { SharedAlbumDetailView(store: store, albumID: album.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        GeometryReader { proxy in
                                            Group {
                                                if let photo = album.coverPhoto { SharedPhotoImage(photo: photo, fill: true) }
                                                else { Color.pink.opacity(0.10).overlay(Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.pink.opacity(0.6))) }
                                            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 20))
                                        Text(album.name).font(.headline).lineLimit(1)
                                        Text("\(album.photos.count) 张照片").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(18)
            }.refreshable { await store.refresh() }
        }
        .navigationTitle("相册").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { albumName = ""; creating = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建相册").disabled(store.needsLogin || busy)
        } }
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
        .alert("新建相册", isPresented: $creating) {
            TextField("相册名称", text: $albumName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                busy = true
                Task { defer { busy = false }; try? await store.change("create", body: ["name": albumName]) }
            }.disabled(albumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var loginCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.pink)
            Text("我们的相册").font(.title2.bold())
            Text("相册只对你和助手开放。首次使用请输入已有的朋友圈账号口令，验证后即可共享。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("朋友圈账号口令", text: $password).textContentType(.password).padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            if let error = store.error, error != AlbumError.authentication.localizedDescription { Text(error).font(.caption).foregroundStyle(.red) }
            Button(busy ? "正在连接…" : "连接相册") {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        _ = try await SharedAlbumsAPI.request("api/login", body: ["pw": password])
                        password = ""
                        await store.refresh()
                        await FavoriteStore.shared.sync()
                    } catch { store.error = "验证未成功，请检查口令或网络后重试。" }
                }
            }.buttonStyle(.borderedProminent).tint(.pink).disabled(password.isEmpty || busy)
        }.padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26)).padding(.top, 32)
    }
}

private struct SharedAlbumDetailView: View {
    @ObservedObject var store: SharedAlbumStore
    let albumID: String
    @State private var selection: [PhotosPickerItem] = []
    @State private var renaming = false
    @State private var name = ""
    @State private var uploading = false
    @State private var progress = ""
    @State private var error: String?
    @State private var opened: SharedPhoto?
    private var album: SharedAlbum? { store.albums.first { $0.id == albumID } }
    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 12) {
                    if uploading { ProgressView(progress).padding() }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
                    if album?.photos.isEmpty == true { ContentUnavailableView("还没有照片", systemImage: "photo", description: Text("点右上角添加，或者让助手传一张过来。")) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(album?.photos ?? []) { photo in
                            Button { opened = photo } label: {
                                GeometryReader { proxy in
                                    SharedPhotoImage(photo: photo, fill: true).frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                }.aspectRatio(1, contentMode: .fit)
                            }.buttonStyle(.plain).accessibilityLabel(photo.caption.isEmpty ? "查看照片" : photo.caption)
                            .contextMenu {
                                if album?.coverPhotoId == photo.id {
                                    Button("恢复默认封面", systemImage: "arrow.uturn.backward") { setCover(nil) }
                                } else {
                                    Button("设为封面", systemImage: "photo.badge.checkmark") { setCover(photo.id) }
                                }
                            }
                        }
                    }
                }.padding(12)
            }.refreshable { await store.refresh() }
        }
        .navigationTitle(album?.name ?? "相册").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
            PhotosPicker(selection: $selection, maxSelectionCount: 9, matching: .images) { Image(systemName: "plus") }.disabled(uploading || store.needsLogin)
            Button { name = album?.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }.accessibilityLabel("修改相册名称")
        } }
        .alert("修改相册名称", isPresented: $renaming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { do { try await store.change("rename", body: ["album_id": albumID, "name": name]) } catch { self.error = error.localizedDescription } } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty, !uploading else { return }
            uploading = true
            Task {
                defer { uploading = false; selection = [] }
                error = nil
                for (index, item) in items.enumerated() {
                    progress = "正在上传 \(index + 1)/\(items.count)"
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw AlbumError.server("读取照片失败") }
                        let ratio = min(1, 2400 / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                        let format = UIGraphicsImageRendererFormat(); format.scale = 1
                        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                        guard let jpg = resized.jpegData(compressionQuality: 0.88) else { throw AlbumError.server("照片转换失败") }
                        try await store.change("upload", body: ["album_id": albumID, "image_base64": jpg.base64EncodedString()])
                    } catch { self.error = "已上传 \(index) 张；第 \(index + 1) 张未成功：\(error.localizedDescription)"; break }
                }
            }
        }
        .fullScreenCover(item: $opened) { photo in
            SharedAlbumPhotoViewer(photo: photo, isCover: album?.coverPhotoId == photo.id) { setCover(album?.coverPhotoId == photo.id ? nil : photo.id) }
        }
    }
    private func setCover(_ photoID: String?) {
        Task {
            do { try await store.change("cover", body: ["album_id": albumID, "photo_id": photoID ?? ""]) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SharedPhotoImage: View {
    let photo: SharedPhoto
    var fill = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
            else if failed { Color.pink.opacity(0.1).overlay(Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")) }
            else { Color.pink.opacity(0.08).overlay(ProgressView()) }
        }.task(id: photo.id) {
            do {
                let data = try await SharedAlbumsAPI.request("api/albums/photos/\(photo.id)")
                guard let decoded = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                image = decoded
            } catch { failed = true }
        }
    }
}

private struct SharedAlbumPhotoViewer: View {
    let photo: SharedPhoto
    var isCover = false
    var toggleCover: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                SharedPhotoImage(photo: photo).scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = min(max($0.magnification, 1), 5) }.onEnded { _ in withAnimation { scale = 1 } })
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if !photo.caption.isEmpty { Text(photo.caption) }
                    Text("\(photo.author == "owner" ? "我" : "助手") · \(Date(timeIntervalSince1970: photo.createdAt / 1000).formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }.foregroundStyle(.white).padding()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.white) }
                if let toggleCover {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(isCover ? "恢复默认封面" : "设为封面", systemImage: isCover ? "arrow.uturn.backward" : "photo.badge.checkmark") { toggleCover(); dismiss() }
                        } label: { Image(systemName: "ellipsis") }.tint(.white)
                    }
                }
            }
        }
    }
}
