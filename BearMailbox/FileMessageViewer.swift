import SwiftUI
import UIKit
import QuickLook
import AVKit
import Photos

/// 聊天文件消息的应用内查看页：先下载到本地缓存（带进度），可预览的类型用 QuickLook 展示，
/// 其他类型（压缩包等）显示文件信息页。右上角菜单提供保存到文件、用其他应用打开、收藏。
struct FileMessageViewer: View {
    let name: String
    var onFavorite: (() async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var exporting = false
    @State private var sharing = false
    @State private var favoriteState: String?

    private var displayName: String {
        name.replacingOccurrences(of: "^\\d+-", with: "", options: .regularExpression)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let localURL {
                    if QLPreviewController.canPreview(localURL as NSURL) {
                        FileQuickLookView(url: localURL).ignoresSafeArea(edges: .bottom)
                    } else {
                        infoPage(url: localURL)
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(errorMessage).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }
                    }.padding()
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(displayName).font(.subheadline).lineLimit(2).multilineTextAlignment(.center)
                        ProgressView(value: progress).frame(width: 200)
                        Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { exporting = true } label: { Label("保存到文件", systemImage: "square.and.arrow.down") }
                        Button { sharing = true } label: { Label("转发 / 用其他应用打开", systemImage: "square.and.arrow.up") }
                        if let onFavorite {
                            Button {
                                Task {
                                    do { try await onFavorite(); favoriteState = "已收藏" }
                                    catch { favoriteState = "收藏未成功：\(error.localizedDescription)" }
                                }
                            } label: { Label("收藏", systemImage: "star") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(localURL == nil)
                }
            }
            .sheet(isPresented: $exporting) {
                if let localURL { FileExportPicker(url: localURL).ignoresSafeArea() }
            }
            .sheet(isPresented: $sharing) {
                if let localURL { FileShareSheet(url: localURL).ignoresSafeArea() }
            }
            .alert(favoriteState ?? "", isPresented: Binding(get: { favoriteState != nil }, set: { if !$0 { favoriteState = nil } })) {
                Button("好") { favoriteState = nil }
            }
        }
        .task { await load() }
    }

    private func infoPage(url: URL) -> some View {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ext = url.pathExtension.lowercased()
        let icon = ["zip", "rar", "7z", "tar", "gz"].contains(ext) ? "doc.zipper" : "doc.fill"
        return VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 56)).foregroundStyle(.secondary)
            Text(displayName).font(.headline).multilineTextAlignment(.center).padding(.horizontal)
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                .font(.subheadline).foregroundStyle(.secondary)
            Text("此类文件无法直接预览，可通过右上角菜单保存或用其他应用打开。")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Button { sharing = true } label: { Text("用其他应用打开").padding(.horizontal, 18).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent)
        }
    }

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func load() async {
        errorMessage = nil
        progress = 0
        let target = Self.cacheDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: target.path) {
            localURL = target
            return
        }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: API.fileURL(name))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let expected = response.expectedContentLength
            var data = Data()
            if expected > 0 { data.reserveCapacity(Int(expected)) }
            var buffer = [UInt8]()
            buffer.reserveCapacity(65_536)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { progress = min(1, Double(data.count) / Double(expected)) }
                }
            }
            data.append(contentsOf: buffer)
            progress = 1
            try data.write(to: target, options: .atomic)
            localURL = target
        } catch {
            errorMessage = "下载未成功：\(error.localizedDescription)"
        }
    }
}

private struct FileQuickLookView: UIViewControllerRepresentable {
    let url: URL

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }
}

private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

private struct FileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 视频消息


/// 视频消息气泡：首帧缩略图 + 时长 + 播放图标。
struct VideoThumbnailBubble: View {
    let name: String
    let onOpen: () -> Void
    @State private var thumbnail: UIImage?
    @State private var duration: String = ""

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.18)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 4)
            }
            .frame(width: 180, height: 240)
            .overlay(alignment: .bottomTrailing) {
                if !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: name) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: API.fileURL(name))
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
            let total = Int(seconds.rounded())
            duration = String(format: "%d:%02d", total / 60, total % 60)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 540, height: 720)
        if let image = try? await generator.image(at: .zero).image {
            thumbnail = UIImage(cgImage: image)
        }
    }
}

/// 全屏视频播放页，右上角菜单：保存到相册、转发 / 用其他应用打开、收藏。
struct VideoMessageViewer: View {
    let name: String
    var onFavorite: (() async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var localURL: URL?
    @State private var working = false
    @State private var sharing = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                }
                if working { ProgressView().tint(.white) }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { player?.pause(); dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await saveToPhotos() } } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                        Button { Task { if await download() != nil { sharing = true } } } label: {
                            Label("转发 / 用其他应用打开", systemImage: "square.and.arrow.up")
                        }
                        if let onFavorite {
                            Button {
                                Task {
                                    do { try await onFavorite(); notice = "已收藏" }
                                    catch { notice = "收藏未成功：\(error.localizedDescription)" }
                                }
                            } label: { Label("收藏", systemImage: "star") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $sharing) {
                if let localURL { FileShareSheet(url: localURL).ignoresSafeArea() }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") { notice = nil }
            }
        }
        .onAppear {
            let p = AVPlayer(url: API.fileURL(name))
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func download() async -> URL? {
        if let localURL { return localURL }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: target.path) { localURL = target; return target }
        working = true
        defer { working = false }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: API.fileURL(name))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            localURL = target
            return target
        } catch {
            notice = "下载未成功：\(error.localizedDescription)"
            return nil
        }
    }

    @MainActor
    private func saveToPhotos() async {
        guard let url = await download() else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            notice = "没有相册写入权限"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            notice = "已保存到相册"
        } catch {
            notice = "保存未成功：\(error.localizedDescription)"
        }
    }
}
