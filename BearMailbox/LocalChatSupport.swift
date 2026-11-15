import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PDFKit

struct ChatPeerTitle: View {
    let name: String
    let typing: Bool
    var status: String = "在线"
    var body: some View {
        VStack(spacing: 1) {
            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(typing ? "对方正在输入…" : status)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(typing ? Color.pink.opacity(0.82) : Color.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .modifier(BubbleGlass(shape: Capsule()))
    }
}

struct LocalChatAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mime: String
    var url: URL { Self.directory.appendingPathComponent(id) }
    var isImage: Bool { mime.hasPrefix("image/") }
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AIChatAttachments", isDirectory: true)
    }
    static func save(_ data: Data, name: String, mime: String? = nil) throws -> Self {
        guard data.count <= 20 * 1024 * 1024 else { throw AlbumError.server("每个聊天附件最多 20 MB") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: name).pathExtension
        let id = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let value = Self(id: id, name: name, mime: mime ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
        try data.write(to: value.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return value
    }
    static func saveImage(_ image: UIImage) throws -> Self {
        let factor = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = scaled.jpegData(compressionQuality: 0.85) else { throw AlbumError.server("图片无法读取") }
        return try save(data, name: "照片.jpg", mime: "image/jpeg")
    }
    func modelContent() throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        if isImage { return [["type": "image", "data": data.base64EncodedString(), "mimeType": mime]] }
        if mime == "application/pdf", let document = PDFDocument(data: data), let text = document.string, !text.isEmpty {
            return [["type": "text", "text": "附件 \(name)：\n" + String(text.prefix(50000))]]
        }
        if let text = String(data: data, encoding: .utf8) {
            return [["type": "text", "text": "附件 \(name)：\n" + String(text.prefix(50000))]]
        }
        return [["type": "text", "text": "[附件 \(name)，类型 \(mime)。该格式尚不能转为模型输入，不要声称已经阅读或听到其内容。]"]]
    }
}

struct LocalChatAttachmentsView: View {
    let files: [LocalChatAttachment]
    let onImage: (URL) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let photos = files.filter(\.isImage)
            if !photos.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: photos.count == 1 ? 1 : (photos.count == 4 ? 2 : 3)), spacing: 4) {
                    ForEach(photos) { file in
                        Button { onImage(file.url) } label: {
                            if let image = UIImage(contentsOfFile: file.url.path) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(height: photos.count == 1 ? 210 : 90).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 250)
            }
            ForEach(files.filter { !$0.isImage }) { file in
                if file.mime.hasPrefix("audio/") { VoiceMessagePlayer(url: file.url) }
                else { ShareLink(item: file.url) { Label(file.name, systemImage: "doc.fill").font(.system(size: 14)).lineLimit(2) }
                    .padding(12).modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 20))) }
            }
        }
    }
}

struct SharedAIAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("验证后，熊窝内添加的 AI 都能使用朋友圈和共享相册，并只读查看收藏。每个 AI 使用自己的身份。")
                    SecureField("原朋友圈口令", text: $password)
                    Button(busy ? "验证中…" : "验证并开放") {
                        busy = true
                        Task {
                            defer { busy = false; password = "" }
                            do {
                                _ = try await SharedAlbumsAPI.request("api/login", body: ["pw": password])
                                _ = try await SharedAlbumsAPI.request("api/ai/tools")
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(password.isEmpty || busy)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }.navigationTitle("共享功能").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
