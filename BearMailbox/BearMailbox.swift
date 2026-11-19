// 熊窝 · SwiftUI（iOS 26 Liquid Glass，单文件）
// 接口：
//   GET  /api/messages?since=<上一条id>&limit=<n>&before=<id>   拉消息 [{id, from, text, ts, file?}]，from 是 me / claude；limit 只取最后 n 条，before 只取该 id 之前的
//   POST /api/send                        body {"text": "...", "file": "..."}
//   GET  /api/file/<file>                 取文件/图片
//   POST /api/upload                      body 是文件原始数据，头 X-Filename
// 本版新增：图片消息+点开大图（捏合缩放）/ approve JSON 选择题卡片 / 加号发相册图片 / 设置页选聊天背景
import SwiftUI
import PhotosUI
import Photos
import UIKit
import UniformTypeIdentifiers
import CoreLocation
import AVFoundation
import Speech
import UserNotifications
import CryptoKit
import Observation
import Security
import WebKit
import LinkPresentation
import Translation

// ===== App =====
@main
struct BearMailboxApp: App {
    @AppStorage("appearanceMode") private var appearanceMode = "light"

    init() {
        ServerConfig.registerBundledDefaults()
        // Earlier builds stored the assistant remark under a different key; carry it over once.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "assistantRemark") == nil, let legacy = defaults.string(forKey: "claudeRemark") {
            defaults.set(legacy, forKey: "assistantRemark")
        }
        BeardenAuth.seedNativeCookie()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bear-activity-ui-test") {
            UserDefaults.standard.set(false, forKey: "chat.activity.acceptance")
        }
        #endif
    }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": return .dark
        case "system": return nil
        default: return .light
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--bear-activity-ui-test") {
                    ChatActivityAcceptanceScreen()
                } else { RootView() }
                #else
                RootView()
                #endif
            }.preferredColorScheme(preferredScheme)
        }
    }
}

struct RootView: View {
    private let tabPink = Color(red: 1.00, green: 0.67, blue: 0.80)
    @State private var hidesConversationTabBar = false
    @State private var selectedTab = 0
    @State private var showingMoments = false
    @State private var showingHomecomingSplash = true
    @AppStorage("claudeUnreadCount") private var claudeUnreadCount = 0
    @AppStorage("localAIInboxVersion") private var localAIInboxVersion = 0
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @AppStorage("assistantRemark") private var syncedAssistantRemark = "助手"
    @AppStorage("patSuffix") private var syncedPatSuffix = "并给他两个亿"
    @AppStorage("myNickname") private var syncedMyNickname = "我"

    /// The primary assistant's unread plus every other conversation's inbox unread; re-evaluated whenever the
    /// inbox version or the conversation list changes.
    @State private var otherConversationIDs: [String] = []
    @State private var otherUnreadCount = 0

    private var totalUnreadCount: Int { claudeUnreadCount + otherUnreadCount }

    /// Decodes the conversation list only when it changes.
    private func refreshConversationIDs() {
        guard let data = conversationsJSON.data(using: .utf8),
              let saved = try? JSONDecoder().decode([AIConversation].self, from: data) else {
            otherConversationIDs = []
            refreshOtherUnread()
            return
        }
        otherConversationIDs = saved.map(\.id).filter { $0 != "claude" }
        refreshOtherUnread()
    }

    /// Sums the in-memory inbox snapshots; no disk or decoding work.
    private func refreshOtherUnread() {
        let total = otherConversationIDs.reduce(0) { $0 + LocalAIInbox.entry($1).unreadCount }
        if total != otherUnreadCount { otherUnreadCount = total }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                ConversationListView(hidesRootTabBar: $hidesConversationTabBar)
                    .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
                    .badge(totalUnreadCount)
                    .tag(0)

                ContactsView()
                    .tabItem { Label("通讯录", systemImage: "person.2.fill") }
                    .tag(1)

                DiscoverView(showingMoments: $showingMoments)
                    .tabItem { Label("发现", systemImage: "safari") }
                    .tag(2)

                MeView()
                    .tabItem { Label("我", systemImage: "person.crop.circle.fill") }
                    .tag(3)
            }
            .tint(tabPink)
            .modifier(RootTabBarVisibility(hidden:
                (selectedTab == 0 && hidesConversationTabBar) || (selectedTab == 2 && showingMoments)
            ))

            if showingHomecomingSplash {
                HomecomingSplashView {
                    withAnimation(.easeOut(duration: 0.38)) {
                        showingHomecomingSplash = false
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .task { BearContactProfileSync.shared.schedule(force: true) }
        .onAppear { refreshConversationIDs() }
        .onChange(of: conversationsJSON) { _, _ in refreshConversationIDs() }
        .onChange(of: localAIInboxVersion) { _, _ in refreshOtherUnread() }
        .onChange(of: syncedAssistantRemark) { _, _ in BearContactProfileSync.shared.schedule() }
        .onChange(of: syncedPatSuffix) { _, _ in BearContactProfileSync.shared.schedule() }
        .onChange(of: syncedMyNickname) { _, _ in BearContactProfileSync.shared.schedule() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            BearContactProfileSync.shared.schedule()
        }
    }
}

private struct RootTabBarVisibility: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .toolbar(hidden ? .hidden : .automatic, for: .tabBar)
            .background(TabBarVisibilityBridge(hidden: hidden).frame(width: 0, height: 0))
    }
}

private struct TabBarVisibilityBridge: UIViewRepresentable {
    let hidden: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        applyVisibility(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        applyVisibility(from: uiView)
    }

    private func applyVisibility(from view: UIView) {
        DispatchQueue.main.async {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController,
                   let tabBarController = controller.tabBarController {
                    tabBarController.tabBar.isHidden = hidden
                    tabBarController.view.setNeedsLayout()
                    return
                }
                responder = current.next
            }

            if let tabBarController = self.findTabBarController(from: view.window?.rootViewController) {
                tabBarController.tabBar.isHidden = hidden
                tabBarController.view.setNeedsLayout()
            }
        }
    }

    private func findTabBarController(from controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabBarController = controller as? UITabBarController { return tabBarController }
        if let presented = findTabBarController(from: controller.presentedViewController) { return presented }
        for child in controller.children {
            if let tabBarController = findTabBarController(from: child) { return tabBarController }
        }
        return nil
    }
}

// ===== 服务器配置 =====
// 开源版不内置任何服务器地址。用户在设置页填写自己的服务器地址
// （例如 https://example.com）；留空则只使用本机功能，网络功能会提示
// 未设置服务器地址，不会回落到任何默认域名。原先 app / kanban / moments
// 三个子域名提供的接口，现统一走这一个 host 下的相对路径。
enum ServerConfig {
    static let defaultsKey = "serverBaseURL"

    static var rawValue: String {
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }
        set { UserDefaults.standard.setValue(newValue, forKey: defaultsKey) }
    }

    /// 去掉首尾空白与末尾 `/` 后的地址。
    static var cleaned: String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 用户填写的服务器地址；未填或不合法时为 nil。
    static var baseURL: URL? {
        let value = cleaned
        guard !value.isEmpty, let url = URL(string: value),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    static var host: String? { baseURL?.host }
    static var isConfigured: Bool { baseURL != nil }

    // ----- 打包时可选的预设 -----
    // 若 App bundle 内含 ServerConfig.json，则其中的地址作为默认值（设置页仍可改）。
    // 该文件只在打包时注入，不进仓库（见 .gitignore）。格式：
    // {"baseURL": "https://example.com", "momentsURL": "https://m.example.com", "workbenchURL": "https://w.example.com"}
    // momentsURL / workbenchURL 可省略，省略时与 baseURL 同 host。
    private struct Bundled: Decodable {
        var baseURL: String?
        var momentsURL: String?
        var workbenchURL: String?
    }

    private static let bundled: Bundled? = {
        guard let url = Bundle.main.url(forResource: "ServerConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Bundled.self, from: data)
    }()

    /// 把预设主地址注册为 UserDefaults 默认值；用户在设置里填写的值优先。
    static func registerBundledDefaults() {
        guard let value = bundled?.baseURL, !value.isEmpty else { return }
        UserDefaults.standard.register(defaults: [defaultsKey: value])
    }

    private static func url(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// 仅当用户仍在使用预设主地址时，才采用预设的分服务地址。
    private static func bundledOverride(_ value: String?) -> URL? {
        guard let preset = url(value), let presetBase = url(bundled?.baseURL),
              baseURL?.host == presetBase.host else { return nil }
        return preset
    }

    /// 朋友圈 / 相册 / 收藏服务地址；默认与主地址同 host。
    static var momentsBase: URL? { bundledOverride(bundled?.momentsURL) ?? baseURL }
    /// 工作台 / 额度看板地址；默认与主地址同 host。
    static var workbenchBase: URL? { bundledOverride(bundled?.workbenchURL) ?? baseURL }
    /// 看板网页地址（带 glass=1 参数）。
    static var workbenchWebURL: URL? {
        guard let base = workbenchBase else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "glass", value: "1")]
        return components?.url
    }
}

// ===== API =====
enum API {
    /// 信箱服务器地址，未在设置里填写时为 nil。
    static var base: URL? { ServerConfig.baseURL }
    static let localAttachmentPrefix = "localai/"
    static let localStickerPrefix = "localsticker/"
    static func isLocalFile(_ name: String) -> Bool {
        name.hasPrefix(localAttachmentPrefix) || name.hasPrefix(localStickerPrefix)
    }
    static func fileURL(_ name: String) -> URL {
        // Device-local conversations keep files on this device instead of the mailbox server.
        if name.hasPrefix(localAttachmentPrefix) {
            return LocalChatAttachment.directory.appendingPathComponent(String(name.dropFirst(localAttachmentPrefix.count)))
        }
        if name.hasPrefix(localStickerPrefix) {
            return StickerLibrary.folderURL.appendingPathComponent(String(name.dropFirst(localStickerPrefix.count)))
        }
        // 未设置服务器地址时返回一个不会产生真实请求的 URL，调用方会正常失败，不崩溃。
        guard let base else { return URL(string: "about:blank")! }
        return base.appendingPathComponent("api/file").appendingPathComponent(name)
    }
    static func isImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains((name as NSString).pathExtension.lowercased())
    }
    static func isVideo(_ name: String) -> Bool {
        ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }
    static func isAudio(_ name: String) -> Bool {
        ["m4a", "aac", "mp3", "wav"].contains((name as NSString).pathExtension.lowercased())
    }
}

// ===== 玻璃（iOS 26 用系统 Liquid Glass，旧版回退 material）=====
struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S

    private var edge: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.58),
                Color.white.opacity(0.10),
                Color.white.opacity(0.34)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .background {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.regular, in: shape)
                        .opacity(0.58)
                }
                .overlay(shape.strokeBorder(edge, lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.055), radius: 8, y: 3)
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .opacity(0.46)
                }
                .overlay(shape.strokeBorder(edge, lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.055), radius: 8, y: 3)
        }
#else
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .opacity(0.46)
            }
            .overlay(shape.strokeBorder(edge, lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.055), radius: 8, y: 3)
#endif
    }
}

// ===== 全局背景 =====
private enum AppBackdropImageCache {
    static let images = NSCache<NSNumber, UIImage>()

    static func image(for version: Int) -> UIImage? {
        guard version > 0 else { return nil }
        let key = NSNumber(value: version)
        if let cached = images.object(forKey: key) { return cached }
        guard let loaded = UIImage(contentsOfFile: SettingsView.homeBgPath.path) else { return nil }
        let prepared = screenSized(loaded)
        images.setObject(prepared, forKey: key)
        return prepared
    }

    static func store(_ image: UIImage, version: Int) {
        let prepared = screenSized(image)
        images.setObject(prepared, forKey: NSNumber(value: version))
    }

    /// The backdrop sits under every glass layer, which re-samples it each frame; a
    /// full-resolution photo there costs frames on every screen. Keep it at screen size.
    private static func screenSized(_ image: UIImage) -> UIImage {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let target = max(bounds.width, bounds.height) * scale
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > target * 1.05 else { return image.preparingForDisplay() ?? image }
        let ratio = target / longest
        let size = CGSize(width: image.size.width * image.scale * ratio / scale,
                          height: image.size.height * image.scale * ratio / scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.preparingForDisplay() ?? resized
    }
}

struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("homeBgVersion") private var homeBgVersion = 0

    private var customBackground: UIImage? {
        AppBackdropImageCache.image(for: homeBgVersion)
    }

    var body: some View {
        Group {
            if let customBackground {
                GeometryReader { geo in
                    Image(uiImage: customBackground)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.10))
                }
            } else {
                ZStack {
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                Color(red: 0.10, green: 0.08, blue: 0.13),
                                Color(red: 0.16, green: 0.10, blue: 0.17),
                                Color(red: 0.08, green: 0.11, blue: 0.16)
                            ]
                            : [
                                Color(red: 1.00, green: 0.91, blue: 0.95),
                                Color(red: 0.93, green: 0.90, blue: 1.00),
                                Color(red: 1.00, green: 0.97, blue: 0.91)
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Circle()
                        .fill(Color.pink.opacity(colorScheme == .dark ? 0.16 : 0.24))
                        .frame(width: 280, height: 280)
                        .blur(radius: 55)
                        .offset(x: 150, y: -270)

                    Circle()
                        .fill(Color.purple.opacity(colorScheme == .dark ? 0.15 : 0.17))
                        .frame(width: 320, height: 320)
                        .blur(radius: 65)
                        .offset(x: -170, y: 300)
                }
                // Flatten the blurred gradient into one layer so it is not re-filtered per frame.
                .drawingGroup()
            }
        }
        .ignoresSafeArea()
    }
}

// ===== 消息模型 =====
struct Msg: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let from: String
    let text: String
    let ts: Int
    var file: String?

    var displayedText: String {
        let body = MediaGroupInfo.batchCaption(text)
        if let reply = ReplyInfo.parse(body) { return reply.body }
        return body
    }

    var previewText: String {
        if let file, API.isImage(file) { return "[图片]" }
        if let file, API.isVideo(file) { return "[视频]" }
        if let file { return "[文件] \(file.replacingOccurrences(of: "^\\d+-", with: "", options: .regularExpression))" }
        if LocationInfo.parse(text) != nil { return "[位置]" }
        let value = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "[消息]" : String(value.prefix(52))
    }

    var timestampText: String {
        let raw = ts > 10_000_000_000 ? Double(ts) / 1000 : Double(ts)
        return Date(timeIntervalSince1970: raw)
            .formatted(date: .omitted, time: .shortened)
    }

    var date: Date {
        let raw = ts > 10_000_000_000 ? Double(ts) / 1000 : Double(ts)
        return Date(timeIntervalSince1970: raw)
    }
}

private struct ReplyInfo: Equatable {
    static let prefix = "[[bear-reply|"

    let messageID: Int
    let sender: String
    let preview: String
    let body: String

    static func encode(message: Msg, sender: String, body: String) -> String {
        let senderValue = Data(sender.utf8).base64EncodedString()
        let previewValue = Data(message.previewText.utf8).base64EncodedString()
        return "\(prefix)\(message.id)|\(senderValue)|\(previewValue)]]\n\(body)"
    }

    static func parse(_ raw: String) -> ReplyInfo? {
        guard raw.hasPrefix(prefix), let end = raw.range(of: "]]"),
              end.lowerBound > raw.startIndex else { return nil }
        let start = raw.index(raw.startIndex, offsetBy: prefix.count)
        let parts = raw[start..<end.lowerBound].split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let messageID = Int(parts[0]),
              let senderData = Data(base64Encoded: String(parts[1])),
              let previewData = Data(base64Encoded: String(parts[2])),
              let sender = String(data: senderData, encoding: .utf8),
              let preview = String(data: previewData, encoding: .utf8) else { return nil }
        var body = String(raw[end.upperBound...])
        if body.first == "\n" { body.removeFirst() }
        return ReplyInfo(messageID: messageID, sender: sender, preview: preview, body: body)
    }
}

struct PatInfo: Equatable {
    static let prefix = "[[bear-pat|"

    let actor: String
    let target: String
    let suffix: String

    func displayText(assistantName: String) -> String {
        func currentName(_ name: String) -> String {
            let lower = name.lowercased()
            return lower.contains("claude") || lower == "dog" ? assistantName : name
        }
        return "\(currentName(actor))拍了拍「\(currentName(target))」\(suffix)"
    }

    static func encode(actor: String, target: String, suffix: String) -> String {
        let values = [actor, target, suffix].map { Data($0.utf8).base64EncodedString() }
        return "\(prefix)\(values.joined(separator: "|"))]]"
    }

    static func parse(_ raw: String) -> PatInfo? {
        guard raw.hasPrefix(prefix), let end = raw.range(of: "]]"),
              end.upperBound == raw.endIndex else { return nil }
        let start = raw.index(raw.startIndex, offsetBy: prefix.count)
        let parts = raw[start..<end.lowerBound].split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { value -> String? in
            guard let data = Data(base64Encoded: String(value)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard values.count == 3 else { return nil }
        return PatInfo(actor: values[0], target: values[1], suffix: values[2])
    }
}

private struct LocationInfo: Equatable {
    static let prefix = "[[bear-location|"
    let latitude: Double
    let longitude: Double

    var mapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)")
    }

    static func encode(latitude: Double, longitude: Double) -> String {
        "\(prefix)\(latitude)|\(longitude)]]"
    }

    static func parse(_ raw: String) -> LocationInfo? {
        if raw.hasPrefix(prefix), let end = raw.range(of: "]]"), end.upperBound == raw.endIndex {
            let start = raw.index(raw.startIndex, offsetBy: prefix.count)
            let values = raw[start..<end.lowerBound].split(separator: "|", omittingEmptySubsequences: false)
            guard values.count == 2,
                  let latitude = Double(values[0]),
                  let longitude = Double(values[1]) else { return nil }
            return LocationInfo(latitude: latitude, longitude: longitude)
        }

        // 兼容此前已经发出的“当前位置 + Apple Maps URL”消息。
        guard raw.contains("maps.apple.com"),
              let range = raw.range(of: "ll=") else { return nil }
        let coordinate = raw[range.upperBound...]
            .split(whereSeparator: { $0 == "&" || $0 == "\n" || $0 == " " })
            .first?
            .split(separator: ",")
        guard let coordinate, coordinate.count == 2,
              let latitude = Double(coordinate[0]),
              let longitude = Double(coordinate[1]) else { return nil }
        return LocationInfo(latitude: latitude, longitude: longitude)
    }
}

// 对方发 {"approve":{"title":…,"questions":[{"q":…,"type":"radio|checkbox","options":[…]}]}}
// 渲染成选择题卡片；作答把「【已确认】1) 问题：答案；2) …」当文字发回去（跳过则【已跳过】）
struct ApprovePayload: Equatable {
    struct Question: Equatable {
        let q: String
        let multi: Bool
        let options: [String]
    }
    let title: String?
    let questions: [Question]

    static func parse(_ raw: String) -> ApprovePayload? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {   // 宽容：也吃 ```json 围栏
            t = t.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard t.hasPrefix("{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let a = obj["approve"] as? [String: Any],
              let rawQs = a["questions"] as? [[String: Any]] else { return nil }
        var qs: [Question] = []
        for q in rawQs {
            guard let text = q["q"] as? String,
                  let opts = q["options"] as? [String], !opts.isEmpty else { return nil }
            qs.append(Question(q: text, multi: (q["type"] as? String) == "checkbox", options: opts))
        }
        guard !qs.isEmpty else { return nil }
        return ApprovePayload(title: a["title"] as? String, questions: qs)
    }
}

// ===== 数据层 =====
// Keep a short send (upload + posting its message) alive across an app switch.
// iOS grants finite time; unfinished attachments remain available for retry.
@MainActor
private final class ChatSendBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "熊窝发送消息") { [weak self] in
            self?.end()
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        let value = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }
}

@MainActor
final class ChatStore: ObservableObject {
    // 审批卡的作答状态（放 store 里，滚动回收视图也不丢）
    struct ApproveState {
        var idx = 0
        var picks: [String?]      // 单选
        var sets: [Set<String>]   // 多选
        var customs: [String]     // 每题「别的答案」
        init(n: Int) {
            picks = Array(repeating: nil, count: n)
            sets = Array(repeating: [], count: n)
            customs = Array(repeating: "", count: n)
        }
    }

    @Published var msgs: [Msg] = []
    @Published private(set) var activities: [Int: ChatActivity] = [:]
    private var activityPolling = false
    @Published private(set) var reactions: [Int: [String]] = [:]
    @Published private(set) var isPeerTyping = false
    @Published private(set) var revealedPartCounts: [Int: Int] = [:]
    @Published private(set) var hasLoadedInitialMessages = false
    @Published private(set) var retractedMessageIDs: Set<Int>
    @Published var approveStates: [Int: ApproveState] = [:]
    @Published var answered: Set<Int> = []     // 已作答的审批消息（本地即时隐藏；回显后历史判断兜底）
    private var approveCache: [Int: ApprovePayload?] = [:]
    private var approvalParseMisses: Set<Int> = []
    private var base: URL? { API.base }
    private var last = 0
    /// 一页拉几条历史。首次只拉最近 50 条，往上翻再按页取。
    static let messagePageSize = 50
    /// 已加载窗口之外是否还有更早的消息（按每次返回的条数判断）。
    @Published private(set) var hasOlderMessages = false
    private var loadingOlder = false
    private var timer: Timer?
    private var started = false
    /// 打开的聊天/列表页数量；只有都离开了才停轮询，切页时先后的顺序不会误停。
    private var pollRetainCount = 0
    private var isPolling = false
    private var pollAgain = false
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var pollGeneration = UUID()
    private var pollRequestTask: Task<(Data, URLResponse), Error>?
    private var isPullingReactions = false
    private var typingTimeout: Task<Void, Never>?
    private var queuedPeerMessages: [Msg] = []
    private var peerRevealTask: Task<Void, Never>?
    private var peerRevealGeneration = UUID()
    private(set) var localPeer: AIConversation?
    @Published private(set) var localMessages: [LocalAIMessage] = []
    @Published var localError: String?
    private var localIDBase = 0
    private var localUploads: [String: LocalChatAttachment] = [:]
    private var localReplyDebounce: Task<Void, Never>?
    private var localReplyInFlight = false
    private var localReplyAgain = false
    private var localActivity = ChatActivity()
    private var localStreamRaw = ""
    private var localStreamEmitted = 0
    private static func readingDelay(for text: String) -> UInt64 {
        // Keep one clock for both split parts and separate server messages.
        // Even a short bubble needs a visible pause; longer ones need reading time.
        UInt64(min(3.2, max(1.2, 0.8 + Double(text.count) * 0.035)) * 1_000_000_000)
    }
    init() {
        let saved = UserDefaults.standard.array(forKey: "claudeRetractedMessageIDs") as? [Int] ?? []
        retractedMessageIDs = Set(saved)
    }

    /// Device-local AI conversation backed by configuredAI.messages.<id>; the provider
    /// connection of the conversation is used for replies instead of the mailbox server.
    init(localPeer: AIConversation) {
        self.localPeer = localPeer
        retractedMessageIDs = []
        localIDBase = Self.localIDBase(for: localPeer.id)
        hiddenMessageIDs = Set(UserDefaults.standard.array(forKey: "configuredAI.\(localPeer.id).hiddenMessageIDs") as? [Int] ?? [])
        // Load history before the first frame so the timeline opens populated at the bottom.
        if let data = UserDefaults.standard.data(forKey: "configuredAI.messages.\(localPeer.id)"),
           let saved = try? JSONDecoder().decode([LocalAIMessage].self, from: data) {
            localMessages = saved
        }
        MainActor.assumeIsolated {
            rebuildLocalTimeline()
            hasLoadedInitialMessages = true
        }
    }

    func start() {
        pollRetainCount += 1
        if localPeer != nil {
            guard !started else { return }
            started = true
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finishPendingReveals() }
            }
            return
        }
        guard !started else {
            Task { await poll() }
            return
        }
        started = true
        Task { await poll() }
        // 聊天页开着时轮询放宽到 5 秒：2 秒一轮时，附属状态的写回会反复触发
        // 整个聊天页重绘，打字时页面跟着一跳一跳。
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeFromBackground() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finishPendingReveals() }
        }
    }

    /// 引用计数归零时才真正停轮询：清掉 5 秒 Timer、取消在途请求、摘掉前后台监听。
    /// 聊天页和对话列表的 onDisappear 各调一次，切页时先后的顺序不会误停。
    func stop() {
        pollRetainCount = max(0, pollRetainCount - 1)
        guard pollRetainCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        pollGeneration = UUID()
        pollRequestTask?.cancel()
        pollRequestTask = nil
        isPolling = false
        pollAgain = false
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
        started = false
    }

    private func finishPendingReveals() {
        peerRevealGeneration = UUID()
        peerRevealTask?.cancel()
        peerRevealTask = nil
        let pending = queuedPeerMessages
        queuedPeerMessages.removeAll()
        revealedPartCounts.removeAll()
        appendDisplayed(pending)
        typingTimeout?.cancel()
        isPeerTyping = false
    }

    private func resumeFromBackground() {
        // A suspended URLSession request must not hold the polling gate forever.
        // Its eventual completion belongs to the old generation and is ignored.
        pollGeneration = UUID()
        pollRequestTask?.cancel()
        pollRequestTask = nil
        isPolling = false
        pollAgain = false
        finishPendingReveals()
        Task { await poll() }
    }

    @MainActor
    func poll() async {
        guard localPeer == nil else { return }
        guard let base else { return }
        guard !isPolling else { pollAgain = true; return }
        let generation = pollGeneration
        isPolling = true
        defer {
            if generation == pollGeneration {
                pollRequestTask = nil
                isPolling = false
                if pollAgain {
                    pollAgain = false
                    Task { await poll() }
                }
            }
        }
        let since = last
        var c = URLComponents(url: base.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "since", value: String(since))]
        if !hasLoadedInitialMessages {
            // 首次只拉最近一页；老服务器会忽略 limit，客户端再取后 50 条。
            queryItems.append(URLQueryItem(name: "limit", value: String(Self.messagePageSize)))
        }
        c.queryItems = queryItems
        var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        let requestTask = Task { try await URLSession.shared.data(for: request) }
        pollRequestTask = requestTask
        guard let (data, response) = try? await requestTask.value,
              generation == pollGeneration,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode([Msg].self, from: data)
        }.value
        guard generation == pollGeneration, let list = decoded else { return }
        let isInitialLoad = !hasLoadedInitialMessages
        if isInitialLoad { hasLoadedInitialMessages = true }
        let fresh = list.filter { $0.id > last }
        // 没有新消息的空轮询什么状态都不改：不拉 typing/forwarded，不补
        // reactions/activities，不写任何 @Published。这样打字时页面不会
        // 每 5 秒被重绘一次；附属状态（对方正在输入、表情、动态）下次
        // 真有新消息时再一起补。
        // The assistant's typing flag is reported by the bridge as soon as a reply
        // starts streaming, before any message exists, so it is checked on every
        // poll; it only writes state when the value actually changes.
        Task { await refreshPeerTyping() }
        guard !fresh.isEmpty else { return }
        Task { await refreshForwarded() }
        last = max(last, fresh.map(\.id).max() ?? last)
        // 首次只留最近一页进内存，剩下的历史往上翻时再按页取；
        // 新消息本来就只有几条，原样处理。
        let page = isInitialLoad ? Array(fresh.suffix(Self.messagePageSize)) : fresh
        if isInitialLoad { hasOlderMessages = fresh.count >= Self.messagePageSize }
        if isInitialLoad || UIApplication.shared.applicationState != .active {
            // 历史记录首次载入时一次显示，不能把旧消息重新演一遍。
            appendDisplayed(page)
        } else {
            // 自己刚发出的消息立即显示；对方同一轮产生的多个气泡进入展示队列。
            appendDisplayed(page.filter { $0.from == "me" })
            enqueuePeerMessages(page.filter { $0.from != "me" })
        }
        // 表情反应失败或变慢不能再挡住聊天记录；消息先显示，再补反应。
        Task { await pullReactions() }
        Task { await pullActivities() }
    }

    /// 往上翻加载更早的一页：取已加载窗口之前 50 条，插到队首。返回实际取到的条数。
    /// 老服务器会忽略 before/limit、把全部历史都返回，这时只取窗口之前的最后 50 条。
    func loadOlderMessages() async -> Int {
        guard localPeer == nil, let base, let oldest = msgs.first?.id, !loadingOlder else { return 0 }
        loadingOlder = true
        defer { loadingOlder = false }
        var c = URLComponents(url: base.appendingPathComponent("api/messages"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "before", value: String(oldest)),
            URLQueryItem(name: "limit", value: String(Self.messagePageSize)),
        ]
        var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return 0 }
        let decoded = await Task.detached(priority: .userInitiated) {
            try? JSONDecoder().decode([Msg].self, from: data)
        }.value
        guard let list = decoded else { return 0 }
        let older = Array(list.filter { $0.id < oldest }
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
            .suffix(Self.messagePageSize))
        guard !older.isEmpty else {
            hasOlderMessages = false
            return 0
        }
        msgs.insert(contentsOf: older, at: 0)
        hasOlderMessages = older.count >= Self.messagePageSize
        return older.count
    }

    private func pullActivities() async {
        guard UserDefaults.standard.bool(forKey: "chat.activity.claude"), !activityPolling else { return }
        activityPolling = true
        defer { activityPolling = false }
        let ids = msgs.suffix(80).filter { $0.from != "me" }.map(\.id)
        guard let fetched = try? await RemoteChatActivityClient.fetch(messageIDs: ids) else { return }
        var next = activities
        for (id, activity) in fetched { next[id] = activity }
        if next != activities { activities = next }
    }

    private func appendDisplayed(_ messages: [Msg]) {
        guard !messages.isEmpty else { return }
        let incoming = messages.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
        if let tail = msgs.last, let first = incoming.first,
           first.ts < tail.ts || (first.ts == tail.ts && first.id < tail.id) {
            // Only migrated/out-of-order records require sorting existing history.
            msgs = (msgs + incoming).sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }
        } else {
            msgs.append(contentsOf: incoming)
        }
    }

    private func enqueuePeerMessages(_ messages: [Msg]) {
        guard !messages.isEmpty else { return }
        queuedPeerMessages.append(contentsOf: messages.sorted {
            $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id
        })
        typingTimeout?.cancel()
        isPeerTyping = true
        guard peerRevealTask == nil else { return }

        let generation = UUID()
        peerRevealGeneration = generation
        peerRevealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.peerRevealGeneration {
                    self.peerRevealTask = nil
                    self.isPeerTyping = false
                }
            }
            while !self.queuedPeerMessages.isEmpty {
                let next = self.queuedPeerMessages.removeFirst()
                let parts = next.file == nil
                    ? MessageBubbleSplitter.parts(next.displayedText, enabled: true) : [next.displayedText]
                let partCount = parts.count
                // Insert at the final layout position. The scroll view's bottom
                // size-change anchor owns viewport adjustment; animating this
                // mutation as well makes rows originate below the composer.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if partCount > 1 { self.revealedPartCounts[next.id] = 1 }
                    self.appendDisplayed([next])
                }
                // Finish this message's parts before revealing the next message.
                // Progress belongs to the store, so lazy row recycling cannot replay it.
                if partCount > 1 {
                    for count in 2...partCount {
                        try? await Task.sleep(nanoseconds: Self.readingDelay(for: parts[count - 2]))
                        guard !Task.isCancelled else { return }
                        withTransaction(transaction) {
                            self.revealedPartCounts[next.id] = count
                        }
                    }
                    withTransaction(transaction) {
                        self.revealedPartCounts.removeValue(forKey: next.id)
                    }
                }
                self.isPeerTyping = !self.queuedPeerMessages.isEmpty
                // Keep the cooldown even when the queue is temporarily empty.
                // A following poll must not bypass the pause and cause a burst.
                try? await Task.sleep(nanoseconds: Self.readingDelay(for: parts.last ?? ""))
                guard !Task.isCancelled else { return }
            }
        }
    }

    @discardableResult
    func send(_ text: String, file: String? = nil) async -> Bool {
        if localPeer != nil { return await sendLocal(text, file: file) }
        let lease = ChatSendBackgroundLease()
        defer { lease.end() }
        guard let base else { return false }
        var r = URLRequest(url: base.appendingPathComponent("api/send"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let file { body["file"] = file }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 30
        guard let (_, response) = try? await URLSession.shared.data(for: r),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        await poll()
        return true
    }

    func isRetracted(_ messageID: Int) -> Bool {
        retractedMessageIDs.contains(messageID)
    }

    /// 本次运行内撤回的时间，用于决定撤回提示上是否显示「重新编辑」。
    private(set) var retractedAt: [Int: Date] = [:]
    func canReEdit(_ message: Msg) -> Bool {
        guard message.from == "me", message.file == nil, let at = retractedAt[message.id] else { return false }
        return Date().timeIntervalSince(at) < 300
    }

    private var lastTypingPing = Date.distantPast
    /// 输入框有字且在变化时节流上报「输入中」，服务端据此推迟把连发消息交给助手。
    func pingTyping(_ text: String) {
        guard localPeer == nil, !text.isEmpty else { return }
        guard let base else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTypingPing) >= 2 else { return }
        lastTypingPing = now
        let url = base.appendingPathComponent("api/typing")
        // 只发请求、不读结果、不碰任何界面状态
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    @discardableResult
    func retract(_ message: Msg) async -> Bool {
        guard message.from == "me" else { return false }
        if localPeer != nil { return await retractLocal(message) }
        guard let base else { return false }
        var request = URLRequest(url: base.appendingPathComponent("api/retract"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": message.id])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        retractedAt[message.id] = Date()
        retractedMessageIDs.insert(message.id)
        reactions.removeValue(forKey: message.id)
        persistRetractedMessages()
        return true
    }

    // 本机删除：只隐藏在这台设备上，不动服务器
    @Published private(set) var hiddenMessageIDs: Set<Int> = Set(UserDefaults.standard.array(forKey: "claudeHiddenMessageIDs") as? [Int] ?? [])
    func isHiddenLocally(_ id: Int) -> Bool { hiddenMessageIDs.contains(id) }
    private var hiddenMessagesKey: String {
        localPeer.map { "configuredAI.\($0.id).hiddenMessageIDs" } ?? "claudeHiddenMessageIDs"
    }
    func hideLocally(_ message: Msg) {
        var ids: Set<Int> = [message.id]
        if let group = MediaGroupInfo.parse(message.text) {
            for m in msgs where MediaGroupInfo.parse(m.text)?.id == group.id { ids.insert(m.id) }
        }
        hiddenMessageIDs.formUnion(ids)
        UserDefaults.standard.set(hiddenMessageIDs.sorted(), forKey: hiddenMessagesKey)
    }

    // 已交给助手的自己的消息 id，用来决定是否还能撤回
    @Published private(set) var forwardedMessageIDs: Set<Int> = []
    private func refreshForwarded() async {
        // 全量过滤、请求和解 JSON 都在后台做，主线程只写回结果，
        // 避免每轮 poll 都在主线程扫一遍整个消息历史、卡住输入。
        let snapshot = msgs
        let known = forwardedMessageIDs
        guard let base else { return }
        let ids = await Task.detached(priority: .utility) { () -> [Int]? in
            let cutoff = Date().timeIntervalSince1970 - 180
            let recent = snapshot.filter { m in
                let raw = m.ts > 10_000_000_000 ? Double(m.ts) / 1000 : Double(m.ts)
                return m.from == "me" && raw > cutoff && !known.contains(m.id)
            }
            guard let first = recent.map(\.id).min() else { return nil }
            var c = URLComponents(url: base.appendingPathComponent("api/forwarded"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "since", value: String(first - 1))]
            var request = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 5
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
            return try? JSONDecoder().decode([Int].self, from: data)
        }.value
        guard let ids else { return }
        let next = forwardedMessageIDs.union(ids)
        if next != forwardedMessageIDs { forwardedMessageIDs = next }
    }

    private func persistRetractedMessages() {
        UserDefaults.standard.set(retractedMessageIDs.sorted(), forKey: "claudeRetractedMessageIDs")
    }

    func toggleReaction(_ emoji: String, for messageID: Int) {
        if localPeer != nil {
            Task { @MainActor in self.toggleLocalReaction(emoji, for: messageID) }
            return
        }
        Task { @MainActor in
            guard let base else { return }
            var request = URLRequest(url: base.appendingPathComponent("api/react"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": messageID, "emoji": emoji])
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
            await applyReactions(data)
        }
    }

    @MainActor
    private func pullReactions() async {
        guard !isPullingReactions else { return }
        guard let base else { return }
        isPullingReactions = true
        defer { isPullingReactions = false }
        var request = URLRequest(url: base.appendingPathComponent("api/reactions"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        await applyReactions(data)
    }

    @MainActor
    private func applyReactions(_ data: Data) async {
        let decoded = await Task.detached(priority: .utility) {
            try? JSONDecoder().decode([String: [String: [String]]].self, from: data)
        }.value
        guard let raw = decoded else { return }
        var merged: [Int: [String]] = [:]
        for (key, sides) in raw {
            guard let id = Int(key) else { continue }
            var values: [String] = []
            for side in ["me", "claude"] {
                for emoji in sides[side] ?? [] where !values.contains(emoji) {
                    values.append(emoji)
                }
            }
            if !values.isEmpty { merged[id] = values }
        }
        if merged != reactions { reactions = merged }
    }

    /// 标题栏「对方正在输入」只看助手侧信号（claude_at），不受本机输入上报影响。
    private func refreshPeerTyping() async {
        guard let base else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/typing"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let assistantAt = (json["claude_at"] as? NSNumber)?.doubleValue ?? 0
        let now = (json["now"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        let active = assistantAt > 0 && now - assistantAt < 90
        guard peerRevealTask == nil else { return }
        // 值不变时不写 @Published，避免每次轮询都让整个聊天页重绘
        if active { if !isPeerTyping { markPeerTyping() } }
        else if isPeerTyping { typingTimeout?.cancel(); isPeerTyping = false }
    }

    private func markPeerTyping() {
        isPeerTyping = true
        typingTimeout?.cancel()
        typingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(75))
            guard !Task.isCancelled else { return }
            self?.isPeerTyping = false
        }
    }

    // 上传图片：body 是原始数据，文件名放 X-Filename（不要密钥；若服务器以后要口令，在下面加一行 setValue 即可）
    func upload(_ data: Data, name: String) async -> String? {
        if localPeer != nil {
            return await MainActor.run { () -> String? in
                guard let saved = try? LocalChatAttachment.save(data, name: name) else { return nil }
                let key = API.localAttachmentPrefix + saved.id
                self.localUploads[key] = saved
                return key
            }
        }
        let lease = ChatSendBackgroundLease()
        defer { lease.end() }
        guard let base else { return nil }
        var r = URLRequest(url: base.appendingPathComponent("api/upload"))
        r.httpMethod = "POST"
        // 大文件（视频）按体积放宽超时，约 200 KB/s 起算
        r.timeoutInterval = max(90, Double(data.count) / 200_000)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "image.jpg",
                   forHTTPHeaderField: "X-Filename")
        guard let (d, resp) = try? await URLSession.shared.upload(for: r, from: data),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let saved = obj["name"] as? String else { return nil }
        return saved
    }

    // approve JSON 解析（带缓存，滚动不重复解析）
    func approvePayload(for m: Msg) -> ApprovePayload? {
        if approvalParseMisses.contains(m.id) { return nil }
        if let c = approveCache[m.id] { return c }
        let p = m.from == "me" ? nil : ApprovePayload.parse(m.text)
        if let p { approveCache[m.id] = p }
        else { approvalParseMisses.insert(m.id) }
        return p
    }

    // 这条审批 JSON 是否已经答过：后面跟了一条「【已确认】/【已跳过】」的我方消息
    func isAnswered(_ m: Msg) -> Bool {
        if answered.contains(m.id) { return true }
        guard let i = msgs.firstIndex(where: { $0.id == m.id }) else { return false }
        return msgs[(i + 1)...].contains {
            $0.from == "me" && ($0.text.hasPrefix("【已确认】") || $0.text.hasPrefix("【已跳过】"))
        }
    }

    func ensureApproveState(_ id: Int, n: Int) {
        if approveStates[id] == nil { approveStates[id] = ApproveState(n: n) }
    }
}


// ===== Device-local AI conversations in the shared chat view =====
// History stays in configuredAI.messages.<id> as [LocalAIMessage]; the timeline is a
// projection into Msg rows. Row ids are derived from the record index, so records are
// only appended or flagged (withdrawn), never removed, except when history is cleared.
extension ChatStore {
    private static let localPartStride = 32

    fileprivate static func localIDBase(for conversationID: String) -> Int {
        var hash: UInt64 = 5381
        for byte in conversationID.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash % 1000 + 1) * 10_000_000
    }

    var isLocalPeer: Bool { localPeer != nil }

    private var localStorageKey: String { "configuredAI.messages.\(localPeer?.id ?? "")" }

    private func localRowID(_ index: Int, _ part: Int) -> Int {
        localIDBase + (index + 1) * Self.localPartStride + part
    }

    private func localIndex(for rowID: Int) -> Int? {
        let offset = rowID - localIDBase
        guard offset >= Self.localPartStride else { return nil }
        let index = offset / Self.localPartStride - 1
        return localMessages.indices.contains(index) ? index : nil
    }

    @MainActor
    func loadLocalMessages() async {
        let key = localStorageKey
        let saved = await Task.detached(priority: .userInitiated) { () -> [LocalAIMessage] in
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([LocalAIMessage].self, from: data)) ?? []
        }.value
        localMessages = saved
        rebuildLocalTimeline()
        hasLoadedInitialMessages = true
    }

    private func persistLocalMessages() {
        let snapshot = localMessages
        let key = localStorageKey
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    @MainActor
    func updateLocalPeer(_ conversation: AIConversation) {
        guard localPeer?.id == conversation.id else { return }
        localPeer = conversation
        objectWillChange.send()
    }

    @MainActor
    func replaceLocalMessages(_ messages: [LocalAIMessage]) {
        localMessages = messages
        persistLocalMessages()
        rebuildLocalTimeline()
    }

    @MainActor
    func clearLocalHistory() {
        localReplyDebounce?.cancel()
        finishPendingReveals()
        localMessages = []
        hiddenMessageIDs = []
        UserDefaults.standard.removeObject(forKey: hiddenMessagesKey)
        persistLocalMessages()
        rebuildLocalTimeline()
    }

    private func localReplyHeader(_ message: LocalAIMessage, indexByID: [UUID: Int]) -> String {
        guard let replyID = message.replyID, let target = indexByID[replyID] else { return "" }
        let sender = Data((message.replySender ?? "").utf8).base64EncodedString()
        let preview = Data((message.replyPreview ?? "").utf8).base64EncodedString()
        return "\(ReplyInfo.prefix)\(localRowID(target, 0))|\(sender)|\(preview)]]\n"
    }

    private func localRows(at index: Int, indexByID: [UUID: Int]) -> [Msg] {
        let message = localMessages[index]
        let from = message.role == "user" ? "me" : "assistant"
        let ts = Int(message.createdAt.timeIntervalSince1970 * 1000)
        var entries: [(text: String, file: String?)] = []
        if let wire = message.wireText {
            entries.append((wire, (message.attachments?.first).map { API.localAttachmentPrefix + $0.id }))
        } else {
            // Records written by the earlier chat view.
            let header = localReplyHeader(message, indexByID: indexByID)
            let files = message.attachments ?? []
            if let sticker = message.stickerPath {
                entries.append((header, API.localStickerPrefix + URL(fileURLWithPath: sticker).lastPathComponent))
            } else {
                if !message.text.isEmpty || files.isEmpty {
                    entries.append((header + message.text, nil))
                }
                for (offset, file) in files.enumerated() {
                    let caption = offset == 0 && message.text.isEmpty ? header : ""
                    entries.append((caption, API.localAttachmentPrefix + file.id))
                }
            }
        }
        return entries.prefix(Self.localPartStride).enumerated().map { part, entry in
            Msg(id: localRowID(index, part), from: from, text: entry.text, ts: ts, file: entry.file)
        }
    }

    /// Rebuilds the projected timeline. Rows in `deferred` are revealed through the
    /// paced peer queue instead of appearing immediately.
    @MainActor
    private func rebuildLocalTimeline(deferring deferred: Range<Int>? = nil) {
        var indexByID: [UUID: Int] = [:]
        for (index, message) in localMessages.enumerated() { indexByID[message.id] = index }
        var rows: [Msg] = []
        var delayed: [Msg] = []
        var withdrawn = Set<Int>()
        var nextReactions: [Int: [String]] = [:]
        var nextActivities: [Int: ChatActivity] = [:]
        let queued = Set(queuedPeerMessages.map(\.id))
        for index in localMessages.indices {
            let message = localMessages[index]
            let built = localRows(at: index, indexByID: indexByID)
            guard let first = built.first else { continue }
            if message.withdrawn == true { withdrawn.formUnion(built.map(\.id)) }
            var reactionList = message.reactions ?? []
            if let reaction = message.aiReaction, !reactionList.contains(reaction) { reactionList.append(reaction) }
            if !reactionList.isEmpty { nextReactions[first.id] = reactionList }
            if let activity = message.activity, !activity.isEmpty { nextActivities[first.id] = activity }
            if let deferred, deferred.contains(index) {
                delayed.append(contentsOf: built)
            } else {
                rows.append(contentsOf: built.filter { !queued.contains($0.id) })
            }
        }
        if withdrawn != retractedMessageIDs { retractedMessageIDs = withdrawn }
        if nextReactions != reactions { reactions = nextReactions }
        if nextActivities != activities { activities = nextActivities }
        if rows != msgs { msgs = rows }
        if !delayed.isEmpty {
            if UIApplication.shared.applicationState == .active {
                enqueuePeerMessages(delayed)
            } else {
                msgs.append(contentsOf: delayed)
            }
        }
    }

    /// Strips timeline markers so the model receives plain text.
    private func localModelText(_ raw: String) -> String {
        if let pat = PatInfo.parse(raw) {
            return pat.displayText(assistantName: localPeer?.displayName ?? "")
        }
        if let location = LocationInfo.parse(raw) {
            return "[位置] 纬度 \(location.latitude)，经度 \(location.longitude)"
        }
        var body = MediaGroupInfo.parse(raw)?.caption ?? MediaGroupInfo.batchCaption(raw)
        if let reply = ReplyInfo.parse(body) { body = reply.body }
        return body
    }

    @MainActor
    private func sendLocal(_ text: String, file: String?) async -> Bool {
        guard let peer = localPeer else { return false }
        var message = LocalAIMessage(role: "user", text: localModelText(text))
        message.wireText = text
        if let file {
            let attachment = localUploads.removeValue(forKey: file) ?? {
                let id = String(file.dropFirst(API.localAttachmentPrefix.count))
                return LocalChatAttachment(id: id, name: id, mime: UTType(filenameExtension: (id as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            }()
            message.attachments = [attachment]
        }
        var body = MediaGroupInfo.parse(text)?.caption ?? MediaGroupInfo.batchCaption(text)
        if body.isEmpty { body = text }
        if let reply = ReplyInfo.parse(body) {
            message.text = "（引用 \(reply.sender)：\(reply.preview)）\n" + message.text
            message.replyPreview = reply.preview
            message.replySender = reply.sender
            if let index = localIndex(for: reply.messageID) {
                message.replyID = localMessages[index].id
            }
        }
        localMessages.append(message)
        LocalAIInbox.received(message, in: peer.id)
        persistLocalMessages()
        rebuildLocalTimeline()
        scheduleLocalReply()
        return true
    }

    /// Consecutive sends (photo batches, quick follow-ups) are answered in one turn.
    @MainActor
    private func scheduleLocalReply() {
        if localReplyInFlight {
            localReplyAgain = true
            return
        }
        localReplyDebounce?.cancel()
        localReplyDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runLocalReply()
        }
    }

    @MainActor
    private func runLocalReply() async {
        guard let peer = localPeer, !localReplyInFlight else { return }
        guard localMessages.last(where: { $0.withdrawn != true })?.role == "user" else { return }
        // Reactions placed on the peer's messages are passed to the model as plain text.
        var context = localMessages.map { message -> LocalAIMessage in
            guard message.role == "assistant", let list = message.reactions, !list.isEmpty else { return message }
            var copy = message
            copy.text += "\n（对方给这条贴了 \(list.joined())）"
            return copy
        }
        if let digest = AICrossContext.groupDigest(memberID: peer.id, name: peer.displayName) {
            context.insert(digest, at: 0)
        }
        localReplyInFlight = true
        localReplyAgain = false
        localActivity = ChatActivity()
        localError = nil
        typingTimeout?.cancel()
        isPeerTyping = true
        let lease = ChatSendBackgroundLease()
        defer { lease.end() }
        localStreamRaw = ""
        localStreamEmitted = 0
        do {
            let reply = try await MessageBubbleSplitter.$localMarkup.withValue(true) {
                try await AIProviderClient.send(
                messages: context,
                model: peer.model ?? "",
                baseURL: peer.baseURL ?? "",
                apiKey: AIKeychain.load(account: peer.credentialID),
                format: peer.interfaceFormat ?? "OpenAI 兼容",
                nickname: peer.name,
                authMode: peer.authMode,
                credentialID: peer.credentialID,
                conversation: peer,
                onActivity: { [weak self] activity in
                    await MainActor.run {
                        guard let self else { return }
                        self.localActivity = activity
                    }
                },
                onDelta: { [weak self] delta in
                    await MainActor.run {
                        guard let self else { return }
                        self.localStreamRaw += delta
                        // Only segments closed by a wave line are complete bubbles.
                        let complete = MessageBubbleSplitter.waveSegments(self.localStreamRaw).dropLast()
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if complete.count > self.localStreamEmitted {
                            self.appendLocalReplyParts(Array(complete[self.localStreamEmitted...]), peer: peer)
                            self.localStreamEmitted = complete.count
                        }
                    }
                }
                )
            }
            let finalParts = MessageBubbleSplitter.localParts(reply)
            if finalParts.count > localStreamEmitted {
                appendLocalReplyParts(Array(finalParts[localStreamEmitted...]), peer: peer)
            }
            localStreamRaw = ""
            if peerRevealTask == nil { isPeerTyping = false }
        } catch {
            localStreamRaw = ""
            if peerRevealTask == nil { isPeerTyping = false }
            localError = error.localizedDescription
        }
        localReplyInFlight = false
        if localReplyAgain {
            localReplyAgain = false
            scheduleLocalReply()
        }
    }

    /// Index of the newest user message starting with (or containing) the snippet.
    private func localUserMessageIndex(matching snippet: String) -> Int? {
        let key = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = localMessages.indices.reversed().filter {
            localMessages[$0].role == "user" && localMessages[$0].withdrawn != true
        }
        guard !key.isEmpty else { return candidates.first }
        return candidates.first { localModelBody(localMessages[$0]).hasPrefix(key) }
            ?? candidates.first { localModelBody(localMessages[$0]).contains(key) }
    }

    private func localModelBody(_ message: LocalAIMessage) -> String {
        guard message.text.hasPrefix("（引用 "), let end = message.text.firstIndex(of: "\n") else { return message.text }
        return String(message.text[message.text.index(after: end)...])
    }

    private static func markupFields(_ line: String, tag: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[[\(tag)"), trimmed.hasSuffix("]]") else { return nil }
        let inner = trimmed.dropFirst(2 + tag.count).dropLast(2)
        guard inner.isEmpty || inner.hasPrefix("|") else { return nil }
        return inner.isEmpty ? [] : inner.dropFirst().components(separatedBy: "|")
    }

    /// Turns one reply bubble into stored messages, applying pat, quote and reaction markup.
    @MainActor
    private func localReplyMessages(_ part: String, peer: AIConversation, reacted: inout Bool) -> [LocalAIMessage] {
        var result: [LocalAIMessage] = []
        var bodyLines: [String] = []
        var quote: (index: Int?, snippet: String)?
        for line in part.components(separatedBy: "\n") {
            if let fields = Self.markupFields(line, tag: "拍一拍") {
                let suffix = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let target = UserDefaults.standard.string(forKey: "myNickname") ?? "我"
                var pat = LocalAIMessage(role: "assistant", text: "（你拍了拍对方\(suffix)）")
                pat.wireText = PatInfo.encode(actor: peer.displayName, target: target, suffix: suffix.isEmpty ? "" : " \(suffix)")
                result.append(pat)
            } else if let fields = Self.markupFields(line, tag: "贴表情"), let emoji = fields.first?.trimmingCharacters(in: .whitespaces), !emoji.isEmpty {
                if let index = localUserMessageIndex(matching: fields.dropFirst().joined(separator: "|")) {
                    localMessages[index].aiReaction = emoji
                    reacted = true
                }
            } else if let fields = Self.markupFields(line, tag: "引用"), bodyLines.isEmpty, quote == nil {
                let snippet = fields.joined(separator: "|")
                quote = (localUserMessageIndex(matching: snippet), snippet)
            } else {
                bodyLines.append(line)
            }
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return result }
        var message = LocalAIMessage(role: "assistant", text: body)
        if let quote {
            let preview: String
            var rowID = 0
            if let index = quote.index {
                let source = localModelBody(localMessages[index])
                preview = String((source.isEmpty ? "[消息]" : source).prefix(52))
                rowID = localRowID(index, 0)
                message.replyID = localMessages[index].id
            } else {
                preview = quote.snippet
            }
            let sender = UserDefaults.standard.string(forKey: "myNickname") ?? "我"
            message.replyPreview = preview
            message.replySender = sender
            message.text = "（引用 \(sender)：\(preview)）\n" + body
            message.wireText = "\(ReplyInfo.prefix)\(rowID)|\(Data(sender.utf8).base64EncodedString())|\(Data(preview.utf8).base64EncodedString())]]\n" + body
        }
        result.insert(message, at: result.isEmpty ? 0 : result.count)
        return result
    }

    @MainActor
    private func appendLocalReplyParts(_ parts: [String], peer: AIConversation) {
        guard !parts.isEmpty else { return }
        let start = localMessages.count
        let opensTurn = start == 0 || localMessages[start - 1].role == "user"
        var reacted = false
        for part in parts {
            for var message in localReplyMessages(part, peer: peer, reacted: &reacted) {
                if opensTurn && localMessages.count == start && !localActivity.isEmpty { message.activity = localActivity }
                localMessages.append(message)
                LocalAIInbox.received(message, in: peer.id)
            }
        }
        if localMessages.count == start {
            if reacted {
                persistLocalMessages()
                rebuildLocalTimeline()
            }
            return
        }
        persistLocalMessages()
        rebuildLocalTimeline(deferring: start..<localMessages.count)
    }

    @MainActor
    private func retractLocal(_ message: Msg) async -> Bool {
        guard let index = localIndex(for: message.id), localMessages[index].role == "user" else { return false }
        localMessages[index].withdrawn = true
        retractedAt[message.id] = Date()
        persistLocalMessages()
        rebuildLocalTimeline()
        return true
    }

    @MainActor
    private func toggleLocalReaction(_ emoji: String, for messageID: Int) {
        guard let index = localIndex(for: messageID) else { return }
        var list = localMessages[index].reactions ?? []
        if list.contains(emoji) { list.removeAll { $0 == emoji } } else { list.append(emoji) }
        localMessages[index].reactions = list.isEmpty ? nil : list
        persistLocalMessages()
        rebuildLocalTimeline()
    }
}

// ===== 气泡 =====
private enum ChatImageCache {
    private static let memory = NSCache<NSString, NSData>()
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChatImages", isDirectory: true)
    }()

    private static func path(_ name: String) -> URL {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    static func store(_ data: Data, name: String) {
        memory.setObject(data as NSData, forKey: name as NSString)
        let destination = path(name)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: destination, options: .atomic)
        }
    }

    static func data(for name: String) async -> Data? {
        if let data = memory.object(forKey: name as NSString) as Data? {
            return data
        }
        if API.isLocalFile(name) {
            let url = API.fileURL(name)
            return await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        }
        let cachedPath = path(name)
        let localName = name.replacingOccurrences(of: "^\\d+-", with: "", options: .regularExpression)
        let localSticker = StickerLibrary.folderURL.appendingPathComponent(localName)
        let data = await Task.detached(priority: .utility) { () -> Data? in
            if let cached = try? Data(contentsOf: cachedPath) { return cached }
            return try? Data(contentsOf: localSticker)
        }.value
        if let data {
            memory.setObject(data as NSData, forKey: name as NSString)
        }
        return data
    }
}

private struct ChatImageView: View {
    let name: String
    let onOpen: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        Group {
            if let image {
                let size = fittedSize(for: image)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture(perform: onOpen)
            } else if failed {
                Button {
                    Task { await load() }
                } label: {
                    Label("图片未加载，点此重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 13))
                        .frame(width: 190, height: 100)
                        .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: 170, height: 170)
                    .overlay(ProgressView())
            }
        }
        .task(id: name) { await load() }
    }

    private func fittedSize(for image: UIImage) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: 170, height: 170)
        }
        let scale = min(min(240 / image.size.width, 300 / image.size.height), 1)
        return CGSize(
            width: max(72, image.size.width * scale),
            height: max(72, image.size.height * scale)
        )
    }

    @MainActor
    private func load() async {
        if let data = await ChatImageCache.data(for: name), let cached = UIImage(data: data) {
            image = cached
            failed = false
            return
        }
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: API.fileURL(name))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ChatImageCache.store(data, name: name)
            image = decoded
        } catch {
            failed = true
        }
    }
}


enum MessageBubbleSplitter {
    static let marker = "<|bubble|>"

    static let instruction = """
    你正在聊天应用中回复。请自行判断回复应放在一个还是多个聊天气泡里：
    - 简短或紧密相关的内容只用一个气泡，不要为了分而分。
    - 只有话题、语气或交流节奏自然转折时才分成多个气泡，最多 5 个。
    - 想断开的地方单独写一行〰（这一行只有这一个字符）；不要解释这个符号，也不要把它放进代码块。
    """

    static let waveLine = "〰"

    /// Set while a one-to-one device-local reply is requested; enables the markup below.
    @TaskLocal static var localMarkup = false

    static let localMarkupInstruction = """
    聊天里还可以用这些标记（每个标记单独占一行，不要解释标记）：
    - 拍一拍对方：[[拍一拍]]，想加后缀写 [[拍一拍|后缀]]，例如 [[拍一拍|的小脑袋]]
    - 引用对方的某条消息再回复：在气泡第一行写 [[引用|那条消息开头的几个字]]，下一行写回复内容
    - 给对方的某条消息贴表情：[[贴表情|🥰|那条消息开头的几个字]]；省略后面的字就贴在对方最新一条消息上
    对方引用你时，消息开头会出现「（引用 某人：原文）」；对方给你贴的表情会写在你那条消息后面的「（对方给这条贴了 …）」里。
    """

    static var promptInstruction: String {
        localMarkup ? instruction + "\n" + localMarkupInstruction : instruction
    }

    /// Splits on lines consisting only of the wave mark. The last element is the
    /// unfinished tail and is empty when the text ends right after a mark.
    static func waveSegments(_ text: String) -> [String] {
        var segments: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == waveLine {
                segments.append(current.joined(separator: "\n"))
                current = []
            } else {
                current.append(line)
            }
        }
        segments.append(current.joined(separator: "\n"))
        return segments
    }

    /// Bubble split for device-local AI replies: wave lines and the legacy marker.
    static func localParts(_ text: String) -> [String] {
        waveSegments(text)
            .flatMap { parts($0, enabled: true) }
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != waveLine }
    }

    static func parts(_ text: String, enabled: Bool) -> [String] {
        var visible = text
        // A live SSE chunk can end halfway through the hidden marker.
        for count in (1..<marker.count).reversed() where visible.hasSuffix(String(marker.prefix(count))) {
            visible.removeLast(count)
            break
        }
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard enabled, trimmed.contains(marker) else { return [trimmed] }

        let parts = trimmed
            .components(separatedBy: marker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.isEmpty ? [trimmed] : Array(parts.prefix(5))
    }
}

private enum MessageURLDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstWebURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector?.firstMatch(in: text, options: [], range: range),
              let url = match.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

private enum LinkPreviewMemoryCache {
    static let metadata = NSCache<NSURL, LPLinkMetadata>()
    static let artwork = NSCache<NSURL, UIImage>()
}

private struct MessageLinkPreviewCard: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?
    @State private var artwork: UIImage?
    @State private var loading = true

    private var title: String {
        let candidate = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? (url.host ?? url.absoluteString) : candidate
    }

    private var host: String {
        (metadata?.originalURL ?? metadata?.url ?? url).host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }

    var body: some View {
        Link(destination: metadata?.originalURL ?? metadata?.url ?? url) {
            VStack(alignment: .leading, spacing: 0) {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 118)
                        .clipped()
                } else if loading {
                    ZStack {
                        LinearGradient(colors: [Color.pink.opacity(0.20), Color.purple.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        ProgressView().tint(.pink)
                    }
                    .frame(height: 72)
                }

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.pink.opacity(0.82))
                        .frame(width: 24, height: 24)
                        .background(Color.pink.opacity(0.11), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.pink.opacity(0.82))
                            .lineLimit(1)
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 7)
                }
                .padding(10)
            }
            .frame(maxWidth: 286, alignment: .leading)
            .background(Color.pink.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: url) { await fetchMetadata() }
    }

    @MainActor
    private func fetchMetadata() async {
        let key = url as NSURL
        if let cached = LinkPreviewMemoryCache.metadata.object(forKey: key) {
            metadata = cached
            artwork = LinkPreviewMemoryCache.artwork.object(forKey: key)
            loading = false
            return
        }

        do {
            let provider = LPMetadataProvider()
            provider.timeout = 8
            let fetched = try await provider.startFetchingMetadata(for: url)
            guard !Task.isCancelled else { return }
            metadata = fetched
            LinkPreviewMemoryCache.metadata.setObject(fetched, forKey: key)
            if let image = await loadImage(from: fetched.imageProvider ?? fetched.iconProvider) {
                artwork = image
                LinkPreviewMemoryCache.artwork.setObject(image, forKey: key)
            }
        } catch {
            // The fallback card still opens the original URL when a site blocks metadata fetching.
        }
        loading = false
    }

    private func loadImage(from provider: NSItemProvider?) async -> UIImage? {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}

struct Bubble: View {
    let msg: Msg
    let reactions: [String]
    var onImage: (URL) -> Void
    var onReply: () -> Void
    var onReact: (String) -> Void
    var onMoreReactions: () -> Void
    var onRetract: () -> Void
    var onDelete: () -> Void
    /// 「选择文字」: enters system text selection for the given selection key.
    var onSelectText: (String) -> Void
    var onJumpToReply: (Int) -> Void
    var onAvatarDoubleTap: () -> Void
    var mine: Bool { msg.from == "me" }
    var partText: String? = nil
    var showsReplyPreview = true
    private var reply: ReplyInfo? { showsReplyPreview ? ReplyInfo.parse(MediaGroupInfo.batchCaption(msg.text)) : nil }
    private var bubbleParts: [String] {
        if let partText { return [partText] }
        return MessageBubbleSplitter.parts(msg.displayedText, enabled: !mine)
    }
    let visiblePartCount: Int
    var activity: ChatActivity? = nil
    var canRetract = false
    @State var openingFile = false
    @Environment(\.chatPeerConversation) private var peer

    private var selectionKey: String { "remote:\(msg.id)" }

    /// Native long-press menu shared by text and media content of this message.
    private var messageMenu: MessageContextMenu {
        MessageContextMenu(
            copyText: msg.displayedText,
            selectionKey: selectionKey,
            onReply: onReply,
            onReact: onReact,
            onMoreReactions: onMoreReactions,
            onSelectText: onSelectText,
            onFavorite: { try await FavoriteStore.shared.add(message: msg, peerName: peer?.displayName) },
            onRetract: canRetract ? onRetract : nil,
            onDelete: onDelete
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 48)
            } else {
                Avatar(isMe: false)
                    .onTapGesture(count: 2, perform: onAvatarDoubleTap)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine, let activity {
                    ChatActivityControls(activity: activity, conversationID: peer?.id ?? "claude")
                }
                content
                    .modifier(messageMenu)

                if !reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(reactions, id: \.self) { emoji in
                            Text(emoji)
                                .font(.system(size: 15))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                        }
                    }
                    .modifier(BubbleGlass(shape: Capsule()))
                }

                Text(msg.timestampText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .padding(.horizontal, 4)
            }

            if mine {
                Avatar(isMe: true)
            } else {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let location = LocationInfo.parse(msg.text) {
            LocationMessageCard(info: location)
        } else if let f = msg.file, API.isImage(f) {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                ChatImageView(name: f, onOpen: { onImage(API.fileURL(f)) })
                if reply != nil || !msg.displayedText.isEmpty {
                    textBubble(text: msg.displayedText, showsReply: true)
                }
            }
        } else if let f = msg.file, API.isAudio(f) {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if reply != nil { textBubble(text: msg.displayedText, showsReply: true) }
                VoiceMessagePlayer(url: API.fileURL(f))
            }
        } else if let f = msg.file, API.isVideo(f) {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if reply != nil { textBubble(text: msg.displayedText, showsReply: true) }
                VideoThumbnailBubble(name: f) { openingFile = true }
                    .fullScreenCover(isPresented: $openingFile) {
                        VideoMessageViewer(name: f, onFavorite: { try await FavoriteStore.shared.add(message: msg, peerName: peer?.displayName) })
                    }
            }
        } else if let f = msg.file {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                Button { openingFile = true } label: {
                    Label(f.replacingOccurrences(of: "^\\d+-", with: "", options: .regularExpression),
                          systemImage: "doc.fill")
                        .font(.system(size: 16))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $openingFile) {
                    FileMessageViewer(name: f, onFavorite: { try await FavoriteStore.shared.add(message: msg, peerName: peer?.displayName) })
                }
                if reply != nil || !msg.displayedText.isEmpty {
                    textBubble(text: msg.displayedText, showsReply: true)
                }
            }
        } else if bubbleParts.count <= 1 {
            textBubble(text: bubbleParts.first ?? msg.displayedText, showsReply: true)
        } else {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                ForEach(Array(bubbleParts.prefix(visiblePartCount).enumerated()), id: \.offset) { index, part in
                    textBubble(text: part, showsReply: index == 0)
                }
            }
        }
    }

    private func textBubble(text: String, showsReply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsReply, let reply {
                Button {
                    onJumpToReply(reply.messageID)
                } label: {
                    HStack(spacing: 7) {
                        Capsule()
                            .fill(Color.pink.opacity(0.58))
                            .frame(width: 3, height: 31)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reply.sender)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.pink.opacity(0.78))
                            Text(reply.preview)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !text.isEmpty {
                SelectableMarkdownText(text: text, selectionKey: selectionKey)
            }

            if let url = MessageURLDetector.firstWebURL(in: text) {
                MessageLinkPreviewCard(url: url)
            }
        }
        .modifier(ChatTextBubblePadding())
        .modifier(ChatTextBubbleBackground(mine: mine))
    }
}

private struct LocationMessageCard: View {
    let info: LocationInfo

    var body: some View {
        Group {
            if let url = info.mapsURL {
                Link(destination: url) { card }
            } else {
                card
            }
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.pink.opacity(0.17))
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.pink.opacity(0.82))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text("当前位置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(String(format: "%.5f, %.5f", info.latitude, info.longitude))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }
}

/// Text field that always asks for the system emoji keyboard.
private final class EmojiInputField: UITextField {
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}

/// 「贴表情」: shows the system emoji keyboard through a hidden field; the first emoji
/// typed becomes the reaction.
@MainActor
private final class EmojiReactionPicker: NSObject, UITextFieldDelegate {
    static let shared = EmojiReactionPicker()
    private let field = EmojiInputField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
    private var onPick: ((String) -> Void)?

    private override init() {
        super.init()
        field.delegate = self
        field.alpha = 0.01
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    func present(_ onPick: @escaping (String) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        self.onPick = onPick
        field.text = ""
        if field.superview !== window { window.addSubview(field) }
        field.becomeFirstResponder()
    }

    @objc private func changed() {
        guard let first = field.text?.first else { return }
        let emoji = String(first)
        field.text = ""
        let pick = onPick
        onPick = nil
        field.resignFirstResponder()
        pick?(emoji)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onPick = nil
        textField.text = ""
        textField.removeFromSuperview()
    }
}

/// System long-press context menu for a message bubble (lifted preview + action list).
private struct MessageContextMenu: ViewModifier {
    let copyText: String
    let selectionKey: String
    var cornerRadius: CGFloat = 22
    let onReply: () -> Void
    let onReact: (String) -> Void
    var onMoreReactions: (() -> Void)? = nil
    var onSelectText: ((String) -> Void)? = nil
    var onFavorite: (() async throws -> Void)? = nil
    var onRetract: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var translating = false
    @State private var translationText = ""
    @State private var favoriteError: String?
    @State private var confirmingDelete = false

    private var plainText: String { uiMarkdown(copyText, size: 16).string }

    /// Runs after the menu's dismissal animation so presented sheets and selection
    /// do not collide with the closing preview.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func body(content: Content) -> some View {
        content
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contextMenu { menuItems }
            .modifier(MessageTranslationHost(isPresented: $translating, text: translationText))
            .alert("收藏未成功", isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } })) {
                Button("好") { favoriteError = nil }
            } message: { Text(favoriteError ?? "") }
            .alert("删除这条消息？", isPresented: $confirmingDelete) {
                Button("删除", role: .destructive) { onDelete?() }
                Button("取消", role: .cancel) {}
            } message: { Text("只从本机删除，不影响对方。") }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onReply) {
            Label("回复", systemImage: "arrowshape.turn.up.left")
        }
        if !copyText.isEmpty {
            Button {
                UIPasteboard.general.string = plainText
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            if let onSelectText {
                Button {
                    let key = selectionKey
                    afterMenuCloses { onSelectText(key) }
                } label: {
                    Label("选择文字", systemImage: "selection.pin.in.out")
                }
            }
        }
        if let onFavorite {
            Button {
                Task {
                    do {
                        try await onFavorite()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } catch {
                        favoriteError = error.localizedDescription
                    }
                }
            } label: {
                Label("收藏", systemImage: "star")
            }
        }
        if !copyText.isEmpty, MessageTranslationHost.isAvailable {
            Button {
                translationText = plainText
                afterMenuCloses { translating = true }
            } label: {
                Label("翻译", systemImage: "translate")
            }
        }
        Button {
            let react = onReact
            afterMenuCloses { EmojiReactionPicker.shared.present(react) }
        } label: {
            Label("贴表情", systemImage: "face.smiling")
        }
        if let onRetract {
            Button(action: onRetract) {
                Label("撤回", systemImage: "arrow.uturn.backward")
            }
        }
        if onDelete != nil {
            Button(role: .destructive) {
                afterMenuCloses { confirmingDelete = true }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// Hosts the system translation sheet where the OS supports it.
private struct MessageTranslationHost: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    static var isAvailable: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
    }
}

private func swiftMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
}

private func uiMarkdown(_ source: String, size: CGFloat, font choice: ChatFontChoice = ChatFontChoice.current) -> NSAttributedString {
    let regular = choice.uiFont(size: size)
    let result = NSMutableAttributedString(
        string: source,
        attributes: [.font: regular, .foregroundColor: UIColor.label]
    )
    let patterns: [(String, UIFont)] = [
        (#"\*\*(.+?)\*\*"#, choice.uiFont(size: size, bold: true)),
        (#"__(.+?)__"#, choice.uiFont(size: size, bold: true)),
        (#"`([^`]+)`"#, UIFont.monospacedSystemFont(ofSize: size - 0.5, weight: .regular))
    ]
    for (pattern, font) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let whole = NSRange(location: 0, length: result.length)
        for match in regex.matches(in: result.string, range: whole).reversed() {
            guard match.numberOfRanges > 1,
                  let inner = Range(match.range(at: 1), in: result.string) else { continue }
            let replacement = String(result.string[inner])
            result.replaceCharacters(in: match.range, with: replacement)
            result.addAttribute(.font, value: font, range: NSRange(location: match.range.location, length: (replacement as NSString).length))
        }
    }
    return result
}

private extension Notification.Name {
    static let clearChatTextSelection = Notification.Name("clearChatTextSelection")
    static let chatTextSelectionChanged = Notification.Name("chatTextSelectionChanged")
}

@MainActor
private enum ChatTextSelection {
    static weak var active: ChatSelectionTextView?
    /// System selection mode: the text view is selectable and shows the system edit menu.
    static var systemSelecting = false
    /// Live text views by selection key, so a menu action can target its own message.
    private static let views = NSMapTable<NSString, ChatSelectionTextView>.strongToWeakObjects()

    static func register(_ view: ChatSelectionTextView, key: String) {
        guard !key.isEmpty else { return }
        views.setObject(view, forKey: key as NSString)
    }

    static func isSelectionInteraction(at point: CGPoint) -> Bool {
        guard let active, active.selectedRange.length > 0 else { return false }
        return active.convert(active.bounds, to: nil).insetBy(dx: -18, dy: -18).contains(point)
    }

    /// Makes the message's text selectable, selects all of it and shows the system handles.
    @discardableResult
    static func beginSystemSelection(key: String) -> Bool {
        guard let view = views.object(forKey: key as NSString), view.window != nil else { return false }
        if let old = active, old !== view { endSystemSelection() }
        systemSelecting = true
        active = view
        // Keep the enclosing list exactly where it is while the text view takes focus.
        var container = view.superview
        while let c = container, !(c is UIScrollView) { container = c.superview }
        let list = container as? UIScrollView
        let offset = list?.contentOffset
        view.isSelectable = true
        view.becomeFirstResponder()
        view.selectedRange = NSRange(location: 0, length: view.attributedText.length)
        if let list, let offset {
            list.setContentOffset(offset, animated: false)
            Task { @MainActor in
                for delay in [0, 120, 300] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard ChatTextSelection.systemSelecting, ChatTextSelection.active === view,
                          !list.isTracking, !list.isDecelerating else { return }
                    if list.contentOffset != offset { list.setContentOffset(offset, animated: false) }
                }
            }
        }
        return true
    }

    static func endSystemSelection() {
        systemSelecting = false
        if let view = active {
            view.selectedRange = NSRange(location: 0, length: 0)
            view.resignFirstResponder()
            view.isSelectable = false
        }
        active = nil
    }
}

private final class ChatSelectionTextView: UITextView {
    var selectionKey = ""

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Only system selection mode shows the system edit menu.
        guard ChatTextSelection.systemSelecting else { return false }
        return super.canPerformAction(action, withSender: sender)
    }
}

// Message text. Not selectable by default so a long press opens the message's context
// menu; 「选择文字」 switches it into system selection.
private struct SelectableMarkdownText: UIViewRepresentable {
    let text: String
    var selectionKey: String = ""

    /// Observed directly so a font change re-renders every visible bubble at once,
    /// including rows a parent equality check would otherwise skip.
    @AppStorage(ChatFontChoice.storageKey) private var fontChoiceRaw = ChatFontChoice.system.rawValue
    private var fontChoice: ChatFontChoice { ChatFontChoice(rawValue: fontChoiceRaw) ?? .system }

    private var renderKey: String { fontChoice.rawValue + "|" + text }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableMarkdownText
        var renderedSource: String
        weak var textView: UITextView?

        init(_ parent: SelectableMarkdownText) {
            self.parent = parent
            self.renderedSource = parent.renderKey
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clearSelection),
                name: .clearChatTextSelection,
                object: nil
            )
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func clearSelection() {
            guard let textView else { return }
            if ChatTextSelection.active === textView {
                ChatTextSelection.endSystemSelection()
            } else {
                textView.selectedRange = NSRange(location: 0, length: 0)
                textView.resignFirstResponder()
                textView.isSelectable = false
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            NotificationCenter.default.post(name: .chatTextSelectionChanged, object: nil)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            // System selection mode uses the default system menu (copy, look up, translate...).
            ChatTextSelection.systemSelecting ? nil : UIMenu(children: [])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = ChatSelectionTextView()
        v.selectionKey = selectionKey
        v.delegate = context.coordinator
        v.isEditable = false
        v.isSelectable = false
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.adjustsFontForContentSizeCategory = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.attributedText = uiMarkdown(text, size: 16, font: fontChoice)
        context.coordinator.textView = v
        ChatTextSelection.register(v, key: selectionKey)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        if let view = v as? ChatSelectionTextView {
            view.selectionKey = selectionKey
            ChatTextSelection.register(view, key: selectionKey)
        }
        if context.coordinator.renderedSource != renderKey {
            context.coordinator.renderedSource = renderKey
            v.attributedText = uiMarkdown(text, size: 16, font: fontChoice)
            v.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width * 0.68
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(fitted.width)), height: ceil(fitted.height))
    }
}

// ===== 审批卡（选择题）=====
struct ApproveCard: View {
    @ObservedObject var store: ChatStore
    let msg: Msg
    let payload: ApprovePayload
    let onFinish: () -> Void

    private var state: ChatStore.ApproveState {
        store.approveStates[msg.id] ?? ChatStore.ApproveState(n: payload.questions.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                card
                Spacer(minLength: 40)
            }
            Text(msg.timestampText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.78))
                .padding(.leading, 4)
        }
    }

    private var card: some View {
        let q = payload.questions[state.idx]
        return VStack(alignment: .leading, spacing: 10) {
            if let title = payload.title, state.idx == 0 {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.pink)
            }
            Text(q.q).font(.system(size: 15, weight: .semibold))

            ForEach(q.options, id: \.self) { opt in
                optionRow(opt, multi: q.multi)
            }
            customRow

            HStack {
                Text("\(state.idx + 1) / \(payload.questions.count)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button("跳过") { finish(skip: true) }
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Button(action: next) {
                    Text(state.idx == payload.questions.count - 1 ? "完成" : "继续")
                        .font(.system(size: 14, weight: .bold))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(isAnswered(state.idx) ? Color.pink.opacity(0.75) : Color.secondary.opacity(0.18),
                                    in: Capsule())
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .frame(maxWidth: 320, alignment: .leading)
        .onAppear { store.ensureApproveState(msg.id, n: payload.questions.count) }
    }

    private func optionRow(_ opt: String, multi: Bool) -> some View {
        let qi = state.idx
        let selected = multi ? state.sets[qi].contains(opt) : state.picks[qi] == opt
        return Button {
            if multi {
                var s = state.sets[qi]
                if s.contains(opt) { s.remove(opt) } else { s.insert(opt) }
                store.approveStates[msg.id]?.sets[qi] = s
            } else {
                store.approveStates[msg.id]?.picks[qi] = opt
                store.approveStates[msg.id]?.customs[qi] = ""
            }
        } label: {
            HStack(spacing: 10) {
                mark(multi: multi, selected: selected)
                Text(opt).font(.system(size: 15)).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.pink.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func mark(multi: Bool, selected: Bool) -> some View {
        ZStack {
            if multi {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(selected ? Color.pink : Color.secondary.opacity(0.6), lineWidth: 1.5)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.pink)
                }
            } else {
                Circle().strokeBorder(selected ? Color.pink : Color.secondary.opacity(0.6), lineWidth: 1.5)
                if selected {
                    Circle().fill(Color.pink).frame(width: 9, height: 9)
                }
            }
        }
        .frame(width: 19, height: 19)
    }

    private var customRow: some View {
        let qi = state.idx
        return HStack(spacing: 10) {
            Image(systemName: "pencil.line").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 19)
            TextField("别的答案…", text: Binding(
                get: { store.approveStates[msg.id]?.customs[qi] ?? "" },
                set: { store.approveStates[msg.id]?.customs[qi] = $0 }
            ))
            .font(.system(size: 15))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func isAnswered(_ qi: Int) -> Bool {
        let q = payload.questions[qi]
        if q.multi { return !state.sets[qi].isEmpty || !state.customs[qi].isEmpty }
        return state.picks[qi] != nil || !state.customs[qi].isEmpty
    }

    private func next() {
        if state.idx < payload.questions.count - 1 {
            store.approveStates[msg.id]?.idx += 1
        } else {
            finish(skip: false)
        }
    }

    private func finish(skip: Bool) {
        var lines: [String] = []
        for (i, q) in payload.questions.enumerated() {
            var v = q.multi
                ? state.sets[i].sorted().joined(separator: "、")
                : (state.customs[i].isEmpty ? (state.picks[i] ?? "") : state.customs[i])
            if q.multi, !state.customs[i].isEmpty {
                v = v.isEmpty ? state.customs[i] : v + "、" + state.customs[i]
            }
            if v.isEmpty { v = "（你来定）" }
            let qq = q.q.replacingOccurrences(of: "？", with: "").replacingOccurrences(of: "?", with: "")
            lines.append("\(qq)：\(v)")
        }
        let text = (skip ? "【已跳过】" : "【已确认】")
            + lines.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "；")
        store.answered.insert(msg.id)
        onFinish()
        Task { await store.send(text) }
    }
}

private struct ApprovalSheetItem: Identifiable {
    let msg: Msg
    let payload: ApprovePayload
    var id: Int { msg.id }
}

private struct ApprovalPromptRow: View {
    let msg: Msg
    let payload: ApprovePayload
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.clipboard.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.pink.opacity(0.82))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payload.title ?? "选择题")
                                .font(.system(size: 15, weight: .semibold))
                            Text("点开填写 · \(payload.questions.count) 题")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(BubbleGlass(shape: Capsule()))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 40)
            }
            Text(msg.timestampText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.78))
                .padding(.leading, 4)
        }
    }
}

private struct ApprovalSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    let item: ApprovalSheetItem

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    ApproveCard(store: store, msg: item.msg, payload: item.payload) {
                        dismiss()
                    }
                    .padding(16)
                }
            }
            .navigationTitle(item.payload.title ?? "选择题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// ===== 大图查看（捏合缩放 / 拖动 / 双击放大缩小）=====
struct ViewerItem: Identifiable { let id = UUID(); let url: URL }

struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var steady: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var failed = false
    @State private var saveMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .ignoresSafeArea()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoomGestures)
                    .onTapGesture(count: 2) { toggle() }
            } else if failed {
                Text("图片无法加载")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).scaleEffect(1.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .accessibilityLabel("关闭")

                Spacer()

                Button { saveImage() } label: {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.white.opacity(image == nil ? 0.42 : 0.88))
                }
                .disabled(image == nil)
                .accessibilityLabel("保存图片")
            }
            .padding(18)
        }
        .task {
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            if url.isFileURL, let local = UIImage(contentsOfFile: url.path) {
                image = local
            } else if let data = await ChatImageCache.data(for: name), let local = UIImage(data: data) {
                image = local
            } else if let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let decoded = UIImage(data: data) {
                ChatImageCache.store(data, name: name)
                image = decoded
            } else {
                failed = true
            }
        }
        .alert("图片", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("好") { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    private func saveImage() {
        guard let image else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run { saveMessage = "请在系统设置中允许熊窝添加照片。" }
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await MainActor.run { saveMessage = "已保存到照片。" }
            } catch {
                await MainActor.run { saveMessage = "保存失败：\(error.localizedDescription)" }
            }
        }
    }

    private func toggle() {
        withAnimation(.spring(duration: 0.28)) {
            if scale > 1.05 {
                scale = 1; steady = 1; offset = .zero; steadyOffset = .zero
            } else {
                scale = 2.5; steady = 2.5
            }
        }
    }

    private var zoomGestures: some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { g in
                    guard scale > 1.02 else { return }
                    offset = CGSize(width: steadyOffset.width + g.translation.width,
                                    height: steadyOffset.height + g.translation.height)
                }
                .onEnded { _ in steadyOffset = offset },
            MagnifyGesture()
                .onChanged { v in scale = min(max(steady * v.magnification, 1), 6) }
                .onEnded { _ in
                    steady = scale
                    if scale <= 1.02 {
                        withAnimation(.spring(duration: 0.25)) {
                            scale = 1; steady = 1; offset = .zero; steadyOffset = .zero
                        }
                    }
                }
        )
    }
}

// ===== 通讯录 =====
enum ContactKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case puppy
    case ayan

    var id: String { rawValue }

    var defaultName: String {
        switch self {
        case .claude: return "助手"
        case .puppy: return "助手 2"
        case .ayan: return "助手"
        }
    }

    var signature: String {
        switch self {
        case .claude: return "随时在线，等你来聊天"
        case .puppy: return "在线"
        case .ayan: return "安静待机中 · 等待接入"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .puppy: return "pawprint.fill"
        case .ayan: return "moon.stars.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .claude: return [.purple.opacity(0.72), .pink.opacity(0.62)]
        case .puppy: return [.pink.opacity(0.78), .orange.opacity(0.54)]
        case .ayan: return [.indigo.opacity(0.78), .purple.opacity(0.58)]
        }
    }
}

struct ContactsView: View {
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @State private var conversations: [AIConversation] = []

    private var aiContacts: [AIConversation] {
        conversations.filter { $0.id != "claude" && $0.kind != "group" }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        NavigationLink {
                            GroupListView()
                        } label: {
                            HStack(spacing: 13) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [.pink.opacity(0.74), .purple.opacity(0.58)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Image(systemName: "person.3.fill")
                                        .font(.system(size: 21, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 50, height: 50)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("群聊")
                                        .font(.system(size: 17, weight: .semibold))
                                    Text("查看所有群聊")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(13)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("联系人")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)

                            ForEach(ContactKind.allCases) { kind in
                                NavigationLink {
                                    ContactDetailView(kind: kind)
                                } label: {
                                    ContactRow(
                                        kind: kind,
                                        name: kind == .claude ? assistantRemark : kind.defaultName
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            ForEach(aiContacts) { conversation in
                                NavigationLink {
                                    AIContactEditor(conversation: conversation, isNew: false) { updated in
                                        update(updated)
                                    }
                                } label: {
                                    HStack(spacing: 13) {
                                        AIConversationAvatar(conversation: conversation, size: 50)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.displayName)
                                                .font(.system(size: 17, weight: .semibold))
                                                .lineLimit(1)
                                            Text([conversation.provider, conversation.model]
                                                .compactMap { $0 }
                                                .filter { !$0.isEmpty }
                                                .joined(separator: " · "))
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(13)
                                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 110)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear(perform: reload)
        .onChange(of: conversationsJSON) { _, _ in reload() }
    }

    private func reload() {
        guard let data = conversationsJSON.data(using: .utf8),
              let saved = try? JSONDecoder().decode([AIConversation].self, from: data) else { return }
        conversations = saved
    }

    private func update(_ conversation: AIConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        guard let data = try? JSONEncoder().encode(conversations),
              let value = String(data: data, encoding: .utf8) else { return }
        conversationsJSON = value
    }
}

struct ContactRow: View {
    let kind: ContactKind
    let name: String

    var body: some View {
        HStack(spacing: 13) {
            ContactAvatar(kind: kind, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(kind.signature)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
    }
}

struct ContactAvatar: View {
    let kind: ContactKind
    let size: CGFloat
    @ObservedObject private var avatars = Avatars.shared

    var body: some View {
        Group {
            if kind == .claude, let image = avatars.assistant ?? avatars.dog {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: kind.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: kind.symbol)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.09), radius: 4, y: 2)
    }
}

struct ContactDetailView: View {
    let kind: ContactKind
    @AppStorage("assistantRemark") private var assistantRemark = "助手"

    private var name: String {
        kind == .claude ? assistantRemark : kind.defaultName
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(spacing: 18) {
                    ContactAvatar(kind: kind, size: 94)

                    VStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 25, weight: .bold))
                        Text(kind.signature)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 0) {
                        profileLine("昵称", value: kind.defaultName)
                        Divider().opacity(0.25)
                        profileLine("状态", value: kind == .ayan ? "等待接入" : "在线")
                    }
                    .padding(.horizontal, 16)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                }
                .padding(.horizontal, 18)
                .padding(.top, 34)
            }
        }
        .navigationTitle("资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func profileLine(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 15))
        .padding(.vertical, 15)
    }
}

struct GroupListView: View {
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @AppStorage("groupDirectoryVersion") private var groupDirectoryVersion = 0
    private var savedGroups: [AIConversation] {
        guard let data = conversationsJSON.data(using: .utf8),
              let conversations = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        return conversations.filter {
            groupDirectoryVersion >= 0 && $0.kind == "group" &&
            UserDefaults.standard.bool(forKey: "group.\($0.id).saved")
        }
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            if savedGroups.isEmpty {
                ContentUnavailableView(
                    "暂无群聊",
                    systemImage: "person.3",
                    description: Text("在群聊详情里打开「保存到通讯录」后会显示在这里")
                )
            } else {
                List(savedGroups) { group in
                    HStack(spacing: 12) {
                        AIConversationAvatar(conversation: group, size: 42)
                        Text(group.displayName).font(.system(size: 16))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("群聊")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// ===== 首页：会话列表 =====
struct AIConversation: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var signature: String
    var symbol: String
    var pinned: Bool
    var kind: String? = nil
    var provider: String? = nil
    var model: String? = nil
    var baseURL: String? = nil
    var authMode: String? = nil
    var interfaceFormat: String? = nil
    var credentialID: String? = nil
    var remark: String? = nil
    var avatarFile: String? = nil
    var groupMemberIDs: [String]? = nil

    var displayName: String {
        let localRemark = remark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localRemark.isEmpty ? name : localRemark
    }
}


// Local conversations keep an inbox snapshot so previews and unread badges update while
// another chat is open. History remains in configuredAI.messages.<id>.
private struct LocalAIInboxEntry: Codable {
    var preview: String = ""
    var time: Date? = nil
    var unreadCount: Int = 0
}

private enum LocalAIInbox {
    static let changedKey = "localAIInboxVersion"
    static let activeKey = "localAIActiveConversation"

    private static func key(_ id: String) -> String { "localAIInbox.\(id)" }

    /// Main-thread memory copy of every snapshot; list rows, sorting and the tab badge read
    /// from here so a render never touches the decoder or the stored chat history.
    private static var cache: [String: LocalAIInboxEntry] = [:]
    /// Byte size of the history blob the snapshot was last checked against (memory only).
    private static var checkedSize: [String: Int] = [:]
    private static var reconciling: Set<String> = []
    private static let workQueue = DispatchQueue(label: "app.bearden.local-ai-inbox", qos: .utility)

    static func entry(_ id: String) -> LocalAIInboxEntry {
        if let cached = cache[id] { return cached }
        var value = LocalAIInboxEntry()
        if let data = UserDefaults.standard.data(forKey: key(id)),
           let stored = try? JSONDecoder().decode(LocalAIInboxEntry.self, from: data) {
            value = stored
        }
        cache[id] = value
        if value.time == nil { reconcile(id) }
        return value
    }

    static func received(_ message: LocalAIMessage, in id: String) {
        var value = entry(id)
        value.preview = previewText(message)
        value.time = max(value.time ?? message.createdAt, message.createdAt)
        if message.role == "assistant",
           UserDefaults.standard.string(forKey: activeKey) != id {
            value.unreadCount += 1
        }
        save(value, id: id)
    }

    static func previewText(_ message: LocalAIMessage) -> String {
        if message.stickerPath != nil { return "[表情包]" }
        if message.withdrawn == true { return "[已撤回]" }
        let text = message.text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if message.attachments?.contains(where: { $0.mime.hasPrefix("image/") }) == true { return "[图片]" }
            return message.attachments?.isEmpty == false ? "[附件]" : " "
        }
        return text
    }

    /// Brings the snapshot up to the newest stored message. Some write paths (group member
    /// replies landing after the screen closed, shared chat view persistence) can leave the
    /// snapshot behind the history. The history blob is only decoded off the main thread and
    /// only when its size changed since the last check, so calling this often is cheap.
    static func reconcile(_ id: String) {
        guard !reconciling.contains(id) else { return }
        reconciling.insert(id)
        let known = checkedSize[id]
        workQueue.async {
            let data = UserDefaults.standard.data(forKey: "configuredAI.messages.\(id)")
            let size = data?.count ?? 0
            var last: LocalAIMessage?
            if size != known, let data {
                last = (try? JSONDecoder().decode([LocalAIMessage].self, from: data))?.last
            }
            DispatchQueue.main.async {
                reconciling.remove(id)
                checkedSize[id] = size
                guard let last else { return }
                var value = entry(id)
                if let time = value.time, time >= last.createdAt { return }
                value.preview = previewText(last)
                value.time = last.createdAt
                save(value, id: id)
            }
        }
    }

    static func markRead(_ id: String) {
        var value = entry(id)
        value.unreadCount = 0
        save(value, id: id)
    }

    private static func save(_ value: LocalAIInboxEntry, id: String) {
        if let old = cache[id], old.preview == value.preview, old.time == value.time,
           old.unreadCount == value.unreadCount { return }
        cache[id] = value
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
        UserDefaults.standard.set(
            UserDefaults.standard.integer(forKey: changedKey) + 1,
            forKey: changedKey
        )
    }
}

private enum AIKeychain {
    // Keychain service follows the bundle identifier so differently-identified builds keep separate stores.
    private static let service = (Bundle.main.bundleIdentifier ?? "app.bearden.mailbox") + ".ai"

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(account: String?) -> String {
        guard let account, !account.isEmpty else { return "" }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func delete(account: String?) {
        guard let account, !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum AIAvatarStore {
    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func save(_ image: UIImage, id: String) throws -> String {
        let name = "\(id).jpg"
        let url = directory.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw NSError(domain: "AIAvatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "头像无法保存"])
        }
        try data.write(to: url, options: .atomic)
        cache.setObject(image, forKey: name as NSString)
        return name
    }

    static func image(named name: String?) -> UIImage? {
        guard let name, !name.isEmpty else { return nil }
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func delete(named name: String?) {
        guard let name else { return }
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

private struct AIConversationAvatar: View {
    let conversation: AIConversation
    let size: CGFloat

    var body: some View {
        Group {
            if conversation.id == "claude" {
                ContactAvatar(kind: .claude, size: size)
            } else if let image = AIAvatarStore.image(named: conversation.avatarFile) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 1.00, green: 0.76, blue: 0.84), Color(red: 0.78, green: 0.72, blue: 0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: conversation.symbol)
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.46), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

struct LocalAIMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let role: String
    var text: String
    let createdAt: Date
    let stickerPath: String?
    var attachments: [LocalChatAttachment]? = nil
    var replyID: UUID? = nil
    var replyPreview: String? = nil
    var replySender: String? = nil
    var reactions: [String]? = nil
    var aiReaction: String? = nil
    var withdrawn: Bool? = nil
    var authorID: String? = nil
    var activity: ChatActivity? = nil
    /// Raw timeline text (reply, album and pat markers) for messages written by the shared chat view.
    var wireText: String? = nil

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        createdAt: Date = .now,
        stickerPath: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.stickerPath = stickerPath
    }

    /// Sticker paths were stored as absolute container paths, which change whenever the app is
    /// reinstalled; fall back to the same file name inside the current sticker folder.
    var stickerURL: URL? {
        guard let stickerPath else { return nil }
        let stored = URL(fileURLWithPath: stickerPath)
        if FileManager.default.fileExists(atPath: stored.path) { return stored }
        return StickerLibrary.folderURL.appendingPathComponent(stored.lastPathComponent)
    }
}

private struct LocalReactionTarget: Identifiable { let id: UUID }

private struct LocalAIMessageBubble: View, Equatable {
    let message: LocalAIMessage
    let conversation: AIConversation
    var onReply: () -> Void = {}
    var onReact: (String) -> Void = { _ in }
    var onMore: () -> Void = {}
    var onRetract: () -> Void = {}
    var onJump: (UUID) -> Void = { _ in }
    var onPat: () -> Void = {}
    var onImage: (URL) -> Void = { _ in }

    private var mine: Bool { message.role == "user" }
    private var senderConversation: AIConversation {
        guard let id = message.authorID,
              let data = UserDefaults.standard.string(forKey: "aiConversationsJSON")?.data(using: .utf8),
              let all = try? JSONDecoder().decode([AIConversation].self, from: data),
              let selected = all.first(where: { $0.id == id }) else { return conversation }
        return selected
    }

    static func == (lhs: LocalAIMessageBubble, rhs: LocalAIMessageBubble) -> Bool {
        lhs.message == rhs.message && lhs.conversation == rhs.conversation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 48)
            } else {
                AIConversationAvatar(conversation: senderConversation, size: 36)
                    .onTapGesture(count: 2, perform: onPat)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine && conversation.kind == "group" &&
                    UserDefaults.standard.object(forKey: "group.\(conversation.id).showNames") as? Bool != false {
                    // 36pt avatar: centre the ~14pt name line on the avatar's middle.
                    Text(senderConversation.displayName).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).padding(.leading, 5).padding(.top, 11)
                }
                if !mine, let activity = message.activity {
                    ChatActivityControls(activity: activity, conversationID: conversation.id)
                }
                Group {
                    if message.withdrawn == true {
                        Text("你撤回了一条消息").font(.caption).foregroundStyle(.secondary)
                    } else if let stickerURL = message.stickerURL {
                        StickerThumbnail(url: stickerURL)
                            .frame(width: 150, height: 150)
                            .onTapGesture { onImage(stickerURL) }
                            .modifier(messageMenu)
                    } else {
                        messageBubble
                            .modifier(messageMenu)
                    }
                }
                if message.withdrawn != true, let files = message.attachments, !files.isEmpty {
                    LocalChatAttachmentsView(files: files, onImage: onImage)
                        .modifier(messageMenu)
                }
                let reactions = (message.reactions ?? []) + (message.aiReaction.map { [$0] } ?? [])
                if !reactions.isEmpty {
                    Text(reactions.joined(separator: " ")).font(.system(size: 15))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .modifier(BubbleGlass(shape: Capsule()))
                }

                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.78))
                    .padding(.horizontal, 4)
            }

            if mine {
                MyAvatar(size: 36)
            } else {
                Spacer(minLength: 48)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var messageMenu: MessageContextMenu {
        MessageContextMenu(
            copyText: message.text,
            selectionKey: "local:\(message.id)",
            onReply: onReply,
            onReact: onReact,
            onMoreReactions: onMore,
            onSelectText: { ChatTextSelection.beginSystemSelection(key: $0) },
            onFavorite: {
                let urls = (message.attachments ?? []).map(\.url) + (message.stickerURL.map { [$0] } ?? [])
                try await FavoriteStore.shared.add(sourceKey: "local:\(conversation.id):\(message.id)", remark: mine ? FavoriteStore.remark(mine: true) : senderConversation.displayName, text: message.text, urls: urls)
            },
            onRetract: mine ? onRetract : nil
        )
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let replyID = message.replyID {
                Button { onJump(replyID) } label: {
                    HStack(spacing: 7) {
                        Capsule().fill(Color.pink.opacity(0.58)).frame(width: 3, height: 31)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.replySender ?? "引用").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.pink.opacity(0.78))
                            Text(message.replyPreview ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.buttonStyle(.plain)
            }
            SelectableMarkdownText(text: message.text, selectionKey: "local:\(message.id)")
            if let url = MessageURLDetector.firstWebURL(in: message.text) {
                MessageLinkPreviewCard(url: url)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }
}

private enum AIProviderError: LocalizedError {
    case invalidURL
    case missingCredential
    case server(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Base URL 不正确。"
        case .missingCredential: return "请先填写 API Key。"
        case .server(let message): return message
        case .malformedResponse: return "供应商返回了无法识别的数据。"
        }
    }
}

private enum AIProviderClient {
    static func fetchModels(baseURL: String, apiKey: String, format: String) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.missingCredential
        }
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let lowerFormat = format.lowercased()
        let endpoint: String
        if lowerFormat.contains("anthropic") {
            endpoint = normalized.hasSuffix("/v1") ? "\(normalized)/models" : "\(normalized)/v1/models"
        } else if lowerFormat.contains("gemini") {
            endpoint = normalized.hasSuffix("/v1beta") ? "\(normalized)/models" : "\(normalized)/v1beta/models"
        } else {
            endpoint = "\(normalized)/models"
        }
        guard var components = URLComponents(string: endpoint) else { throw AIProviderError.invalidURL }
        if lowerFormat.contains("gemini") {
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }
        guard let url = components.url else { throw AIProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        if lowerFormat.contains("anthropic") {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !lowerFormat.contains("gemini") {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let data = try await responseData(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.malformedResponse
        }
        let records = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let models = records.compactMap { record -> String? in
            if let id = record["id"] as? String { return id }
            if var name = record["name"] as? String {
                if name.hasPrefix("models/") { name.removeFirst("models/".count) }
                return name
            }
            return nil
        }
        return Array(Set(models)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func send(
        messages: [LocalAIMessage],
        model: String,
        baseURL: String,
        apiKey: String,
        format: String,
        nickname: String,
        authMode: String? = nil,
        credentialID: String? = nil,
        conversation: AIConversation? = nil,
        groupID: String? = nil,
        onActivity: ChatActivityHandler? = nil,
        onDelta: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        let lowerFormat = format.lowercased()
        if authMode == "订阅账号", lowerFormat.contains("responses") {
            return try await ChatGPTPlanClient.send(
                account: credentialID,
                messages: messages.map { (role: $0.role, text: $0.text) },
                model: model,
                nickname: nickname,
                conversation: conversation,
                richMessages: messages,
                onActivity: onActivity
            )
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.missingCredential
        }
        if let conversation {
            return try await AIModelTools.send(messages: messages, conversation: conversation, apiKey: apiKey, groupID: groupID, onActivity: onActivity, onDelta: onDelta)
        }
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var request: URLRequest
        let system = "你在熊窝里的昵称是\(nickname)。自然地和用户对话。\n\n\(MessageBubbleSplitter.promptInstruction)"

        if lowerFormat.contains("anthropic") {
            let endpoint = normalized.hasSuffix("/v1") ? "\(normalized)/messages" : "\(normalized)/v1/messages"
            guard let url = URL(string: endpoint) else { throw AIProviderError.invalidURL }
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 2048,
                "system": system,
                "messages": messages.map { ["role": $0.role, "content": $0.text] }
            ])
        } else if lowerFormat.contains("gemini") {
            let endpoint = normalized.hasSuffix("/v1beta")
                ? "\(normalized)/models/\(model):generateContent"
                : "\(normalized)/v1beta/models/\(model):generateContent"
            guard var components = URLComponents(string: endpoint) else { throw AIProviderError.invalidURL }
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = components.url else { throw AIProviderError.invalidURL }
            request = URLRequest(url: url)
            let contents = messages.map { message -> [String: Any] in
                ["role": message.role == "assistant" ? "model" : "user", "parts": [["text": message.text]]]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": contents
            ])
        } else {
            let endpoint = normalized.hasSuffix("/v1") ? "\(normalized)/chat/completions" : "\(normalized)/chat/completions"
            guard let url = URL(string: endpoint) else { throw AIProviderError.invalidURL }
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            var payloadMessages = [["role": "system", "content": system]]
            payloadMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.text] })
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": payloadMessages,
                "stream": false
            ])
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await responseData(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.malformedResponse
        }
        if lowerFormat.contains("anthropic"),
           let content = json["content"] as? [[String: Any]] {
            let value = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !value.isEmpty { return value }
        } else if lowerFormat.contains("gemini"),
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] {
            let value = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !value.isEmpty { return value }
        } else if let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let value = message["content"] as? String, !value.isEmpty {
            return value
        }
        throw AIProviderError.malformedResponse
    }

    private static func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = "连接失败（HTTP \(http.statusCode)）"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let detail = error["message"] as? String {
                message = detail
            } else if let detail = String(data: data, encoding: .utf8), !detail.isEmpty {
                message = String(detail.prefix(240))
            }
            throw AIProviderError.server(message)
        }
        return data
    }
}

private struct ClaudeStateSnapshot: Decodable {
    struct Usage: Decodable {
        struct Row: Decodable, Identifiable {
            let key: String
            let label: String
            let percent: Double
            let resetsAt: String
            var id: String { key }
        }
        let rows: [Row]
        let tier: String
        let subscription: String
    }

    struct Heartbeat: Decodable {
        let ageSec: Double
        let status: String
    }

    struct Model: Decodable {
        struct Context: Decodable {
            let tokens: Int
            let budget: Int
            let percent: Double
            let compactions: Int
            let dropped: Int
            let level: String
        }
        let id: String
        let name: String
        let effort: String
        let degraded: Bool
        let context: Context
    }

    let usage: Usage
    let heartbeat: Heartbeat
    let model: Model
}

private struct ProviderWalletSnapshot {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }
    let provider: String
    let status: String
    let rows: [Row]
}

private enum QuotaFetchError: LocalizedError {
    case unsupported(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let provider):
            return "\(provider) 没有提供可由普通 API Key 查询的钱包余额接口。"
        case .invalidResponse:
            return "额度接口返回了无法识别的数据。"
        case .server(let message):
            return message
        }
    }
}

private enum QuotaClient {
    static func fetchClaudeState() async throws -> ClaudeStateSnapshot {
        guard let base = ServerConfig.workbenchBase else {
            throw QuotaFetchError.server("未设置服务器地址")
        }
        let url = base.appendingPathComponent("api/state")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let data = try await checkedData(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(ClaudeStateSnapshot.self, from: data) else {
            throw QuotaFetchError.invalidResponse
        }
        return snapshot
    }

    static func fetchWallet(for conversation: AIConversation) async throws -> ProviderWalletSnapshot {
        let key = AIKeychain.load(account: conversation.credentialID)
        guard !key.isEmpty else { throw AIProviderError.missingCredential }
        let normalized = (conversation.baseURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let haystack = "\(conversation.provider ?? "") \(normalized)".lowercased()

        if haystack.contains("openrouter") {
            return try await fetchOpenRouter(normalized: normalized, key: key)
        }
        if haystack.contains("deepseek") {
            return try await fetchDeepSeek(normalized: normalized, key: key)
        }
        if haystack.contains("siliconflow") || haystack.contains("硅基流动") {
            return try await fetchSiliconFlow(normalized: normalized, key: key)
        }

        throw QuotaFetchError.unsupported(conversation.provider ?? "这个供应商")
    }

    private static func fetchOpenRouter(normalized: String, key: String) async throws -> ProviderWalletSnapshot {
        let root = normalized.isEmpty ? "https://openrouter.ai/api/v1" : normalized
        guard let url = URL(string: "\(root)/key") else { throw AIProviderError.invalidURL }
        let json = try await json(url: url, key: key)
        guard let data = json["data"] as? [String: Any] else { throw QuotaFetchError.invalidResponse }
        var rows: [ProviderWalletSnapshot.Row] = []
        if let remaining = number(data["limit_remaining"]) {
            rows.append(.init(label: "剩余额度", value: money(remaining)))
        }
        if let usage = number(data["usage"]) {
            rows.append(.init(label: "已使用", value: money(usage)))
        }
        if let limit = number(data["limit"]) {
            rows.append(.init(label: "额度上限", value: money(limit)))
        }
        guard !rows.isEmpty else { throw QuotaFetchError.invalidResponse }
        let isFree = (data["is_free_tier"] as? Bool) == true
        return .init(provider: "OpenRouter", status: isFree ? "免费额度" : "账户额度", rows: rows)
    }

    private static func fetchDeepSeek(normalized: String, key: String) async throws -> ProviderWalletSnapshot {
        var root = normalized.isEmpty ? "https://api.deepseek.com" : normalized
        if root.hasSuffix("/v1") { root.removeLast(3) }
        guard let url = URL(string: "\(root)/user/balance") else { throw AIProviderError.invalidURL }
        let json = try await json(url: url, key: key)
        guard let balances = json["balance_infos"] as? [[String: Any]], !balances.isEmpty else {
            throw QuotaFetchError.invalidResponse
        }
        let rows = balances.compactMap { item -> ProviderWalletSnapshot.Row? in
            guard let total = stringNumber(item["total_balance"]) else { return nil }
            let currency = (item["currency"] as? String) ?? ""
            return .init(label: currency.isEmpty ? "钱包余额" : "\(currency) 余额", value: "\(total) \(currency)")
        }
        guard !rows.isEmpty else { throw QuotaFetchError.invalidResponse }
        let available = (json["is_available"] as? Bool) != false
        return .init(provider: "DeepSeek", status: available ? "可用" : "余额不可用", rows: rows)
    }

    private static func fetchSiliconFlow(normalized: String, key: String) async throws -> ProviderWalletSnapshot {
        let root = normalized.isEmpty ? "https://api.siliconflow.cn/v1" : normalized
        guard let url = URL(string: "\(root)/user/info") else { throw AIProviderError.invalidURL }
        let json = try await json(url: url, key: key)
        guard let data = json["data"] as? [String: Any] else { throw QuotaFetchError.invalidResponse }
        var rows: [ProviderWalletSnapshot.Row] = []
        for (label, key) in [("可用余额", "balance"), ("充值余额", "chargeBalance"), ("总额度", "totalBalance")] {
            if let value = number(data[key]) { rows.append(.init(label: label, value: money(value))) }
        }
        guard !rows.isEmpty else { throw QuotaFetchError.invalidResponse }
        return .init(provider: "硅基流动", status: "账户额度", rows: rows)
    }

    private static func json(url: URL, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await checkedData(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        return json
    }

    private static func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaFetchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var message = "额度查询失败（HTTP \(http.statusCode)）"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) {
                message = detail
            }
            throw QuotaFetchError.server(message)
        }
        return data
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func stringNumber(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = number(value) { return String(format: "%.2f", value) }
        return nil
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private struct ClaudeQuotaView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ClaudeStateSnapshot?
    @State private var loading = true
    @State private var errorMessage: String?

    @State private var kanbanLoading = true

    // 看板网页由用户自己部署的服务器提供；未设置服务器地址时显示提示。
    var body: some View {
        NavigationStack {
            ZStack {
                if let url = ServerConfig.workbenchWebURL {
                    WorkspaceWebView(url: url, isLoading: $kanbanLoading)
                        .ignoresSafeArea(edges: .bottom)
                    if kanbanLoading { ProgressView() }
                } else {
                    ContentUnavailableView("未设置服务器地址", systemImage: "server.rack",
                                           description: Text("在设置里填写你自己部署的服务器地址后，这里会打开额度与状态看板。"))
                }
            }
            .navigationTitle("额度与状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }

    var nativeBody: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    if let snapshot {
                        VStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(snapshot.model.name).font(.system(size: 21, weight: .bold))
                                        Text("\(snapshot.model.id) · \(snapshot.model.effort)")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Label(snapshot.heartbeat.status == "active" ? "在线" : "离线", systemImage: "circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(snapshot.heartbeat.status == "active" ? Color.green : Color.secondary)
                                }
                                Text("最近心跳 \(Int(snapshot.heartbeat.ageSec)) 秒前")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(18)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))

                            VStack(spacing: 16) {
                                ForEach(snapshot.usage.rows) { row in
                                    quotaProgress(label: row.label, percent: row.percent, detail: resetText(row.resetsAt))
                                }
                            }
                            .padding(18)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))

                            VStack(spacing: 12) {
                                quotaProgress(
                                    label: "上下文",
                                    percent: snapshot.model.context.percent,
                                    detail: "\(snapshot.model.context.tokens.formatted()) / \(snapshot.model.context.budget.formatted()) tokens"
                                )
                                HStack {
                                    Text("压缩 \(snapshot.model.context.compactions) 次")
                                    Spacer()
                                    Text(snapshot.model.context.level.uppercased())
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            }
                            .padding(18)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                        }
                        .padding(16)
                    } else if loading {
                        ProgressView("正在拉取额度…")
                            .padding(.top, 80)
                    } else {
                        ContentUnavailableView("额度读取失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage ?? "请稍后重试"))
                            .padding(.top, 50)
                    }
                }
            }
            .navigationTitle("额度与状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func quotaProgress(label: String, percent: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(percent >= 85 ? .orange : .pink)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func resetText(_ raw: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: raw) else { return "回血时间：\(raw)" }
        return "回血时间：\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do { snapshot = try await QuotaClient.fetchClaudeState() }
        catch { snapshot = nil; errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct ProviderWalletView: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: AIConversation
    @State private var snapshot: ProviderWalletSnapshot?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                if let snapshot {
                    VStack(spacing: 14) {
                        VStack(spacing: 5) {
                            AIConversationAvatar(conversation: conversation, size: 72)
                            Text(snapshot.provider).font(.system(size: 20, weight: .bold))
                            Text(snapshot.status).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))

                        VStack(spacing: 0) {
                            ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                                HStack {
                                    Text(row.label)
                                    Spacer()
                                    Text(row.value).fontWeight(.semibold)
                                }
                                .padding(.horizontal, 18).frame(height: 56)
                                if index < snapshot.rows.count - 1 { Divider().padding(.leading, 18) }
                            }
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                        Spacer()
                    }
                    .padding(16)
                } else if loading {
                    ProgressView("正在查询钱包…")
                } else {
                    ContentUnavailableView("暂时查不到钱包余额", systemImage: "creditcard.trianglebadge.exclamationmark", description: Text(errorMessage ?? "该供应商没有开放余额接口"))
                }
            }
            .navigationTitle("钱包额度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do { snapshot = try await QuotaClient.fetchWallet(for: conversation) }
        catch { snapshot = nil; errorMessage = error.localizedDescription }
        loading = false
    }
}

private struct WorkspaceItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var urlString: String
    var symbol: String
    var colorToken: String
    var isFavorite: Bool
    var lastOpenedAt: TimeInterval

    var url: URL? {
        guard let value = URL(string: urlString),
              let scheme = value.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return value
    }

    var host: String {
        url?.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? urlString
    }

    var iconURLs: [URL] {
        guard let url,
              let scheme = url.scheme,
              let host = url.host(percentEncoded: true) else { return [] }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host

        var candidates: [URL] = []
        origin.path = "/apple-touch-icon.png"
        if let appleTouchIcon = origin.url { candidates.append(appleTouchIcon) }
        origin.path = "/favicon.ico"
        if let favicon = origin.url { candidates.append(favicon) }

        var fallback = URLComponents(string: "https://www.google.com/s2/favicons")
        fallback?.queryItems = [
            URLQueryItem(name: "domain_url", value: url.absoluteString),
            URLQueryItem(name: "sz", value: "128")
        ]
        if let fallbackURL = fallback?.url { candidates.append(fallbackURL) }
        return candidates
    }

    static let defaults: [WorkspaceItem] = [
        WorkspaceItem(
            id: "official-chatgpt",
            name: "ChatGPT",
            urlString: "https://chatgpt.com",
            symbol: "sparkles",
            colorToken: "pink",
            isFavorite: true,
            lastOpenedAt: 4
        ),
        WorkspaceItem(
            id: "official-github",
            name: "GitHub",
            urlString: "https://github.com",
            symbol: "chevron.left.forwardslash.chevron.right",
            colorToken: "purple",
            isFavorite: true,
            lastOpenedAt: 3
        ),
        WorkspaceItem(
            id: "official-notion",
            name: "Notion",
            urlString: "https://www.notion.so",
            symbol: "doc.text.fill",
            colorToken: "blue",
            isFavorite: true,
            lastOpenedAt: 2
        ),
        WorkspaceItem(
            id: "official-cloudflare",
            name: "Cloudflare",
            urlString: "https://dash.cloudflare.com",
            symbol: "cloud.fill",
            colorToken: "orange",
            isFavorite: false,
            lastOpenedAt: 1
        )
    ]
}

private extension WorkspaceItem {
    var tint: Color {
        switch colorToken {
        case "purple": return Color(red: 0.66, green: 0.48, blue: 0.95)
        case "blue": return Color(red: 0.38, green: 0.66, blue: 0.98)
        case "orange": return Color(red: 1.00, green: 0.62, blue: 0.34)
        case "green": return Color(red: 0.36, green: 0.78, blue: 0.60)
        default: return Color(red: 1.00, green: 0.50, blue: 0.70)
        }
    }
}

private struct WorkspaceWebsiteIcon: View {
    let item: WorkspaceItem
    @State private var websiteIcon: UIImage?

    var body: some View {
        ZStack {
            if let websiteIcon {
                Circle().fill(Color.white.opacity(0.94))
                Image(uiImage: websiteIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(10)
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [item.tint.opacity(0.95), item.tint.opacity(0.58)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: item.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Circle().stroke(Color.white.opacity(0.42), lineWidth: 0.8)
        }
        .frame(width: 58, height: 58)
        .shadow(color: item.tint.opacity(0.24), radius: 10, y: 5)
        .task(id: item.urlString) {
            websiteIcon = nil
            for iconURL in item.iconURLs {
                guard !Task.isCancelled else { return }
                var request = URLRequest(url: iconURL)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 8
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { continue }
                websiteIcon = image
                return
            }
        }
    }
}

/// Records the scroll phase at the moment a finger lands on a scroll view, so a drag gesture
/// can tell a deliberate pull from rest apart from a scroll that only just reached the edge.
private final class ScrollTouchState {
    /// True while a finger is down and the scroll view is tracking it.
    var touching = false
    /// Whether the current touch landed while the content was idle (not mid-momentum).
    var beganAtRest = false
    var touchBeganAt = Date.distantPast
    /// Kept current by the owner: whether the content is scrolled to its very top.
    var atTop = true
    /// Whether the content was at its very top when the current touch landed.
    var beganAtTop = false
    fileprivate var settled = true
}

private struct ScrollTouchTracker: ViewModifier {
    let state: ScrollTouchState

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { old, new in
                if new == .tracking || new == .interacting {
                    if !state.touching {
                        state.touching = true
                        state.touchBeganAt = Date()
                        state.beganAtRest = old == .idle && state.settled
                        state.beganAtTop = state.atTop
                    }
                } else {
                    state.touching = false
                    state.settled = new == .idle
                }
            }
        } else {
            content
        }
    }
}

private struct ConversationScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WorkspaceLauncherView: View {
    let items: [WorkspaceItem]
    let conversationCount: Int
    let onOpen: (WorkspaceItem) -> Void
    let onAdd: () -> Void
    let onToggleFavorite: (WorkspaceItem) -> Void
    let onDelete: (WorkspaceItem) -> Void
    let onClose: () -> Void
    let onCloseDragChanged: (CGFloat) -> Void
    let onCloseDragEnded: (CGFloat, CGFloat) -> Void

    @State private var search = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    private var filtered: [WorkspaceItem] {
        guard !search.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.host.localizedCaseInsensitiveContains(search)
        }
    }

    private var recents: [WorkspaceItem] {
        Array(filtered.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(8))
    }

    private var favorites: [WorkspaceItem] {
        filtered.filter(\.isFavorite)
    }

    var body: some View {
        ZStack {
            AppBackdrop()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Spacer()
                        Text("工作台")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .overlay(alignment: .trailing) {
                        Button(action: onAdd) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48)
                                .modifier(Glass(shape: Circle()))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加工作台入口")
                    }
                    .padding(.top, 12)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        TextField("搜索网址和工作区", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))

                    workspaceSection(title: "最近使用", items: recents)
                    workspaceSection(title: "常用", items: favorites)

                    if filtered.isEmpty {
                        ContentUnavailableView("没有找到入口", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .frame(height: 180)
                    }

                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 22)
                .padding(.top, 44)
            }
            .scrollIndicators(.hidden)

            VStack {
                Spacer()
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.32))
                            .frame(width: 34, height: 4)
                        Text("熊窝（\(conversationCount)）")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    guard value.translation.height < 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    onCloseDragChanged(-value.translation.height)
                }
                .onEnded { value in
                    onCloseDragEnded(
                        max(0, -value.translation.height),
                        max(0, -value.predictedEndTranslation.height)
                    )
                }
        )
    }

    @ViewBuilder
    private func workspaceSection(title: String, items: [WorkspaceItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        Button { onOpen(item) } label: {
                            VStack(spacing: 9) {
                                WorkspaceWebsiteIcon(item: item)

                                Text(item.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { onToggleFavorite(item) } label: {
                                Label(item.isFavorite ? "取消常用" : "设为常用", systemImage: item.isFavorite ? "star.slash" : "star")
                            }
                            if !item.id.hasPrefix("official-") {
                                Button(role: .destructive) { onDelete(item) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AddWorkspaceItemView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (WorkspaceItem) -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var colorToken = "pink"
    @State private var errorMessage: String?

    private let colors = ["pink", "purple", "blue", "orange", "green"]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 0) {
                            TextField("名称，例如：我的工作区", text: $name)
                                .textInputAutocapitalization(.never)
                                .padding(17)
                            Divider().opacity(0.25)
                            TextField("网址，例如：https://example.com", text: $address)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(17)
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))

                        VStack(alignment: .leading, spacing: 14) {
                            Text("图标颜色")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                ForEach(colors, id: \.self) { token in
                                    Button {
                                        colorToken = token
                                    } label: {
                                        Circle()
                                            .fill(sampleTint(token))
                                            .frame(width: 40, height: 40)
                                            .overlay {
                                                if colorToken == token {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 14, weight: .bold))
                                                        .foregroundStyle(.white)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("添加入口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加", action: save) }
            }
            .alert("无法添加", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func sampleTint(_ token: String) -> Color {
        WorkspaceItem(id: "sample", name: "", urlString: "https://example.com", symbol: "globe", colorToken: token, isFavorite: false, lastOpenedAt: 0).tint
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAddress.contains("://") { cleanAddress = "https://" + cleanAddress }
        guard !cleanName.isEmpty else {
            errorMessage = "先给这个入口取个名字。"
            return
        }
        guard let url = URL(string: cleanAddress),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else {
            errorMessage = "请输入完整的 http 或 https 网址。"
            return
        }
        onSave(
            WorkspaceItem(
                id: UUID().uuidString,
                name: cleanName,
                urlString: url.absoluteString,
                symbol: "globe",
                colorToken: colorToken,
                isFavorite: true,
                lastOpenedAt: Date.now.timeIntervalSince1970
            )
        )
        dismiss()
    }
}

private struct WorkspaceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: WorkspaceItem
    @State private var isLoading = true
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(.systemBackground).ignoresSafeArea()
                if let url = item.url {
                    WorkspaceWebView(url: url, isLoading: $isLoading)
                        .id(reloadID)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("网址无效", systemImage: "exclamationmark.triangle")
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        reloadID += 1
                        isLoading = true
                    } label: { Image(systemName: "arrow.clockwise") }
                    if let url = item.url {
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                    }
                }
            }
        }
    }
}

private struct WorkspaceWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        if url.query?.contains("glass=1") == true {
            // 让网页底下的液态玻璃透出来
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
        }
        let target = url
        BeardenAuth.seed(configuration.websiteDataStore.httpCookieStore) { [weak webView] in
            webView?.load(URLRequest(url: target))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil, !webView.isLoading else { return }
        let target = url
        BeardenAuth.seed(webView.configuration.websiteDataStore.httpCookieStore) { [weak webView] in
            guard let webView, webView.url == nil else { return }
            webView.load(URLRequest(url: target))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding private var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

struct ConversationListView: View {
    @Binding var hidesRootTabBar: Bool
    @StateObject private var store = ChatStore()
    @State private var search = ""
    @State private var conversations: [AIConversation] = []
    @State private var selectedConversation: AIConversation?
    @State private var claudeUnreadStartMessageID: Int?
    @State private var showingAddAI = false
    @State private var showingCreateGroup = false
    @State private var loaded = false
    @State private var workspaceItems: [WorkspaceItem] = []
    @State private var workspaceOpen = false
    @State private var workspaceLayerVisible = false
    @State private var workspacePullDistance: CGFloat = 0
    @State private var workspaceCloseDistance: CGFloat = 0
    @State private var workspacePullTracking = false
    @GestureState private var workspacePullGestureRunning = false
    @State private var conversationListAtTop = true
    /// When the list last came to rest at the top; a scroll that only just arrived there
    /// (momentum or the same finger still scrolling up) must not open the workspace.
    @State private var conversationListAtTopSince = Date.distantPast
    /// Decided once on the first sample of each drag: nil = undecided, true = may pull.
    @State private var workspacePullEligible: Bool?
    @State private var conversationScrollTouch = ScrollTouchState()
    @State private var showingAddWorkspace = false
    @State private var selectedWorkspaceItem: WorkspaceItem?
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @AppStorage("workspaceItemsJSON") private var workspaceItemsJSON = ""
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("claudeUnreadCount") private var claudeUnreadCount = 0
    @AppStorage("claudeLastReadMessageID") private var claudeLastReadMessageID = 0
    @AppStorage("claudeUnreadTrackingInitialized") private var claudeUnreadTrackingInitialized = false
    @AppStorage("localAIInboxVersion") private var localAIInboxVersion = 0

    private var filtered: [AIConversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter {
            displayName($0).localizedCaseInsensitiveContains(search) ||
            $0.signature.localizedCaseInsensitiveContains(search) ||
            LocalAIInbox.entry($0.id).preview.localizedCaseInsensitiveContains(search)
        }
    }

    private var pinned: [AIConversation] {
        byRecent(filtered.filter(\.pinned))
    }

    private var regular: [AIConversation] {
        byRecent(filtered.filter { !$0.pinned })
    }

    /// Newest conversation first inside each section; conversations without any message keep
    /// their saved order below the active ones.
    private func byRecent(_ items: [AIConversation]) -> [AIConversation] {
        _ = localAIInboxVersion
        let dated = items.enumerated().map { ($0.offset, $0.element, lastActivity($0.element)) }
        return dated.sorted { lhs, rhs in
            switch (lhs.2, rhs.2) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.0 < rhs.0
            }
        }.map(\.1)
    }

    private func lastActivity(_ conversation: AIConversation) -> Date? {
        if conversation.id == "claude" {
            guard let ts = lastVisibleMessage?.ts else { return nil }
            let raw = Double(ts)
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return LocalAIInbox.entry(conversation.id).time
    }

    private func reconcileInbox() {
        for conversation in conversations where conversation.id != "claude" {
            LocalAIInbox.reconcile(conversation.id)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if workspaceLayerVisible {
                    WorkspaceLauncherView(
                        items: workspaceItems,
                        conversationCount: conversations.count,
                        onOpen: openWorkspace,
                        onAdd: { showingAddWorkspace = true },
                        onToggleFavorite: toggleWorkspaceFavorite,
                        onDelete: deleteWorkspace,
                        onClose: closeWorkspace,
                        onCloseDragChanged: updateWorkspaceCloseDrag,
                        onCloseDragEnded: finishWorkspaceCloseDrag
                    )
                    .ignoresSafeArea()
                    .opacity(workspaceRevealProgress)
                    .scaleEffect(0.96 + (0.04 * workspaceRevealProgress))
                    .offset(y: -24 * (1 - workspaceRevealProgress))
                    .allowsHitTesting(workspaceOpen)
                    .zIndex(0)
                }

                NavigationStack {
            ZStack {
                AppBackdrop()

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索", text: $search)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .modifier(Glass(shape: Capsule()))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? "还没有会话" : "没有搜索结果",
                            systemImage: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                            description: Text(search.isEmpty ? "点右上角加号添加新的 AI" : "换个关键词试试")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationScrollOffsetKey.self,
                                    value: geometry.frame(in: .named("conversation-list-scroll")).minY
                                )
                            }
                            .frame(height: 0)

                            LazyVStack(spacing: 18) {
                                if !pinned.isEmpty {
                                    conversationCard(pinned, title: "置顶")
                                }

                                if !regular.isEmpty {
                                    conversationCard(regular, title: "其他联系人和群聊")
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 110)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                        }
                        .coordinateSpace(name: "conversation-list-scroll")
                        .onPreferenceChange(ConversationScrollOffsetKey.self) { value in
                            guard !workspaceLayerVisible else { return }
                            let atTop = value >= -2
                            conversationScrollTouch.atTop = atTop
                            if conversationListAtTop != atTop {
                                conversationListAtTop = atTop
                                if atTop { conversationListAtTopSince = Date() }
                            }
                        }
                        .modifier(ScrollTouchTracker(state: conversationScrollTouch))
                        .scrollDisabled(workspaceLayerVisible)
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .navigationTitle("熊窝")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingAddAI = true
                        } label: {
                            Label("创建 AI", systemImage: "sparkles")
                        }

                        Button {
                            showingCreateGroup = true
                        } label: {
                            Label("创建群聊", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 21, weight: .regular))
                    }
                    .accessibilityLabel("新建")
                }
            }
            .navigationDestination(item: $selectedConversation) { conversation in
                if conversation.id == "claude" {
                    ChatView(store: store, isPinned: Binding(
                        get: { conversations.first(where: { $0.id == "claude" })?.pinned ?? false },
                        set: { value in
                            guard let index = conversations.firstIndex(where: { $0.id == "claude" }) else { return }
                            conversations[index].pinned = value
                            persist()
                        }
                    ), groupMembers: conversations.filter { $0.kind != "group" }, onCreateGroup: { conversation in
                        conversations.append(conversation)
                        persist()
                    }, unreadStartMessageID: claudeUnreadStartMessageID, onReachedLatest: {
                        markClaudeRead()
                    })
                } else if conversation.kind == "group" {
                    AddedAIChatView(conversation: latestConversation(conversation), onLeave: {
                        delete(conversation)
                        selectedConversation = nil
                    })
                } else {
                    LocalAIChatScreen(conversation: latestConversation(conversation))
                        .id(conversation.id)
                }
            }
            .sheet(isPresented: $showingAddAI) {
                AddAIView { conversation in
                    conversations.append(conversation)
                    persist()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingCreateGroup) {
                CreateGroupView(members: conversations.filter { $0.kind != "group" }) { conversation in
                    conversations.append(conversation)
                    persist()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
                }
                .offset(y: workspaceFrontOffset(containerHeight: geometry.size.height))
                .allowsHitTesting(!workspaceOpen)
                .zIndex(1)
            }
        }
        .simultaneousGesture(workspacePullGesture)
        .toolbar(workspaceOpen ? .hidden : .automatic, for: .navigationBar)
        .toolbar((workspaceOpen || selectedConversation != nil) ? .hidden : .automatic, for: .tabBar)
        .sheet(isPresented: $showingAddWorkspace) {
            AddWorkspaceItemView { item in
                workspaceItems.append(item)
                persistWorkspaceItems()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $selectedWorkspaceItem) { item in
            WorkspaceBrowserView(item: item)
        }
        .onAppear {
            store.start()
            if !loaded {
                loaded = true
            }
            loadConversations()
            loadWorkspaceItems()
            syncRootTabBarVisibility()
            reconcileInbox()
        }
        .onDisappear {
            store.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localAIMessageAppended)) { _ in
            reconcileInbox()
        }
        .onChange(of: conversationsJSON) { _, _ in loadConversations() }
        .onChange(of: workspaceItemsJSON) { _, _ in loadWorkspaceItems() }
        .onChange(of: selectedConversation) { _, conversation in
            syncRootTabBarVisibility()
            if conversation == nil {
                claudeUnreadStartMessageID = nil
                // The closed chat may still be writing its history on the disk queue.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reconcileInbox() }
            }
        }
        .onChange(of: workspaceOpen) { _, _ in syncRootTabBarVisibility() }
        .onChange(of: workspacePullGestureRunning) { _, running in
            // GestureState also resets when another system gesture cancels the drag.
            if !running {
                workspacePullEligible = nil
                if workspacePullTracking || (!workspaceOpen && workspacePullDistance != 0) { cancelWorkspacePull() }
            }
        }
        .onChange(of: store.hasLoadedInitialMessages) { _, _ in syncClaudeUnreadState() }
        .onChange(of: store.msgs.last?.id) { _, _ in syncClaudeUnreadState() }
    }

    private var workspaceRevealProgress: CGFloat {
        // While open (including a close swipe) the workspace and its backdrop stay put;
        // only the front home layer slides back down over them.
        if workspaceOpen { return 1 }
        return min(max(workspacePullDistance / 220, 0), 1)
    }

    private func workspaceFrontOffset(containerHeight: CGFloat) -> CGFloat {
        if workspaceOpen {
            return max(0, containerHeight + 80 - workspaceCloseDistance)
        }
        return workspacePullDistance
    }

    private var workspacePullGesture: some Gesture {
        // The front layer moves during this gesture. Its local coordinate space
        // would feed that movement back into the next translation sample.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($workspacePullGestureRunning) { _, running, _ in
                running = true
            }
            .onChanged { value in
                guard !workspaceOpen, selectedConversation == nil else { return }
                // Only a drag that starts while the list is already resting at the top may
                // pull the workspace; scrolling back up to the top never does.
                if workspacePullEligible == nil {
                    // The scroll view's own touch record decides whether this finger landed on
                    // a list already at rest at the top. The drag sample alone cannot: it may
                    // start (or restart) after the same finger has scrolled the list up to the top.
                    let touch = conversationScrollTouch
                    if #available(iOS 18.0, *), !touch.touching, value.translation.height < 20 {
                        return
                    }
                    let landedAtRest: Bool
                    if #available(iOS 18.0, *), touch.touching {
                        // Position at touch-down decides; reaching the top later in the
                        // same drag never counts.
                        landedAtRest = touch.beganAtRest && touch.beganAtTop &&
                            touch.touchBeganAt.timeIntervalSince(conversationListAtTopSince) > 0.25
                    } else {
                        landedAtRest = Date().timeIntervalSince(conversationListAtTopSince) > 0.25
                    }
                    workspacePullEligible = conversationListAtTop &&
                        landedAtRest &&
                        search.isEmpty &&
                        value.translation.height > 0 &&
                        abs(value.translation.height) > abs(value.translation.width)
                }
                guard workspacePullEligible == true else { return }
                // The first stretch behaves like the normal list bounce; the layer only
                // starts to show after the dead zone.
                let pulled = value.translation.height - Self.workspacePullDeadZone
                guard workspacePullTracking || pulled > 0 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    workspacePullTracking = true
                    workspaceLayerVisible = true
                    workspacePullDistance = min(max(pulled * 0.92, 0), 280)
                }
            }
            .onEnded { value in
                workspacePullEligible = nil
                guard workspacePullTracking else {
                    // Never leave a partly pulled layer behind.
                    if !workspaceOpen && (workspacePullDistance != 0 || workspaceLayerVisible) { cancelWorkspacePull() }
                    return
                }
                workspacePullTracking = false
                let shouldOpen = !workspaceOpen && search.isEmpty &&
                    workspacePullDistance >= Self.workspaceOpenThreshold
                if shouldOpen {
                    withAnimation(.snappy(duration: 0.42, extraBounce: 0.02)) {
                        workspaceOpen = true
                        workspacePullDistance = 0
                    }
                } else {
                    withAnimation(.snappy(duration: 0.30, extraBounce: 0.02)) {
                        workspacePullDistance = 0
                    }
                    hideWorkspaceLayerAfterAnimation()
                }
            }
    }

    /// Pull past the dead zone, then this much more, before releasing opens the workspace.
    private static let workspacePullDeadZone: CGFloat = 24
    private static let workspaceOpenThreshold: CGFloat = 80

    private func cancelWorkspacePull() {
        workspacePullTracking = false
        withAnimation(.snappy(duration: 0.30, extraBounce: 0.02)) {
            workspacePullDistance = 0
        }
        hideWorkspaceLayerAfterAnimation()
    }

    private func closeWorkspace() {
        withAnimation(.snappy(duration: 0.38, extraBounce: 0.02)) {
            workspaceOpen = false
            workspacePullDistance = 0
            workspaceCloseDistance = 0
        }
        hideWorkspaceLayerAfterAnimation()
    }

    private func updateWorkspaceCloseDrag(_ distance: CGFloat) {
        guard workspaceOpen else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            workspaceCloseDistance = min(max(distance, 0), 360)
        }
    }

    private func finishWorkspaceCloseDrag(_ distance: CGFloat, _ predictedDistance: CGFloat) {
        guard workspaceOpen else { return }
        // A short upward swipe is enough to send the workspace back, like WeChat's mini-program pane.
        let shouldClose = distance >= 36 || predictedDistance >= 80
        if shouldClose {
            closeWorkspace()
        } else {
            withAnimation(.snappy(duration: 0.30, extraBounce: 0.02)) {
                workspaceCloseDistance = 0
            }
        }
    }

    private func syncRootTabBarVisibility() {
        hidesRootTabBar = selectedConversation != nil || workspaceOpen
    }

    private func hideWorkspaceLayerAfterAnimation() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !workspaceOpen,
                  workspacePullDistance == 0,
                  workspaceCloseDistance == 0 else { return }
            workspaceLayerVisible = false
        }
    }

    private func loadWorkspaceItems() {
        if let data = workspaceItemsJSON.data(using: .utf8),
           let saved = try? JSONDecoder().decode([WorkspaceItem].self, from: data),
           !saved.isEmpty {
            workspaceItems = saved
        } else {
            workspaceItems = WorkspaceItem.defaults
            persistWorkspaceItems()
        }
    }

    private func persistWorkspaceItems() {
        guard let data = try? JSONEncoder().encode(workspaceItems),
              let value = String(data: data, encoding: .utf8) else { return }
        workspaceItemsJSON = value
    }

    private func openWorkspace(_ item: WorkspaceItem) {
        guard let index = workspaceItems.firstIndex(where: { $0.id == item.id }) else { return }
        workspaceItems[index].lastOpenedAt = Date.now.timeIntervalSince1970
        let latest = workspaceItems[index]
        persistWorkspaceItems()
        selectedWorkspaceItem = latest
    }

    private func toggleWorkspaceFavorite(_ item: WorkspaceItem) {
        guard let index = workspaceItems.firstIndex(where: { $0.id == item.id }) else { return }
        workspaceItems[index].isFavorite.toggle()
        persistWorkspaceItems()
    }

    private func deleteWorkspace(_ item: WorkspaceItem) {
        guard !item.id.hasPrefix("official-") else { return }
        workspaceItems.removeAll { $0.id == item.id }
        persistWorkspaceItems()
    }

    @ViewBuilder
    private func conversationCard(_ items: [AIConversation], title: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 7)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        hidesRootTabBar = true
                        if conversation.id == "claude" {
                            claudeUnreadStartMessageID = firstUnreadClaudeMessageID
                        }
                        selectedConversation = conversation
                    } label: {
                        ConversationRow(
                            title: displayName(conversation),
                            preview: conversation.id == "claude" ? preview :
                                (localAIInboxVersion >= 0 ? localPreview(conversation) : ""),
                            time: conversation.id == "claude" ? messageTime :
                                (localAIInboxVersion >= 0 ? LocalAIInbox.entry(conversation.id).time?.formatted(date: .omitted, time: .shortened) ?? "" : ""),
                            symbol: conversation.symbol,
                            avatarFile: conversation.avatarFile,
                            primary: conversation.id == "claude",
                            unreadCount: conversation.id == "claude" ? claudeUnreadCount :
                                LocalAIInbox.entry(conversation.id).unreadCount
                        )
                        .frame(height: 76)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            togglePin(conversation)
                        } label: {
                            Label(
                                conversation.pinned ? "取消置顶" : "置顶",
                                systemImage: conversation.pinned ? "pin.slash.fill" : "pin.fill"
                            )
                        }
                        Button(role: .destructive) {
                            delete(conversation)
                        } label: {
                            Label("删除", systemImage: "trash.fill")
                        }
                    }

                    if index < items.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.28))
                            .padding(.leading, 74)
                    }
                }
            }
            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
        }
    }

    private func localPreview(_ conversation: AIConversation) -> String {
        let entry = LocalAIInbox.entry(conversation.id)
        if !entry.preview.isEmpty { return entry.preview }
        if conversation.kind == "group" {
            return "群聊 · \((conversation.groupMemberIDs?.count ?? 0) + 1) 位成员"
        }
        return "在线"
    }

    private func displayName(_ conversation: AIConversation) -> String {
        conversation.id == "claude" ? assistantRemark : conversation.displayName
    }

    private func latestConversation(_ conversation: AIConversation) -> AIConversation {
        conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private func loadConversations() {
        if let data = conversationsJSON.data(using: .utf8),
           let saved = try? JSONDecoder().decode([AIConversation].self, from: data) {
            conversations = saved
            if !conversations.contains(where: { $0.id == "claude" }) {
                conversations.insert(Self.claudeConversation, at: 0)
                persist()
            }
        } else {
            conversations = [Self.claudeConversation]
            persist()
        }
    }

    private static let claudeConversation = AIConversation(
        id: "claude",
        name: "助手",
        signature: "随时在线，等你来聊天",
        symbol: "ellipsis.curlybraces",
        pinned: true
    )

    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations),
              let value = String(data: data, encoding: .utf8) else { return }
        conversationsJSON = value
    }

    private func togglePin(_ conversation: AIConversation) {
        let id = conversation.id
        // Context menus keep a snapshot of the source row during dismissal. Moving that row
        // between two glass containers immediately creates a temporary duplicate preview.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                conversations[index].pinned.toggle()
            }
            persist()
        }
    }

    private func delete(_ conversation: AIConversation) {
        let credentialID = conversation.credentialID
        let avatarFile = conversation.avatarFile
        let id = conversation.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            AIKeychain.delete(account: credentialID)
            AIAvatarStore.delete(named: avatarFile)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                conversations.removeAll { $0.id == id }
            }
            persist()
        }
    }

    private var lastVisibleMessage: Msg? {
        let hiddenThrough = UserDefaults.standard.integer(forKey: "claudeHiddenThroughID")
        return store.msgs.last(where: {
            $0.id > hiddenThrough &&
            !store.isRetracted($0.id) &&
            !$0.text.hasPrefix("【已确认】") &&
            !$0.text.hasPrefix("【已跳过】")
        })
    }

    private var preview: String {
        guard let last = lastVisibleMessage else { return "连接中…" }
        if let file = last.file {
            return API.isImage(file) ? "[图片]" : (API.isAudio(file) ? "[语音]" : "[文件] \(file.replacingOccurrences(of: "^\\d+-", with: "", options: .regularExpression))")
        }
        if LocationInfo.parse(last.text) != nil { return "[位置]" }
        if ApprovePayload.parse(last.text) != nil { return "[需要确认]" }
        let t = last.text.replacingOccurrences(of: "\n", with: " ")
        return t.isEmpty ? " " : t
    }

    private var messageTime: String {
        guard let ts = lastVisibleMessage?.ts else { return "" }
        let raw = Double(ts)
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .shortened)
    }

    private var latestClaudeMessageID: Int {
        store.msgs.lazy.filter { $0.from != "me" }.map(\.id).max() ?? claudeLastReadMessageID
    }

    private var firstUnreadClaudeMessageID: Int? {
        store.msgs.first {
            $0.from != "me" &&
            $0.id > claudeLastReadMessageID &&
            !store.isRetracted($0.id)
        }?.id
    }

    private func syncClaudeUnreadState() {
        guard store.hasLoadedInitialMessages else { return }
        let latestID = latestClaudeMessageID
        guard claudeUnreadTrackingInitialized else {
            claudeUnreadTrackingInitialized = true
            claudeLastReadMessageID = latestID
            claudeUnreadCount = 0
            return
        }
        if selectedConversation?.id == "claude" {
            markClaudeRead()
        } else {
            claudeUnreadCount = store.msgs.reduce(into: 0) { count, message in
                if message.from != "me" && message.id > claudeLastReadMessageID {
                    count += 1
                }
            }
        }
    }

    private func markClaudeRead() {
        guard store.hasLoadedInitialMessages else { return }
        claudeLastReadMessageID = latestClaudeMessageID
        claudeUnreadCount = 0
    }
}

struct ConversationRow: View {
    let title: String
    let preview: String
    let time: String
    let symbol: String
    let avatarFile: String?
    let primary: Bool
    let unreadCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if primary {
                    Avatar(isMe: false)
                        .scaleEffect(1.28)
                } else if let image = AIAvatarStore.image(named: avatarFile) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.00, green: 0.76, blue: 0.84),
                                        Color(red: 0.78, green: 0.72, blue: 0.96)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : String(unreadCount))
                        .font(.system(size: unreadCount > 99 ? 9 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, unreadCount > 9 ? 5 : 0)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Color.red, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 7, y: -6)
                        .accessibilityLabel("\(unreadCount) 条未读消息")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(time)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(alignment: .topTrailing)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum AIServiceKind {
    case subscription
    case api
}

private struct AIServiceOption: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let kind: AIServiceKind
    let baseURL: String
    let defaultModel: String
    let suggestedModels: [String]
    let interfaceFormat: String
}

private let aiServiceCatalog: [AIServiceOption] = [
    AIServiceOption(id: "chatgpt", name: "ChatGPT / Codex", subtitle: "ChatGPT 套餐 · 官方登录", symbol: "circle.hexagongrid.fill", kind: .subscription, baseURL: "https://api.openai.com/v1", defaultModel: "gpt-6.1-sol", suggestedModels: ["gpt-6.1-sol"], interfaceFormat: "OpenAI Responses"),
    AIServiceOption(id: "claude-subscription", name: "Claude", subtitle: "订阅账号 · 登录连接", symbol: "sparkles", kind: .subscription, baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-4.6", suggestedModels: ["claude-opus-4.6", "claude-sonnet-4.6"], interfaceFormat: "Anthropic"),
    AIServiceOption(id: "kimi", name: "Kimi Code", subtitle: "订阅账号 · 登录连接", symbol: "moon.stars.fill", kind: .subscription, baseURL: "https://api.moonshot.cn/v1", defaultModel: "kimi-k2.5", suggestedModels: ["kimi-k2.5", "kimi-code"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "grok", name: "Grok", subtitle: "订阅账号 · 登录连接", symbol: "bolt.horizontal.circle.fill", kind: .subscription, baseURL: "https://api.x.ai/v1", defaultModel: "grok-4", suggestedModels: ["grok-4", "grok-4-fast"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "openai", name: "OpenAI", subtitle: "官方 API", symbol: "circle.hexagongrid.fill", kind: .api, baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5.2", suggestedModels: ["gpt-5.2", "gpt-5-mini", "gpt-4.1"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "anthropic", name: "Anthropic", subtitle: "Claude 官方 API", symbol: "sparkles", kind: .api, baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-4.6", suggestedModels: ["claude-sonnet-4.6", "claude-opus-4.6"], interfaceFormat: "Anthropic"),
    AIServiceOption(id: "google", name: "Google AI Studio", subtitle: "Gemini 官方 API", symbol: "diamond.fill", kind: .api, baseURL: "https://generativelanguage.googleapis.com", defaultModel: "gemini-3-flash", suggestedModels: ["gemini-3-flash", "gemini-3-pro"], interfaceFormat: "Gemini"),
    AIServiceOption(id: "deepseek", name: "DeepSeek", subtitle: "官方 API", symbol: "water.waves", kind: .api, baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat", suggestedModels: ["deepseek-chat", "deepseek-reasoner"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "xai", name: "xAI", subtitle: "Grok 官方 API", symbol: "bolt.horizontal.circle.fill", kind: .api, baseURL: "https://api.x.ai/v1", defaultModel: "grok-4", suggestedModels: ["grok-4", "grok-4-fast"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "openrouter", name: "OpenRouter", subtitle: "聚合模型 API", symbol: "arrow.triangle.branch", kind: .api, baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-5.2", suggestedModels: ["openai/gpt-5.2", "anthropic/claude-sonnet-4.6", "google/gemini-3-pro"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "siliconflow", name: "硅基流动", subtitle: "聚合模型 API", symbol: "waveform.path.ecg", kind: .api, baseURL: "https://api.siliconflow.cn/v1", defaultModel: "deepseek-ai/DeepSeek-V3.2", suggestedModels: ["deepseek-ai/DeepSeek-V3.2", "Qwen/Qwen3-235B"], interfaceFormat: "OpenAI 兼容"),
    AIServiceOption(id: "custom", name: "自定义", subtitle: "填写兼容接口与模型", symbol: "slider.horizontal.3", kind: .api, baseURL: "", defaultModel: "", suggestedModels: [], interfaceFormat: "OpenAI 兼容")
]

struct AddAIView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let onAdd: (AIConversation) -> Void

    private var filteredServices: [AIServiceOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return aiServiceCatalog }
        return aiServiceCatalog.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query) ||
            $0.interfaceFormat.localizedCaseInsensitiveContains(query)
        }
    }

    private var subscriptions: [AIServiceOption] {
        filteredServices.filter { $0.kind == .subscription }
    }

    private var apiServices: [AIServiceOption] {
        filteredServices.filter { $0.kind == .api }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选择你要连接的服务，可以登录订阅账号，也可以使用 API。")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                TextField("搜索服务或接入方式", text: $search)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
                            .padding(.top, 7)
                        }

                        if !subscriptions.isEmpty {
                            serviceSection(
                                title: "订阅账号",
                                subtitle: "登录已有账号，继续使用对应服务。",
                                services: subscriptions
                            )
                        }

                        if !apiServices.isEmpty {
                            serviceSection(
                                title: "API 服务",
                                subtitle: "使用供应商密钥，也支持填写自己的接口地址。",
                                services: apiServices
                            )
                        }

                        if filteredServices.isEmpty {
                            ContentUnavailableView(
                                "没有找到服务",
                                systemImage: "magnifyingglass",
                                description: Text("换个名称或接入方式试试")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 70)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("连接服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { serviceID in
                if let service = aiServiceCatalog.first(where: { $0.id == serviceID }) {
                    AIProviderSetupView(service: service) { conversation in
                        onAdd(conversation)
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .modifier(Glass(shape: Circle()))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .modifier(Glass(shape: Circle()))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func serviceSection(title: String, subtitle: String, services: [AIServiceOption]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                    NavigationLink(value: service.id) {
                        AIServiceRow(service: service)
                    }
                    .buttonStyle(.plain)

                    if index < services.count - 1 {
                        Divider()
                            .opacity(0.22)
                            .padding(.leading, 74)
                    }
                }
            }
            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
        }
    }
}

private struct AIServiceRow: View {
    let service: AIServiceOption

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.14))
                Image(systemName: service.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.47, blue: 0.68))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(service.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(service.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }
}

private struct AIProviderSetupView: View {
    private enum AuthenticationMode: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case subscription = "订阅账号"
        var id: String { rawValue }
    }

    let service: AIServiceOption
    let onCreate: (AIConversation) -> Void
    @State private var providerName: String
    @State private var interfaceFormat: String
    @State private var baseURL: String
    @State private var authMode: AuthenticationMode
    @State private var apiKey = ""
    @State private var model: String
    @State private var models: [String]
    @State private var showingModelOptions = false
    @State private var loadingModels = false
    @State private var errorMessage: String?
    @State private var draftConversation: AIConversation?
    @State private var chatGPTCredentialID = "chatgpt.setup.\(UUID().uuidString)"
    @StateObject private var chatGPTOAuth = ChatGPTOAuthController()

    init(service: AIServiceOption, onCreate: @escaping (AIConversation) -> Void) {
        self.service = service
        self.onCreate = onCreate
        _providerName = State(initialValue: service.name)
        _interfaceFormat = State(initialValue: service.interfaceFormat)
        _baseURL = State(initialValue: service.baseURL)
        _authMode = State(initialValue: service.kind == .subscription ? .subscription : .apiKey)
        _model = State(initialValue: service.defaultModel)
        _models = State(initialValue: service.suggestedModels)
    }

    private var canContinue: Bool {
        let fieldsReady = !providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if authMode == .subscription {
            return fieldsReady && service.id == "chatgpt" &&
                ChatGPTCredentialStore.load(account: chatGPTCredentialID)?.canUsePlan == true
        }
        return fieldsReady && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    setupField("供应商名称") {
                        TextField("供应商名称", text: $providerName)
                            .setupInputStyle()
                    }

                    setupField("接口格式") {
                        Menu {
                            ForEach(["OpenAI 兼容", "OpenAI Responses", "Anthropic", "Gemini"], id: \.self) { value in
                                Button(value) { interfaceFormat = value }
                            }
                        } label: {
                            setupMenuLabel(interfaceFormat)
                        }
                    }

                    setupField("Base URL") {
                        TextField("https://…", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .setupInputStyle()
                    }

                    setupField("登录方式") {
                        Picker("登录方式", selection: $authMode) {
                            ForEach(AuthenticationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if authMode == .apiKey {
                        setupField("API Key") {
                            SecureField("粘贴新的 API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .setupInputStyle()
                        }
                    } else if service.id == "chatgpt" {
                        VStack(alignment: .leading, spacing: 12) {
                            if let credential = ChatGPTCredentialStore.load(account: chatGPTCredentialID), credential.canUsePlan {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("ChatGPT 已连接").font(.system(size: 15, weight: .semibold))
                                        Text(credential.email ?? "已验证账户")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            Button {
                                Task { await signInWithChatGPT() }
                            } label: {
                                HStack(spacing: 9) {
                                    if chatGPTOAuth.isAuthenticating { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "circle.hexagongrid.fill") }
                                    Text(ChatGPTCredentialStore.load(account: chatGPTCredentialID) == nil ? "Continue with ChatGPT" : "重新连接 ChatGPT")
                                }
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .background(Color.black, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(chatGPTOAuth.isAuthenticating)
                            Text("登录会在安全浏览器中完成；熊窝不会看到你的密码，也不需要 API Key。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(15)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                    } else {
                        Text("这个订阅服务还没有接入安全的官方登录。先选 API Key；目前只开放 ChatGPT 官方登录。")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(15)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                    }

                    setupField("当前模型") {
                        VStack(spacing: 10) {
                            if models.isEmpty {
                                TextField("填写模型名称", text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .setupInputStyle()
                            } else {
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        showingModelOptions.toggle()
                                    }
                                } label: {
                                    setupMenuLabel(model.isEmpty ? "请选择模型" : model)
                                }
                                .buttonStyle(.plain)

                                if showingModelOptions {
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            ForEach(models, id: \.self) { value in
                                                Button {
                                                    model = value
                                                    withAnimation(.easeOut(duration: 0.16)) {
                                                        showingModelOptions = false
                                                    }
                                                } label: {
                                                    Text(value)
                                                        .font(.system(size: 15, weight: model == value ? .semibold : .regular))
                                                        .foregroundStyle(.primary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .padding(.horizontal, 16)
                                                        .frame(height: 46)
                                                }
                                                .buttonStyle(.plain)
                                                if value != models.last { Divider().opacity(0.18) }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 230)
                                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                                }
                            }

                            Button {
                                Task { await fetchModels() }
                            } label: {
                                HStack(spacing: 8) {
                                    if loadingModels { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                    Text(loadingModels ? "正在拉取…" : "拉取可选模型")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 45)
                                .modifier(Glass(shape: Capsule()))
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingModels || !canFetchModels)
                            .opacity(canFetchModels ? 1 : 0.46)
                        }
                    }

                    Button(action: continueToProfile) {
                        Label("下一步：完善联系人资料", systemImage: "person.crop.circle.badge.plus")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(colors: [.pink.opacity(0.90), .purple.opacity(0.72)], startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)
                    .opacity(canContinue ? 1 : 0.45)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 34)
            }
            .scrollDismissesKeyboard(.interactively)
            ChatGPTAuthorizationSheet(controller: chatGPTOAuth)
                .frame(width: 0, height: 0)
        }
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $draftConversation) { conversation in
            AIContactEditor(conversation: conversation, isNew: true, initialModels: models, onSave: onCreate)
        }
        .alert("连接服务", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func setupField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func setupMenuLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
    }

    @MainActor
    private func fetchModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            let values: [String]
            if authMode == .subscription, service.id == "chatgpt" {
                values = try await ChatGPTPlanClient.listModels(account: chatGPTCredentialID)
            } else {
                values = try await AIProviderClient.fetchModels(baseURL: baseURL, apiKey: apiKey, format: interfaceFormat)
            }
            guard !values.isEmpty else { throw AIProviderError.server("供应商没有返回可用模型。") }
            models = values
            if !values.contains(model) { model = values[0] }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func continueToProfile() {
        let id = UUID().uuidString
        let credentialID = "ai.\(id)"
        do {
            if authMode == .subscription, service.id == "chatgpt" {
                try ChatGPTCredentialStore.copy(from: chatGPTCredentialID, to: credentialID)
            } else {
                try AIKeychain.save(apiKey, account: credentialID)
            }
            draftConversation = AIConversation(
                id: id,
                name: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
                signature: model,
                symbol: service.symbol,
                pinned: false,
                provider: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                authMode: authMode.rawValue,
                interfaceFormat: interfaceFormat,
                credentialID: credentialID
            )
        } catch {
            errorMessage = "登录信息无法安全保存：\(error.localizedDescription)"
        }
    }

    private var canFetchModels: Bool {
        if authMode == .subscription {
            return service.id == "chatgpt" && ChatGPTCredentialStore.load(account: chatGPTCredentialID)?.canUsePlan == true
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func signInWithChatGPT() async {
        do {
            _ = try await chatGPTOAuth.signIn(storageAccount: chatGPTCredentialID)
            providerName = "ChatGPT"
            interfaceFormat = "OpenAI Responses"
            baseURL = "https://api.openai.com/v1"
            await fetchModels()
        } catch ChatGPTAuthError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    func setupInputStyle() -> some View {
        self
            .padding(.horizontal, 16)
            .frame(height: 54)
            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
    }
}

private struct AIContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (AIConversation) -> Void
    @State private var conversation: AIConversation
    @State private var apiKey: String
    @State private var models: [String]
    @State private var showingModelOptions = false
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var loadingModels = false
    @State private var errorMessage: String?

    init(conversation: AIConversation, isNew: Bool, initialModels: [String] = [], onSave: @escaping (AIConversation) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _conversation = State(initialValue: conversation)
        _apiKey = State(initialValue: conversation.authMode == "订阅账号" ? "" : AIKeychain.load(account: conversation.credentialID))
        let candidates = Array(Set(initialModels + [conversation.model ?? ""])).filter { !$0.isEmpty }.sorted()
        _models = State(initialValue: candidates)
        _avatarPreview = State(initialValue: AIAvatarStore.image(named: conversation.avatarFile))
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 17) {
                    PhotosPicker(selection: $avatarPhoto, matching: .images) {
                        VStack(spacing: 8) {
                            Group {
                                if let avatarPreview {
                                    Image(uiImage: avatarPreview).resizable().scaledToFill()
                                } else {
                                    AIConversationAvatar(conversation: conversation, size: 94)
                                }
                            }
                            .frame(width: 94, height: 94)
                            .clipShape(Circle())
                            Text("修改头像")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)

                    editorField("昵称", note: "AI 自己也能看到") {
                        TextField("昵称", text: $conversation.name).setupInputStyle()
                    }
                    editorField("备注", note: "只在你的设备上显示，AI 看不见") {
                        TextField("备注（可选）", text: optionalBinding(\.remark)).setupInputStyle()
                    }
                    editorField("供应商名称", note: nil) {
                        TextField("供应商", text: optionalBinding(\.provider)).setupInputStyle()
                    }
                    editorField("接口格式", note: nil) {
                        Menu {
                            ForEach(["OpenAI 兼容", "OpenAI Responses", "Anthropic", "Gemini"], id: \.self) { value in
                                Button(value) { conversation.interfaceFormat = value }
                            }
                        } label: {
                            menuLabel(conversation.interfaceFormat ?? "OpenAI 兼容")
                        }
                    }
                    editorField("Base URL", note: nil) {
                        TextField("https://…", text: optionalBinding(\.baseURL))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .setupInputStyle()
                    }
                    if conversation.authMode == "订阅账号",
                       let credential = ChatGPTCredentialStore.load(account: conversation.credentialID) {
                        editorField("ChatGPT 账号", note: "凭证保存在系统 Keychain 中") {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(credential.email ?? "已验证账户")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(height: 54)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                        }
                    } else {
                        editorField("API Key", note: "保存在系统 Keychain 中") {
                            SecureField("API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .setupInputStyle()
                        }
                    }
                    editorField("当前模型", note: nil) {
                        VStack(spacing: 10) {
                            if models.isEmpty {
                                TextField("填写模型名称", text: optionalBinding(\.model))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .setupInputStyle()
                            } else {
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        showingModelOptions.toggle()
                                    }
                                } label: {
                                    menuLabel(conversation.model ?? "请选择模型")
                                }
                                .buttonStyle(.plain)

                                if showingModelOptions {
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            ForEach(models, id: \.self) { value in
                                                Button {
                                                    conversation.model = value
                                                    withAnimation(.easeOut(duration: 0.16)) {
                                                        showingModelOptions = false
                                                    }
                                                } label: {
                                                    Text(value)
                                                        .font(.system(size: 15, weight: conversation.model == value ? .semibold : .regular))
                                                        .foregroundStyle(.primary)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .padding(.horizontal, 16)
                                                        .frame(height: 46)
                                                }
                                                .buttonStyle(.plain)
                                                if value != models.last { Divider().opacity(0.18) }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 230)
                                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                                }
                            }
                            Button {
                                Task { await fetchModels() }
                            } label: {
                                HStack(spacing: 8) {
                                    if loadingModels { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.clockwise") }
                                    Text(loadingModels ? "正在拉取…" : "重新拉取可选模型")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .modifier(Glass(shape: Capsule()))
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingModels || (conversation.authMode != "订阅账号" && apiKey.isEmpty))
                        }
                    }

                    Button(action: save) {
                        Text(isNew ? "添加到小家" : "保存修改")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(
                                LinearGradient(colors: [.pink.opacity(0.90), .purple.opacity(0.72)], startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(conversation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 38)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(isNew ? "完善联系人资料" : "联系人详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: avatarPhoto) { _, item in loadAvatar(item) }
        .alert("联系人资料", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func editorField<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).frame(height: 54)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<AIConversation, String?>) -> Binding<String> {
        Binding(
            get: { conversation[keyPath: keyPath] ?? "" },
            set: { conversation[keyPath: keyPath] = $0 }
        )
    }

    @MainActor
    private func fetchModels() async {
        loadingModels = true
        defer { loadingModels = false }
        do {
            let values: [String]
            if conversation.authMode == "订阅账号",
               (conversation.interfaceFormat ?? "").lowercased().contains("responses") {
                values = try await ChatGPTPlanClient.listModels(account: conversation.credentialID)
            } else {
                values = try await AIProviderClient.fetchModels(
                    baseURL: conversation.baseURL ?? "",
                    apiKey: apiKey,
                    format: conversation.interfaceFormat ?? "OpenAI 兼容"
                )
            }
            guard !values.isEmpty else { throw AIProviderError.server("供应商没有返回可用模型。") }
            models = values
            if let current = conversation.model, values.contains(current) == false { conversation.model = values[0] }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAvatar(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                await MainActor.run { avatarPreview = image }
            }
        }
    }

    private func save() {
        do {
            var updated = conversation
            let account = updated.credentialID ?? "ai.\(updated.id)"
            updated.credentialID = account
            if updated.authMode != "订阅账号" {
                try AIKeychain.save(apiKey, account: account)
            } else if ChatGPTCredentialStore.load(account: account) == nil {
                throw ChatGPTAuthError.missingCredential
            }
            if let avatarPreview {
                updated.avatarFile = try AIAvatarStore.save(avatarPreview, id: updated.id)
            }
            updated.signature = updated.model ?? "新的 AI 伙伴"
            onSave(updated)
            if !isNew { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AIProviderConfigurationView: View {
    private enum AuthenticationMode: String, CaseIterable, Identifiable {
        case apiKey = "API Key"
        case subscription = "订阅账号"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let service: AIServiceOption
    let onCreate: (AIConversation) -> Void

    @State private var providerName: String
    @State private var baseURL: String
    @State private var authMode: AuthenticationMode
    @State private var apiKey = ""
    @State private var model: String
    @State private var robotName: String
    @State private var introduction = ""
    @State private var showingSubscriptionNotice = false

    init(service: AIServiceOption, onCreate: @escaping (AIConversation) -> Void) {
        self.service = service
        self.onCreate = onCreate
        _providerName = State(initialValue: service.name)
        _baseURL = State(initialValue: service.baseURL)
        _authMode = State(initialValue: service.kind == .subscription ? .subscription : .apiKey)
        _model = State(initialValue: service.defaultModel)
        _robotName = State(initialValue: service.name.replacingOccurrences(of: " / Codex", with: ""))
    }

    private var symbol: String { service.symbol }

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    providerCard

                    field(title: "供应商名称", help: "仅用于在小家里区分不同连接。") {
                        TextField("供应商名称", text: $providerName)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                    }

                    field(title: "接口格式", help: nil) {
                        HStack(spacing: 13) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color(red: 0.72, green: 0.47, blue: 0.68))
                                .frame(width: 38, height: 38)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("接口格式")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Text(service.interfaceFormat)
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 15)
                        .frame(height: 66)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                    }

                    field(title: "Base URL", help: "支持兼容接口和自建中转地址。") {
                        TextField("https://…", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                    }

                    field(title: "登录方式", help: nil) {
                        Picker("登录方式", selection: $authMode) {
                            ForEach(AuthenticationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if authMode == .apiKey {
                        field(title: "API Key", help: "密钥只用于连接所选服务。") {
                            SecureField("粘贴新的 API Key", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                                .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))
                        }
                    } else {
                        subscriptionCard
                    }

                    field(title: "当前模型", help: "也可以直接输入供应商支持的模型名称。") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                TextField("模型名称", text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 19, style: .continuous)))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(service.suggestedModels, id: \.self) { suggested in
                                        Button(suggested) { model = suggested }
                                            .font(.system(size: 13, weight: model == suggested ? .semibold : .regular))
                                            .foregroundStyle(model == suggested ? Color.white : Color.primary)
                                            .padding(.horizontal, 13)
                                            .frame(height: 34)
                                            .background(
                                                model == suggested
                                                    ? Color(red: 0.88, green: 0.55, blue: 0.72)
                                                    : Color.white.opacity(0.12),
                                                in: Capsule()
                                            )
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI 资料")
                            .font(.system(size: 22, weight: .bold))

                        VStack(spacing: 0) {
                            TextField("显示名称", text: $robotName)
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                            Divider().opacity(0.22)
                            TextField("一句简介（可选）", text: $introduction)
                                .padding(.horizontal, 16)
                                .frame(height: 54)
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 21, style: .continuous)))
                    }

                    Button(action: createConversation) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("添加到小家")
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 55)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 1.00, green: 0.58, blue: 0.74), Color(red: 0.70, green: 0.57, blue: 0.92)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(robotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(robotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 38)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert("订阅账号连接", isPresented: $showingSubscriptionNotice) {
            Button("知道了") { }
        } message: {
            Text("授权登录会在对应服务接口接入后启用；现在可以先保存机器人资料和模型配置。")
        }
    }

    private var providerCard: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().fill(Color.white.opacity(0.14))
                Image(systemName: service.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(red: 0.72, green: 0.47, blue: 0.68))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 5) {
                Text(service.name)
                    .font(.system(size: 18, weight: .bold))
                Text(service.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
    }

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 25))
                    .foregroundStyle(Color(red: 0.72, green: 0.47, blue: 0.68))
                VStack(alignment: .leading, spacing: 3) {
                    Text("订阅账号")
                        .font(.system(size: 17, weight: .semibold))
                    Text("前往供应商授权页登录，不会读取你的密码。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                showingSubscriptionNotice = true
            } label: {
                Label("登录订阅", systemImage: "person.badge.key.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.27), in: Capsule())
            }
            .buttonStyle(.plain)

            Text("实验性能力：订阅登录依赖各供应商的授权方式，上游变化后可能需要同步更新。")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
    }

    @ViewBuilder
    private func field<Content: View>(title: String, help: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            content()
            if let help {
                Text(help)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func createConversation() {
        let cleanName = robotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIntroduction = introduction.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            AIConversation(
                id: UUID().uuidString,
                name: cleanName,
                signature: cleanIntroduction.isEmpty
                    ? (cleanModel.isEmpty ? "新的 AI 伙伴" : cleanModel)
                    : cleanIntroduction,
                symbol: symbol,
                pinned: false,
                provider: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
                model: cleanModel,
                baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                authMode: authMode.rawValue
            )
        )
    }
}

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @State private var groupName = ""
    @State private var selected: Set<String> = []
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var avatarImage: UIImage?
    let members: [AIConversation]
    let onCreate: (AIConversation) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(spacing: 14) {
                        PhotosPicker(selection: $selectedAvatar, matching: .images) {
                            Group {
                                if let avatarImage { Image(uiImage: avatarImage).resizable().scaledToFill() }
                                else { Image(systemName: "person.3.fill").font(.system(size: 27)).foregroundStyle(.pink) }
                            }.frame(width: 76, height: 76).background(.white.opacity(0.25)).clipShape(Circle())
                                .overlay(alignment: .bottomTrailing) { Image(systemName: "camera.fill").font(.caption).foregroundStyle(.pink) }
                        }
                        Text("群聊头像").font(.caption).foregroundStyle(.secondary)
                        TextField("群聊名称", text: $groupName)
                            .padding(.horizontal, 15)
                            .frame(height: 50)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))

                        VStack(spacing: 0) {
                            ForEach(members) { member in
                                Button {
                                    if selected.contains(member.id) {
                                        selected.remove(member.id)
                                    } else {
                                        selected.insert(member.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        AIConversationAvatar(conversation: member, size: 40)

                                        Text(member.id == "claude" ? assistantRemark : member.displayName)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 21))
                                            .foregroundStyle(
                                                selected.contains(member.id)
                                                    ? Color(red: 1.00, green: 0.67, blue: 0.80)
                                                    : Color.secondary
                                            )
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 58)
                                }
                                .buttonStyle(.plain)

                                if member.id != members.last?.id {
                                    Divider().opacity(0.20).padding(.leading, 64)
                                }
                            }
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("创建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let clean = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let chosen = members.filter { selected.contains($0.id) }
                        let automaticName = chosen.map {
                            $0.id == "claude" ? assistantRemark : $0.displayName
                        }.joined(separator: "、")
                        var group = AIConversation(
                                id: UUID().uuidString,
                                name: clean.isEmpty ? (automaticName.isEmpty ? "新群聊" : automaticName) : clean,
                                signature: "群聊 · \(chosen.count + 1) 位成员",
                                symbol: "person.3.fill",
                                pinned: false,
                                kind: "group",
                                groupMemberIDs: chosen.map(\.id)
                            )
                        if let avatarImage { group.avatarFile = try? AIAvatarStore.save(avatarImage, id: group.id) }
                        onCreate(group)
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedAvatar) { _, item in
                Task { if let data = try? await item?.loadTransferable(type: Data.self) {
                    avatarImage = UIImage(data: data)
                } }
            }
        }
    }
}

/// Optional cross-conversation context: a configured AI sees its recent one-to-one
/// messages inside groups and its recent group messages inside the one-to-one chat.
private enum AICrossContext {
    static let limit = 30
    private static let characterLimit = 200

    static func key(_ id: String) -> String { "ai.\(id).crossContext" }
    static func isEnabled(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: key(id)) as? Bool ?? true
    }

    private static func history(_ id: String) -> [LocalAIMessage] {
        guard let data = UserDefaults.standard.data(forKey: "configuredAI.messages.\(id)"),
              let list = try? JSONDecoder().decode([LocalAIMessage].self, from: data) else { return [] }
        return list.filter { $0.withdrawn != true }
    }

    private static func conversations() -> [AIConversation] {
        guard let data = UserDefaults.standard.string(forKey: "aiConversationsJSON")?.data(using: .utf8),
              let all = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        return all
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > characterLimit ? String(flat.prefix(characterLimit)) + "…" : flat
    }

    private static func digest(_ lines: [String], header: String) -> LocalAIMessage? {
        guard !lines.isEmpty else { return nil }
        return LocalAIMessage(role: "user", text: header + "\n" + lines.joined(separator: "\n"), createdAt: .distantPast)
    }

    /// Recent one-to-one messages of a member, for a group request.
    static func privateDigest(memberID: String, name: String) -> LocalAIMessage? {
        guard isEnabled(memberID) else { return nil }
        let lines = history(memberID).suffix(limit).compactMap { message -> String? in
            let text = message.text.isEmpty ? (message.attachments?.isEmpty == false ? "[附件]" : "") : message.text
            guard !text.isEmpty else { return nil }
            return "（私聊）" + (message.role == "user" ? "用户：" : "\(name)：") + clip(text)
        }
        return digest(lines, header: "以下是你和用户最近的私聊记录，仅作背景参考，不要逐条复述：")
    }

    /// Recent messages of groups that include the member, for a one-to-one request.
    static func groupDigest(memberID: String, name: String) -> LocalAIMessage? {
        guard isEnabled(memberID) else { return nil }
        let all = conversations()
        let names = Dictionary(all.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var entries: [(date: Date, line: String)] = []
        for group in all where group.kind == "group" && (group.groupMemberIDs ?? []).contains(memberID) {
            for message in history(group.id).suffix(limit) {
                let text = message.text.isEmpty ? (message.attachments?.isEmpty == false ? "[附件]" : "") : message.text
                guard !text.isEmpty else { continue }
                let speaker: String
                if message.role == "user" { speaker = "用户" }
                else if message.authorID == memberID { speaker = name }
                else { speaker = names[message.authorID ?? ""] ?? "AI" }
                entries.append((message.createdAt, "（群聊：\(group.displayName)）\(speaker)：" + clip(text)))
            }
        }
        let lines = entries.sorted { $0.date < $1.date }.suffix(limit).map(\.line)
        return digest(Array(lines), header: "以下是你所在群聊最近的记录，仅作背景参考，不要逐条复述：")
    }
}

struct AICrossContextToggle: View {
    @AppStorage private var enabled: Bool

    init(conversationID: String) {
        _enabled = AppStorage(wrappedValue: true, AICrossContext.key(conversationID))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            Label("私聊和群聊记录互通", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 15))
        }
    }
}

/// Shorthand markup that device-local AI replies may contain (see localMarkupInstruction).
private enum LocalReplyMarkup {
    enum Item {
        case text(String, quote: String?)
        case pat(String)
        case react(String, target: String)
    }

    static func fields(_ line: String, tag: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[[\(tag)"), trimmed.hasSuffix("]]") else { return nil }
        let inner = trimmed.dropFirst(2 + tag.count).dropLast(2)
        guard inner.isEmpty || inner.hasPrefix("|") else { return nil }
        return inner.isEmpty ? [] : inner.dropFirst().components(separatedBy: "|")
    }

    static func items(_ part: String) -> [Item] {
        var result: [Item] = []
        var body: [String] = []
        var quote: String?
        for line in part.components(separatedBy: "\n") {
            if let values = fields(line, tag: "拍一拍") {
                result.append(.pat(values.first?.trimmingCharacters(in: .whitespaces) ?? ""))
            } else if let values = fields(line, tag: "贴表情"),
                      let emoji = values.first?.trimmingCharacters(in: .whitespaces), !emoji.isEmpty {
                result.append(.react(emoji, target: values.dropFirst().joined(separator: "|")))
            } else if let values = fields(line, tag: "引用"), body.isEmpty, quote == nil {
                quote = values.joined(separator: "|")
            } else {
                body.append(line)
            }
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result.append(.text(text, quote: quote)) }
        return result
    }
}

/// One-to-one device-local AI chat rendered by the shared ChatView.
private struct LocalAIChatScreen: View {
    @StateObject private var store: ChatStore

    init(conversation: AIConversation) {
        _store = StateObject(wrappedValue: ChatStore(localPeer: conversation))
    }

    var body: some View {
        ChatView(
            store: store,
            isPinned: .constant(false),
            groupMembers: [],
            onCreateGroup: { _ in },
            unreadStartMessageID: nil,
            onReachedLatest: {
                if let id = store.localPeer?.id { LocalAIInbox.markRead(id) }
            }
        )
    }
}

/// Quote card above the composer, shared by one-to-one and group chats.
struct ChatReplyComposerCard: View {
    let title: String
    let preview: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(Color.pink.opacity(0.62))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.pink.opacity(0.80))
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// "发送后合并展示" switch in the pending attachment tray, shared by one-to-one and group chats.
struct PendingCombineToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label("发送后合并展示", systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.pink.opacity(0.72) : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Ordered on-disk writes for device-local chats. Detached tasks could land out of order and
/// let an older snapshot overwrite newer replies; a serial queue keeps the last write last.
enum LocalAIMessageDisk {
    private static let queue = DispatchQueue(label: "app.bearden.local-ai-messages")

    static func save(_ messages: [LocalAIMessage], key: String) {
        queue.async {
            guard let data = try? JSONEncoder().encode(messages) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Appends straight to storage; used when a reply finishes after the chat screen closed.
    static func append(_ message: LocalAIMessage, key: String) {
        queue.async {
            var list: [LocalAIMessage] = []
            if let data = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode([LocalAIMessage].self, from: data) { list = saved }
            guard !list.contains(where: { $0.id == message.id }) else { return }
            list.append(message)
            if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .localAIMessageAppended, object: nil,
                                                userInfo: ["key": key, "message": message])
            }
        }
    }

    static func load(key: String) async -> [LocalAIMessage]? {
        await withCheckedContinuation { continuation in
            queue.async {
                let data = UserDefaults.standard.data(forKey: key)
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode([LocalAIMessage].self, from: $0) })
            }
        }
    }
}

final class ChatScreenLiveness { var visible = false }

extension Notification.Name {
    /// Posted on the main queue after a local chat message is appended to storage.
    static let localAIMessageAppended = Notification.Name("localAIMessageAppended")
}

struct AddedAIChatView: View {
    private enum ReactionPage {
        case emoji
        case stickers
    }

    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @State private var current: AIConversation
    @State private var messages: [LocalAIMessage] = []
    @State private var draftBuffer = ChatDraftBuffer()
    @State private var liveness = ChatScreenLiveness()
    @State private var combineAfterSending = false
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var showingDetails = false
    @State private var showingQuota = false
    @State private var showingReactions = false
    @State private var showingAttachments = false
    @State private var showingFilePicker = false
    @State private var showingCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachmentNames: [String] = []
    @State private var pendingFiles: [LocalChatAttachment] = []
    @State private var replyingTo: LocalAIMessage?
    @State private var reactionTarget: LocalReactionTarget?
    @State private var imageViewer: ViewerItem?
    @State private var showingSharedAccess = false
    @State private var showingMentionPicker = false
    @State private var connected = false
    @State private var unreadStartLocalMessageID: UUID?
    @State private var streamingRaw = ""
    @State private var currentActivity = ChatActivity()
    @State private var streamingIDs = (0..<5).map { _ in UUID() }
    @State private var stickerPhoto: PhotosPickerItem?
    @State private var reactionPage: ReactionPage = .emoji
    @State private var voicePressActive = false
    @StateObject private var voice = VoiceController()
    @StateObject private var locationProvider = OneShotLocationProvider()
    @StateObject private var stickers = StickerLibrary()
    @FocusState private var inputFocused: Bool
    @State private var initialScrollReady = false
    @State private var composerHeight: CGFloat = 57
    @State private var hasMeasuredComposer = false
    @State private var panelScrollTask: Task<Void, Never>?
    @State private var draftSaveTask: Task<Void, Never>?
    @AppStorage("bgVersion") private var bgVersion = 0
    @State private var bgImage: UIImage?
    private let bottomID = "configured-ai-bottom"
    private static let emojis = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "🥰",
        "😍", "😘", "😋", "😎", "🤩", "🥳", "😏",
        "🥺", "😭", "😤", "😡", "🤯", "😴", "🤔",
        "🙄", "😶", "🫠", "🤡", "👀", "👍", "🫶",
        "❤️", "🩷", "💜", "✨", "🎉", "🔥", "🌚",
        "🫪", "🐶", "🐱", "🐻", "🐰", "🎀", "💌"
    ]

    let onLeave: () -> Void

    init(conversation: AIConversation, onLeave: @escaping () -> Void = {}) {
        _current = State(initialValue: conversation)
        self.onLeave = onLeave
    }

    var body: some View { chatLifecycle }

    private var chatNavigation: some View {
        chatRoot
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatPeerTitle(name: current.displayName, typing: sending && current.kind != "group",
                    status: current.kind == "group"
                        ? "\((current.groupMemberIDs?.count ?? 0) + 1) 位成员"
                        : (errorMessage == nil ? "在线" : "连接异常"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingDetails = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chatSheets: some View {
        chatNavigation
        .sheet(isPresented: $showingSharedAccess) { SharedAIAccessView().presentationDetents([.medium]) }
        .sheet(isPresented: $showingMentionPicker) {
            NavigationStack {
                List {
                    Button {
                        if draftBuffer.text.hasSuffix("@") { draftBuffer.text.removeLast() }
                        draftBuffer.text += "@全体成员 "
                        showingMentionPicker = false
                        inputFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .modifier(Glass(shape: Circle()))
                            Text("@全体成员").foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(configuredGroupMembers()) { member in
                        Button {
                            let name = member.id == "claude"
                                ? (UserDefaults.standard.string(forKey: "assistantRemark") ?? member.name)
                                : member.displayName
                            if draftBuffer.text.hasSuffix("@") { draftBuffer.text.removeLast() }
                            draftBuffer.text += "@\(name) "
                            showingMentionPicker = false
                            inputFocused = true
                        } label: {
                            HStack(spacing: 12) {
                                AIConversationAvatar(conversation: member, size: 38)
                                Text(member.displayName).foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle("@ 群成员")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingMentionPicker = false }
                } }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $reactionTarget) { target in
            ReactionPickerView(emojis: Self.emojis) { emoji in
                changeLocalMessage(target.id) { msg in
                    var list = msg.reactions ?? []
                    if list.contains(emoji) { list.removeAll { $0 == emoji } } else { list.append(emoji) }
                    msg.reactions = list
                }
                reactionTarget = nil
            }.presentationDetents([.medium])
        }
        .fullScreenCover(item: $imageViewer) { item in ImageViewer(url: item.url) }
        .navigationDestination(isPresented: $showingDetails) {
            if current.kind == "group" {
                GroupChatDetailsView(
                    conversation: $current,
                    messages: $messages,
                    onUpdate: persistConversation,
                    onClear: {
                        messages.removeAll()
                        persistMessages()
                    },
                    onLeave: onLeave
                )
            } else {
                ConfiguredAIChatDetailsView(
                    conversation: $current,
                    messages: $messages,
                    onUpdate: persistConversation,
                    onClear: {
                        messages.removeAll()
                        persistMessages()
                    }
                )
            }
        }
        .sheet(isPresented: $showingQuota) {
            ProviderWalletView(conversation: current)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                do { pendingFiles.append(try LocalChatAttachment.saveImage(image)) }
                catch { errorMessage = error.localizedDescription }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    pendingFiles.append(try LocalChatAttachment.save(data, name: url.lastPathComponent))
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private var chatChanges: some View {
        chatSheets
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task {
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
                        pendingFiles.append(try LocalChatAttachment.saveImage(image))
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .onChange(of: stickerPhoto) { _, item in
            guard let item else { return }
            stickerPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run { stickers.add(data: data) }
            }
        }
    }

    private var chatLifecycle: some View {
        chatChanges
        .onReceive(NotificationCenter.default.publisher(for: .localAIMessageAppended)) { note in
            // Storage is the source of truth for member replies; whichever screen instance is
            // showing this chat picks the appended message up, so a reply that lands while the
            // screen was covered or re-created is not overwritten by a stale in-memory list.
            guard note.userInfo?["key"] as? String == storageKey(),
                  let message = note.userInfo?["message"] as? LocalAIMessage,
                  !messages.contains(where: { $0.id == message.id }) else { return }
            // Same insertion as the private Claude chat: the row lands in place without an
            // implicit move/slide animation and the list follows the bottom anchor.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { messages.append(message) }
        }
        .onDisappear {
            liveness.visible = false
            if UserDefaults.standard.string(forKey: LocalAIInbox.activeKey) == current.id {
                UserDefaults.standard.removeObject(forKey: LocalAIInbox.activeKey)
            }
            voice.stopTranscription()
            panelScrollTask?.cancel()
            draftSaveTask?.cancel()
            UserDefaults.standard.set(draftBuffer.text, forKey: "chatDraft.\(current.id)")
        }
        .onAppear {
            liveness.visible = true
            UserDefaults.standard.set(current.id, forKey: LocalAIInbox.activeKey)
            reloadAddedAIBackground()
            if draftBuffer.text.isEmpty {
                draftBuffer.text = UserDefaults.standard.string(forKey: "chatDraft.\(current.id)") ?? ""
            }
        }
        .onChange(of: draftBuffer.text) { _, text in
            if current.kind == "group" && text.hasSuffix("@") && !showingMentionPicker {
                showingMentionPicker = true
            }
            draftSaveTask?.cancel()
            draftSaveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(text, forKey: "chatDraft.\(current.id)")
            }
        }
        .onChange(of: bgVersion) { _, _ in reloadAddedAIBackground() }
        .alert("发送失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var chatRoot: some View {
        ZStack {
            addedAIChatBackground
            ScrollViewReader { proxy in chatLayout(proxy) }
        }
    }

    private func chatLayout(_ proxy: ScrollViewProxy) -> some View {
                ZStack(alignment: .bottom) {
                    addedAIHistory(proxy)

                    addedAIComposer
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ComposerHeightPreferenceKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                }
                .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
                    guard height > 0, abs(height - composerHeight) > 0.5 else { return }
                    composerHeight = height
                    if hasMeasuredComposer {
                        followAddedAIPanel(proxy)
                    } else {
                        hasMeasuredComposer = true
                    }
                }
                .onChange(of: messages.last?.id) { _, _ in
                    // Mirrors ChatView: follow the bottom anchor when any side's message arrives.
                    followAddedAIPanel(proxy)
                }
                .onChange(of: inputFocused) { _, focused in
                    if focused { followAddedAIPanel(proxy) }
                }
                .onChange(of: showingReactions) { _, _ in followAddedAIPanel(proxy) }
                .onChange(of: showingAttachments) { _, _ in followAddedAIPanel(proxy) }
                .task {
                    await loadMessages()
                    let unread = LocalAIInbox.entry(current.id).unreadCount
                    unreadStartLocalMessageID = unread > 0
                        ? messages.filter { $0.role == "assistant" }.suffix(unread).first?.id
                        : nil
                    LocalAIInbox.markRead(current.id)
                    await Task.yield()
                    await Task.yield()
                    jumpAddedAIWithoutAnimation(proxy)
                    initialScrollReady = true
                }

    }

    private func addedAIHistory(_ proxy: ScrollViewProxy) -> some View {
                    ScrollView {
                        LazyVStack(spacing: 13) {
                            if messages.isEmpty {
                                Text("现在可以和 \(current.name) 聊天了")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 22)
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                if index == 0 || !Calendar.current.isDate(message.createdAt, inSameDayAs: messages[index - 1].createdAt) {
                                    ChatDateDivider(date: message.createdAt)
                                }
                                if message.id == unreadStartLocalMessageID {
                                    ChatUnreadDivider()
                                }
                                localRow(message, proxy: proxy).id(message.id)
                            }
                            if sending && !currentActivity.isEmpty {
                                HStack {
                                    ChatActivityControls(activity: currentActivity, conversationID: current.id)
                                    Spacer(minLength: 48)
                                }.padding(.leading, 44)
                            }
                            ForEach(Array(MessageBubbleSplitter.localParts(streamingRaw).enumerated()),
                                    id: \.offset) { index, part in
                                LocalAIMessageBubble(
                                    message: LocalAIMessage(id: streamingIDs[index], role: "assistant", text: part),
                                    conversation: current
                                )
                            }
                            Color.clear.frame(height: composerHeight + 1).id(bottomID)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    }
                    .opacity(initialScrollReady ? 1 : 0)
                    .allowsHitTesting(initialScrollReady)
                    .chatInitialBottomAnchor()
                    .transparentTopScrollEdge()
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                            guard !ChatTextSelection.isSelectionInteraction(at: value.location) else { return }
                            NotificationCenter.default.post(name: .clearChatTextSelection, object: nil)
                        }
                    )
    }
    private func sendMessage(_ outgoing: String) {
        let typed = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !pendingFiles.isEmpty, !sending else { return }
        showingAttachments = false
        showingReactions = false
        dispatchUserMessage(typed)
    }

    private func sendAddedAISticker(_ sticker: LocalSticker) {
        guard !sending else { return }
        showingReactions = false
        dispatchUserMessage("[表情包]", stickerPath: sticker.url.path)
    }

    private func changeLocalMessage(_ id: UUID, edit: (inout LocalAIMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        edit(&messages[index])
        persistMessages()
    }

    @ViewBuilder
    private func localRow(_ message: LocalAIMessage, proxy: ScrollViewProxy) -> some View {
        if let wire = message.wireText, let pat = PatInfo.parse(wire) {
            PatSystemRow(
                info: pat,
                timestamp: message.createdAt.formatted(date: .omitted, time: .shortened),
                onEdit: {}
            )
        } else {
            localBubbleRow(message, proxy: proxy)
        }
    }

    private func patText(target: String) -> String {
        let suffix = (UserDefaults.standard.string(forKey: "patSuffix") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PatInfo.encode(actor: "我", target: target, suffix: suffix.isEmpty ? "" : " \(suffix)")
    }

    private func localBubbleRow(_ message: LocalAIMessage, proxy: ScrollViewProxy) -> some View {
        LocalAIMessageBubble(message: message, conversation: current,
            onReply: { replyingTo = message; inputFocused = true },
            onReact: { emoji in
                changeLocalMessage(message.id) { msg in
                    var list = msg.reactions ?? []
                    if list.contains(emoji) { list.removeAll { $0 == emoji } } else { list.append(emoji) }
                    msg.reactions = list
                }
            },
            onMore: { reactionTarget = LocalReactionTarget(id: message.id) },
            onRetract: { changeLocalMessage(message.id) { $0.withdrawn = true } },
            onJump: { id in withAnimation { proxy.scrollTo(id, anchor: .center) } },
            onPat: {
                let target = current.kind == "group" ? nameForGroupMember(message.authorID) : current.displayName
                dispatchUserMessage("我拍了拍「\(target)」", wireText: patText(target: target))
            },
            onImage: { url in imageViewer = ViewerItem(url: url) })
    }

    private var canCombinePendingFiles: Bool {
        pendingFiles.count >= 2 && pendingFiles.allSatisfy(\.isImage)
    }

    private func replySenderName(_ message: LocalAIMessage) -> String {
        if message.role == "user" { return "我" }
        return current.kind == "group" ? nameForGroupMember(message.authorID) : current.displayName
    }

    private func replyPreviewText(_ message: LocalAIMessage) -> String {
        if message.stickerPath != nil { return "[表情包]" }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(52)) }
        if let files = message.attachments, !files.isEmpty {
            return files.allSatisfy(\.isImage) ? "[图片]" : "[文件]"
        }
        return "[消息]"
    }

    private func dispatchUserMessage(_ value: String, stickerPath: String? = nil, wireText: String? = nil) {
        var message = LocalAIMessage(role: "user", text: value, stickerPath: stickerPath)
        message.wireText = wireText
        var files = pendingFiles
        // Without "发送后合并展示", several photos go out as separate bubbles like the
        // one-to-one chat; only the last bubble (with the text) starts the reply turn.
        if !combineAfterSending && files.count >= 2 && files.allSatisfy(\.isImage) {
            let leading = files.dropLast(value.isEmpty ? 1 : 0)
            for file in leading {
                var single = LocalAIMessage(role: "user", text: "")
                single.attachments = [file]
                messages.append(single)
            }
            files = value.isEmpty ? [files[files.count - 1]] : []
        }
        combineAfterSending = false
        message.attachments = files
        pendingFiles = []
        if let replyingTo {
            message.replyID = replyingTo.id
            message.replyPreview = replyPreviewText(replyingTo)
            message.replySender = replySenderName(replyingTo)
            self.replyingTo = nil
        }
        messages.append(message)
        LocalAIInbox.received(message, in: current.id)
        persistMessages()
        sending = true
        currentActivity = ChatActivity()
        let requestMessages = messages
        let live = liveness
        let diskKey = storageKey()
        Task {
            do {
                if current.kind == "group" {
                    let allMembers = configuredGroupMembers()
                    let mentioned = allMembers.filter { member in
                        let display = member.id == "claude"
                            ? (UserDefaults.standard.string(forKey: "assistantRemark") ?? member.name)
                            : member.displayName
                        return value.contains("@\(display)") || value.contains("@\(member.name)")
                    }
                    let mentionsAll = value.contains("@全体成员")
                    let members = (mentioned.isEmpty || mentionsAll) ? allMembers : mentioned
                    guard !members.isEmpty else { throw AIModelToolError.invalidResponse("群聊还没有成员，请在聊天详情里添加成员") }
                    // One bounded follow-up lets two AI members answer each other without
                    // turning a single user message into an unending agent loop.
                    let speakers = mentioned.isEmpty && !mentionsAll && members.count > 1
                        ? members + [members[0]] : members
                    var failedMembers: [String] = []
                    for member in speakers {
                        if failedMembers.contains(member.displayName) { continue }
                        // Read the stored history so each speaker sees the replies before it,
                        // even when this screen instance is no longer the one on display.
                        let history = await LocalAIMessageDisk.load(key: diskKey) ?? messages
                        let context: [LocalAIMessage] = history.filter { $0.withdrawn != true }.map { original in
                            var copy = original
                            if let preview = copy.replyPreview, copy.replyID != nil {
                                copy.text = "（引用 \(copy.replySender ?? "")：\(preview)）\n" + copy.text
                            }
                            if copy.role == "assistant", copy.authorID == member.id,
                               let list = copy.reactions, !list.isEmpty {
                                copy.text += "\n（对方给这条贴了 \(list.joined())）"
                            }
                            if copy.role == "assistant" && copy.authorID != member.id {
                                copy = LocalAIMessage(role: "user", text: "[\(nameForGroupMember(copy.authorID))]：\(copy.text)", createdAt: copy.createdAt)
                            }
                            return copy
                        }
                        do {
                            currentActivity = ChatActivity()
                            let reply: String
                            if member.id == "claude" {
                                reply = try await sendClaudeGroupReply(context: context)
                            } else {
                                var memberContext = context
                                if let digest = AICrossContext.privateDigest(memberID: member.id, name: member.displayName) {
                                    memberContext.insert(digest, at: 0)
                                }
                                let requestContext = memberContext
                                reply = try await MessageBubbleSplitter.$localMarkup.withValue(true) {
                                    try await AIProviderClient.send(messages: requestContext,
                                    model: member.model ?? "", baseURL: member.baseURL ?? "",
                                    apiKey: AIKeychain.load(account: member.credentialID),
                                    format: member.interfaceFormat ?? "OpenAI 兼容", nickname: member.name,
                                    authMode: member.authMode, credentialID: member.credentialID,
                                    conversation: member, groupID: current.id,
                                    onActivity: { activity in
                                        await MainActor.run { currentActivity = activity }
                                    })
                                }
                            }
                            connected = true
                            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                            var appended = 0
                            for part in MessageBubbleSplitter.localParts(reply) {
                                for item in LocalReplyMarkup.items(part) {
                                    var message: LocalAIMessage
                                    switch item {
                                    case .react(let emoji, let target):
                                        if let index = groupUserMessageIndex(matching: target) {
                                            messages[index].aiReaction = emoji
                                            persistMessages()
                                        }
                                        continue
                                    case .pat(let suffix):
                                        message = LocalAIMessage(role: "assistant", text: "（\(member.displayName)拍了拍「我」\(suffix)）")
                                        message.wireText = PatInfo.encode(actor: member.displayName, target: "我", suffix: suffix.isEmpty ? "" : " \(suffix)")
                                    case .text(let body, let quote):
                                        message = LocalAIMessage(role: "assistant", text: body)
                                        if let quote {
                                            let index = groupUserMessageIndex(matching: quote)
                                            message.replyID = index.map { messages[$0].id }
                                            message.replyPreview = index.map { String(messages[$0].text.prefix(80)) } ?? quote
                                            message.replySender = "我"
                                        }
                                    }
                                    message.authorID = member.id
                                    if appended == 0 && !currentActivity.isEmpty { message.activity = currentActivity }
                                    appended += 1
                                    LocalAIInbox.received(message, in: current.id)
                                    // Always append to storage; the visible screen merges it via notification.
                                    _ = live
                                    LocalAIMessageDisk.append(message, key: diskKey)
                                }
                            }
                        } catch {
                            // One unavailable member must not block the others from seeing the
                            // original text and attachments in this group turn.
                            if !failedMembers.contains(member.displayName) {
                                failedMembers.append(member.displayName)
                            }
                        }
                    }
                    if !failedMembers.isEmpty {
                        errorMessage = "\(failedMembers.joined(separator: "、")) 暂时未收到这条群消息，请稍后重试"
                    } else {
                        errorMessage = nil
                    }
                    sending = false
                    return
                }
                let reply = try await AIProviderClient.send(
                    messages: requestMessages,
                    model: current.model ?? "",
                    baseURL: current.baseURL ?? "",
                    apiKey: AIKeychain.load(account: current.credentialID),
                    format: current.interfaceFormat ?? "OpenAI 兼容",
                    nickname: current.name,
                    authMode: current.authMode,
                    credentialID: current.credentialID,
                    conversation: current,
                    onActivity: { activity in
                        await MainActor.run { currentActivity = activity }
                    },
                    onDelta: { delta in
                        await MainActor.run { streamingRaw += delta }
                    }
                )
                connected = true
                let wasStreamed = !streamingRaw.isEmpty
                streamingRaw = ""
                let parts = MessageBubbleSplitter.localParts(reply)
                for (index, part) in parts.enumerated() {
                    await MainActor.run {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            var message = LocalAIMessage(role: "assistant", text: part)
                            if index == 0 && !currentActivity.isEmpty { message.activity = currentActivity }
                            messages.append(message)
                            LocalAIInbox.received(message, in: current.id)
                        }
                        persistMessages()
                    }
                    if !wasStreamed && index < parts.count - 1 {
                        try? await Task.sleep(nanoseconds: 420_000_000)
                    }
                }
                await MainActor.run {
                    sending = false
                }
            } catch {
                await MainActor.run {
                    sending = false
                    streamingRaw = ""
                    connected = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func configuredGroupMembers() -> [AIConversation] {
        guard let data = conversationsJSON.data(using: .utf8),
              let all = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        let ids = current.groupMemberIDs ?? []
        return ids.compactMap { id in
            if let saved = all.first(where: { $0.id == id && $0.kind != "group" }) { return saved }
            if id == "claude" {
                return AIConversation(
                    id: "claude",
                    name: "助手",
                    signature: "随时在线，等你来聊天",
                    symbol: "ellipsis.curlybraces",
                    pinned: true
                )
            }
            return nil
        }
    }

    private func sendClaudeGroupReply(context: [LocalAIMessage]) async throws -> String {
        let history = context.suffix(18).map { message -> String in
            if message.role == "user" {
                // 别的 AI 的发言在 context 里被改写成「[名字]：……」的 user 消息，不是我说的
                if message.text.hasPrefix("["), let end = message.text.range(of: "]：") {
                    let name = String(message.text[message.text.index(after: message.text.startIndex)..<end.lowerBound])
                    return "\(name)：\(message.text[end.upperBound...])"
                }
                return "我：\(message.text)"
            }
            return "\(nameForGroupMember(message.authorID))：\(message.text)"
        }.joined(separator: "\n")
        let prompt = """
        你现在正在熊窝的群聊「\(current.name)」里。请结合下面的群聊记录，以你自己的身份回复最后一条消息；只输出要发进群里的内容，不要解释规则。
        \(MessageBubbleSplitter.localMarkupInstruction)

        \(history)
        """

        // A group turn must never go through the direct-message mailbox.
        // The server must route this room independently before the assistant can answer.
        guard let base = API.base else {
            throw AIModelToolError.invalidResponse("未设置服务器地址，群聊回复无法发送")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/groups/reply"))
        request.httpMethod = "POST"
        request.timeoutInterval = 95
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = BeardenAuth.bearer {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        } else {
            let groupToken = AIKeychain.load(account: "claude-group-reply")
            if !groupToken.isEmpty {
                request.setValue("Bearer \(groupToken)", forHTTPHeaderField: "Authorization")
            }
        }
        var images: [String] = []
        // Only the newest user turn's images are sent; older photos are already in the
        // member's session and resending them inflates every request.
        // Photos sent as separate bubbles belong to the same turn, so collect the trailing run.
        let isHumanTurn: (LocalAIMessage) -> Bool = { $0.role == "user" && !($0.text.hasPrefix("[") && $0.text.contains("]：")) }
        var turn: [LocalAIMessage] = []
        if let lastHuman = context.lastIndex(where: isHumanTurn) {
            var index = lastHuman
            while index >= 0, isHumanTurn(context[index]) {
                turn.insert(context[index], at: 0)
                index -= 1
            }
        }
        for latest in turn where latest.attachments?.contains(where: \.isImage) == true || latest.stickerPath != nil {
            for file in (latest.attachments ?? []).filter(\.isImage) where images.count < 6 {
                if let data = try? Data(contentsOf: file.url) {
                    images.append("data:\(file.mime);base64,\(data.base64EncodedString())")
                }
            }
            if images.count < 6, let stickerURL = latest.stickerURL,
               let data = try? Data(contentsOf: stickerURL) {
                images.append("data:image/jpeg;base64,\(data.base64EncodedString())")
            }
        }
        let requestID = UUID().uuidString
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "group_id": current.id,
            "member_id": "claude",
            "request_id": requestID,
            "prompt": prompt,
            "images": images
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIModelToolError.invalidResponse("助手的群聊独立通道尚未接通，消息没有发送到单聊")
        }
        let result = try JSONDecoder().decode(ClaudeGroupReply.self, from: data)
        // The member chose not to speak this turn: not an error, nothing to show.
        if result.noReply == true, result.groupID == current.id, result.requestID == requestID { return "" }
        guard result.groupID == current.id, result.memberID == "claude", result.requestID == requestID,
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIModelToolError.invalidResponse("助手群聊回复校验失败")
        }
        return result.text
    }

    private struct ClaudeGroupReply: Decodable {
        let groupID: String
        let memberID: String
        let requestID: String
        let text: String
        let noReply: Bool?

        enum CodingKeys: String, CodingKey {
            case groupID = "group_id"
            case memberID = "member_id"
            case requestID = "request_id"
            case text
            case noReply = "no_reply"
        }
    }

    private func groupUserMessageIndex(matching snippet: String) -> Int? {
        let key = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = messages.indices.reversed().filter {
            messages[$0].role == "user" && messages[$0].withdrawn != true
        }
        guard !key.isEmpty else { return candidates.first }
        return candidates.first { messages[$0].text.hasPrefix(key) }
            ?? candidates.first { messages[$0].text.contains(key) }
    }

    private func nameForGroupMember(_ id: String?) -> String {
        configuredGroupMembers().first(where: { $0.id == id })?.name ?? "AI"
    }

    private var addedAIComposer: some View {
        VStack(spacing: 8) {
            if let replyingTo {
                ChatReplyComposerCard(
                    title: "回复 \(replySenderName(replyingTo))",
                    preview: replyPreviewText(replyingTo)
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil }
                }
            }
            if !pendingFiles.isEmpty {
                VStack(spacing: 8) {
                    HStack {
                        Text("待发送 \(pendingFiles.count)")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if canCombinePendingFiles {
                            PendingCombineToggle(isOn: $combineAfterSending)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingFiles) { file in
                                PendingAttachmentCard(item: PendingAttachment(
                                    data: Data(),
                                    name: file.name,
                                    preview: file.isImage ? UIImage(contentsOfFile: file.url.path) : nil
                                )) {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        pendingFiles.removeAll { $0.id == file.id }
                                        if !canCombinePendingFiles { combineAfterSending = false }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(10)
                .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
            }

            if showingAttachments {
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        showingAttachments = false
                        showingCamera = true
                    } label: {
                        ComposerMenuRow(title: "相机", systemImage: "camera.fill", tint: .gray)
                    }
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 9, matching: .images) {
                        ComposerMenuRow(title: "照片", systemImage: "photo.on.rectangle", tint: .orange)
                    }
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showingAttachments = false
                            showingReactions = true
                        }
                    } label: {
                        ComposerMenuRow(title: "表情包", systemImage: "face.smiling.inverse", tint: .cyan)
                    }
                    Button {
                        showingAttachments = false
                        showingFilePicker = true
                    } label: {
                        ComposerMenuRow(title: "文件", systemImage: "folder.fill", tint: .blue)
                    }
                    Button {
                        showingAttachments = false
                        locationProvider.request { location in
                            pendingAttachmentNames.append(String(
                                format: "位置 %.6f, %.6f",
                                location.coordinate.latitude,
                                location.coordinate.longitude
                            ))
                        }
                    } label: {
                        ComposerMenuRow(title: locationProvider.isLocating ? "定位中" : "位置", systemImage: "location.fill", tint: .green)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .frame(width: 230, alignment: .leading)
                .modifier(NativeGlass(shape: RoundedRectangle(cornerRadius: 30, style: .continuous)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }

            ChatInputRow(
                buffer: draftBuffer,
                inputFocused: $inputFocused,
                isRecording: voice.isRecording,
                isTranscribing: voice.isTranscribing,
                uploading: sending,
                hasAttachments: !pendingFiles.isEmpty,
                menuOpen: showingAttachments || showingReactions,
                recordingStartedAt: nil,
                recordedVoice: nil,
                previewPlaying: false,
                onVoiceTap: toggleAddedAITranscription,
                onHoldStart: beginAddedAIVoicePress,
                onHoldEnd: endAddedAIVoicePress,
                onTogglePlus: {
                    inputFocused = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        if showingAttachments || showingReactions {
                            showingAttachments = false
                            showingReactions = false
                        } else {
                            showingAttachments = true
                        }
                    }
                },
                onDiscardVoice: {},
                onPlayVoice: {},
                onSendVoice: {},
                onSend: sendMessage
            )

            if showingReactions {
                VStack(spacing: 10) {
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 38, height: 4)
                    ScrollView {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                                spacing: 10
                            ) {
                                PhotosPicker(selection: $stickerPhoto, matching: .images) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 24, weight: .medium))
                                        Text("添加")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                .buttonStyle(.plain)

                                ForEach(stickers.items) { sticker in
                                    Button {
                                        sendAddedAISticker(sticker)
                                    } label: {
                                        StickerThumbnail(url: sticker.url)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                    }
                    .frame(height: 240)
                }
                .padding(12)
                .modifier(NativeGlass(shape: RoundedRectangle(cornerRadius: 27, style: .continuous)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard (showingAttachments || showingReactions),
                          value.translation.height > 48,
                          value.translation.height > abs(value.translation.width) * 1.2 else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        showingAttachments = false
                        showingReactions = false
                    }
                }
        )
    }

    private func addedAIReactionTab(
        _ title: String,
        systemImage: String,
        page: ReactionPage
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { reactionPage = page }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    reactionPage == page ? Color.white.opacity(0.25) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func toggleAddedAITranscription() {
        if voice.isTranscribing {
            voice.stopTranscription()
            return
        }
        let prefix = draftBuffer.text
        Task {
            do {
                try await voice.startTranscription { transcript in
                    draftBuffer.text = prefix + transcript
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func beginAddedAIVoicePress() {
        voicePressActive = true
        Task {
            do {
                try await voice.startRecording { voicePressActive }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func endAddedAIVoicePress() {
        voicePressActive = false
        guard let url = voice.finishRecording() else { return }
        do {
            pendingFiles.append(try LocalChatAttachment.save(Data(contentsOf: url), name: "语音.m4a", mime: "audio/mp4"))
        } catch { errorMessage = error.localizedDescription }
    }

    private var addedAIChatBackground: some View {
        Group {
            if let bg = bgImage {
                GeometryReader { geometry in
                    Image(uiImage: bg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .overlay(Color.black.opacity(0.025))
                .ignoresSafeArea()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.90, blue: 0.95),
                            Color(red: 0.91, green: 0.88, blue: 1.00),
                            Color(red: 1.00, green: 0.96, blue: 0.90)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(Color.pink.opacity(0.26))
                        .frame(width: 260, height: 260)
                        .blur(radius: 45)
                        .offset(x: 130, y: -250)
                    Circle()
                        .fill(Color.purple.opacity(0.18))
                        .frame(width: 300, height: 300)
                        .blur(radius: 55)
                        .offset(x: -150, y: 260)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func reloadAddedAIBackground() {
        bgImage = bgVersion > 0 ? UIImage(contentsOfFile: SettingsView.bgPath.path) : nil
    }

    private func jumpAddedAIWithoutAnimation(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    private func followAddedAIPanel(_ proxy: ScrollViewProxy) {
        panelScrollTask?.cancel()
        panelScrollTask = Task { @MainActor in
            // 面板收起动画结束后再补一次，避免记录停在被顶上去的位置
            for delay in [UInt64(0), 220, 450] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                guard !Task.isCancelled else { return }
                jumpAddedAIWithoutAnimation(proxy)
            }
        }
    }

    private func storageKey() -> String { "configuredAI.messages.\(current.id)" }

    private func loadMessages() async {
        if let saved = await LocalAIMessageDisk.load(key: storageKey()) { messages = saved }
    }

    private func persistMessages() {
        LocalAIMessageDisk.save(messages, key: storageKey())
    }

    private func persistConversation(_ updated: AIConversation) {
        guard let data = conversationsJSON.data(using: .utf8),
              var conversations = try? JSONDecoder().decode([AIConversation].self, from: data),
              let index = conversations.firstIndex(where: { $0.id == updated.id }) else { return }
        conversations[index] = updated
        guard let encoded = try? JSONEncoder().encode(conversations),
              let string = String(data: encoded, encoding: .utf8) else { return }
        conversationsJSON = string
    }
}


private struct GroupMemberPicker: View {
    let title: String
    let members: [AIConversation]
    let onConfirm: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(members) { member in
                Button {
                    if !selected.insert(member.id).inserted { selected.remove(member.id) }
                } label: {
                    HStack(spacing: 12) {
                        AIConversationAvatar(conversation: member, size: 40)
                        Text(member.id == "claude" ? assistantRemark : member.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selected.contains(member.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(member.id) ? Color.pink : Color.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AppBackdrop())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        onConfirm(Array(selected))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

private struct GroupChatDetailsView: View {
    @Binding var conversation: AIConversation
    @Binding var messages: [LocalAIMessage]
    let onUpdate: (AIConversation) -> Void
    let onClear: () -> Void
    let onLeave: () -> Void

    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @Environment(\.dismiss) private var dismiss
    @State private var contentReady = false
    @State private var showingAddMembers = false
    @State private var showingRemoveMembers = false
    @State private var showingSearch = false
    @State private var showingBackground = false
    @State private var showingClearConfirmation = false
    @State private var showingLeaveConfirmation = false
    @State private var showingNameEditor = false
    @State private var showingNicknameEditor = false
    @State private var showingGroupTokenEditor = false
    @State private var nameDraft = ""
    @State private var nicknameDraft = ""
    @State private var groupTokenDraft = ""
    @State private var hasGroupToken = false
    @State private var myNickname = ""
    @State private var isMuted = false
    @State private var isSaved = false
    @State private var showsNames = true
    @State private var avatarPicker: PhotosPickerItem?
    @State private var avatarError: String?

    private var prefix: String { "group.\(conversation.id)" }
    private var allContacts: [AIConversation] {
        guard let data = conversationsJSON.data(using: .utf8),
              let all = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        var contacts = all.filter { $0.kind != "group" }
        if !contacts.contains(where: { $0.id == "claude" }) {
            contacts.insert(
                AIConversation(
                    id: "claude",
                    name: "助手",
                    signature: "随时在线，等你来聊天",
                    symbol: "ellipsis.curlybraces",
                    pinned: true
                ),
                at: 0
            )
        }
        return contacts
    }
    private var members: [AIConversation] {
        (conversation.groupMemberIDs ?? []).compactMap { id in allContacts.first { $0.id == id } }
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View { groupAlerts }

    private var groupContent: some View {
        ZStack {
            AppBackdrop()
            if contentReady {
                ScrollView {
                    VStack(spacing: 18) {
                        heroCard
                        memberGrid
                        section {
                            row("群聊名称", icon: "person.3.fill", value: conversation.name) {
                                nameDraft = conversation.name
                                showingNameEditor = true
                            }
                        }
                        section {
                            row("查找聊天内容", icon: "magnifyingglass") { showingSearch = true }
                        }
                        section {
                            ChatActivityPreference(conversationID: conversation.id)
                            Divider().opacity(0.24)
                            Toggle(isOn: $isMuted) {
                                Label("消息免打扰", systemImage: "bell.slash")
                            }
                            .padding(.vertical, 17)
                            Divider().opacity(0.24)
                            Toggle(isOn: Binding(
                                get: { conversation.pinned },
                                set: { conversation.pinned = $0; onUpdate(conversation) }
                            )) {
                                Label("置顶聊天", systemImage: "pin")
                            }
                            .padding(.vertical, 17)
                            Divider().opacity(0.24)
                            Toggle(isOn: $isSaved) {
                                Label("保存到通讯录", systemImage: "person.crop.circle.badge.checkmark")
                            }
                            .padding(.vertical, 17)
                        }
                        section {
                            row("我在本群的昵称", icon: "person.text.rectangle", value: myNickname.isEmpty ? "未设置" : myNickname) {
                                nicknameDraft = myNickname
                                showingNicknameEditor = true
                            }
                            Divider().opacity(0.24)
                            Toggle(isOn: $showsNames) {
                                Label("显示群成员昵称", systemImage: "text.bubble")
                            }
                            .padding(.vertical, 17)
                        }
                        section {
                            row("设置当前聊天背景", icon: "photo.on.rectangle") { showingBackground = true }
                        }
                        section {
                            row("清空聊天记录", icon: "trash") { showingClearConfirmation = true }
                        }
                        Button(role: .destructive) { showingLeaveConfirmation = true } label: {
                            Text("删除并退出群聊")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 17)
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private var heroCard: some View {
        VStack(spacing: 12) {
            AIConversationAvatar(conversation: conversation, size: 86)
            VStack(spacing: 4) {
                Text(conversation.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("\(members.count + 1) 位成员")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $avatarPicker, matching: .images) {
                Label("更换群头像", systemImage: "camera")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .modifier(Glass(shape: Capsule()))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 25)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 27, style: .continuous)))
    }

    private var groupNavigation: some View {
        groupContent
        .navigationTitle("聊天信息（\(members.count + 1)）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard !contentReady else { return }
            isMuted = UserDefaults.standard.bool(forKey: "\(prefix).muted")
            isSaved = UserDefaults.standard.bool(forKey: "\(prefix).saved")
            showsNames = UserDefaults.standard.object(forKey: "\(prefix).showNames") as? Bool ?? true
            myNickname = UserDefaults.standard.string(forKey: "\(prefix).nickname") ?? ""
            hasGroupToken = !AIKeychain.load(account: "claude-group-reply").isEmpty
            try? await Task.sleep(for: .milliseconds(180))
            contentReady = true
        }
    }

    private var groupState: some View {
        groupNavigation
        .onChange(of: isMuted) { _, value in UserDefaults.standard.set(value, forKey: "\(prefix).muted") }
        .onChange(of: isSaved) { _, value in
            UserDefaults.standard.set(value, forKey: "\(prefix).saved")
            UserDefaults.standard.set(
                UserDefaults.standard.integer(forKey: "groupDirectoryVersion") + 1,
                forKey: "groupDirectoryVersion"
            )
        }
        .onChange(of: showsNames) { _, value in UserDefaults.standard.set(value, forKey: "\(prefix).showNames") }
        .onChange(of: avatarPicker) { _, item in
            Task {
                guard let item else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { throw AlbumError.server("头像无法读取") }
                    conversation.avatarFile = try AIAvatarStore.save(image, id: conversation.id)
                    onUpdate(conversation)
                } catch { avatarError = error.localizedDescription }
                avatarPicker = nil
            }
        }
    }

    private var groupSheets: some View {
        groupState
        .sheet(isPresented: $showingAddMembers) {
            GroupMemberPicker(title: "添加群成员",
                              members: allContacts.filter { !(conversation.groupMemberIDs ?? []).contains($0.id) }) { ids in
                conversation.groupMemberIDs = (conversation.groupMemberIDs ?? []) + ids
                onUpdate(conversation)
            }
        }
        .sheet(isPresented: $showingRemoveMembers) {
            GroupMemberPicker(title: "移除群成员", members: members) { ids in
                conversation.groupMemberIDs?.removeAll { ids.contains($0) }
                onUpdate(conversation)
            }
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack { LocalAIChatSearchView(messages: messages, conversation: conversation) }
        }
        .sheet(isPresented: $showingBackground) {
            ChatBackgroundChoice().presentationDetents([.medium])
        }
    }

    private var groupAlerts: some View {
        groupSheets
        .alert("群聊名称", isPresented: $showingNameEditor) {
            TextField("群聊名称", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                conversation.name = name
                onUpdate(conversation)
            }
        }
        .alert("我在本群的昵称", isPresented: $showingNicknameEditor) {
            TextField("昵称", text: $nicknameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                myNickname = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.set(myNickname, forKey: "\(prefix).nickname")
            }
        }
        .alert("助手群聊密钥", isPresented: $showingGroupTokenEditor) {
            SecureField("粘贴 Bearer 密钥", text: $groupTokenDraft)
            Button("取消", role: .cancel) { groupTokenDraft = "" }
            Button("保存") {
                let value = groupTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                groupTokenDraft = ""
                guard !value.isEmpty else { return }
                do {
                    try AIKeychain.save(value.replacingOccurrences(of: "Bearer ", with: ""), account: "claude-group-reply")
                    hasGroupToken = true
                } catch { avatarError = "密钥保存失败：\(error.localizedDescription)" }
            }
        }
        .alert("群聊头像", isPresented: Binding(get: { avatarError != nil }, set: { if !$0 { avatarError = nil } })) {
            Button("好") { avatarError = nil }
        } message: { Text(avatarError ?? "") }
        .confirmationDialog("清空此设备上的群聊记录？", isPresented: $showingClearConfirmation) {
            Button("清空", role: .destructive) { onClear() }
        }
        .confirmationDialog("删除并退出这个群聊？", isPresented: $showingLeaveConfirmation) {
            Button("删除并退出", role: .destructive) { dismiss(); onLeave() }
        }
    }

    private var memberGrid: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("群成员", systemImage: "person.3.fill")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(members.count + 1)人")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                memberTile(name: "我", symbol: "person.crop.circle.fill") {
                    MyAvatar(size: 56)
                }
                ForEach(members) { member in
                    memberTile(name: member.id == "claude" ? assistantRemark : member.displayName, symbol: member.symbol) {
                        AIConversationAvatar(conversation: member, size: 56)
                    }
                }
                Button { showingAddMembers = true } label: {
                    memberTile(name: "添加", symbol: "plus") {
                        Image(systemName: "plus")
                            .font(.system(size: 22))
                            .frame(width: 56, height: 56)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 17, style: .continuous)))
                    }
                }.buttonStyle(.plain)
                if !members.isEmpty {
                    Button { showingRemoveMembers = true } label: {
                        memberTile(name: "移除", symbol: "minus") {
                            Image(systemName: "minus")
                                .font(.system(size: 22))
                                .frame(width: 56, height: 56)
                                .modifier(Glass(shape: RoundedRectangle(cornerRadius: 17, style: .continuous)))
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 27, style: .continuous)))
    }

    private func memberTile<Content: View>(name: String, symbol: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            content()
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(name)
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
    }

    private func row(_ title: String, icon: String, value: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 23)
                Text(title)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 16))
            .padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConfiguredAIChatDetailsView: View {
    @Binding var conversation: AIConversation
    @Binding var messages: [LocalAIMessage]
    let onUpdate: (AIConversation) -> Void
    let onClear: () -> Void

    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @Environment(\.dismiss) private var dismiss
    @State private var contentReady = false
    @State private var isMuted = false
    @State private var reminderEnabled = false
    @State private var reminderDate = Date.now.addingTimeInterval(3600)
    @State private var showingSearch = false
    @State private var showingGroup = false
    @State private var showingBackground = false
    @State private var showingClearConfirmation = false
    @State private var showingRemarkEditor = false
    @State private var remarkDraft = ""
    @State private var notificationError: String?
    @State private var groupAvatarPicker: PhotosPickerItem?
    @State private var groupAvatarError: String?

    private var keyPrefix: String { "configuredAI.\(conversation.id)" }

    var body: some View {
        ZStack {
            AppBackdrop()
            if contentReady {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 10) {
                            AIConversationAvatar(conversation: conversation, size: 82)
                            if conversation.kind == "group" {
                                PhotosPicker(selection: $groupAvatarPicker, matching: .images) {
                                    Label("更换群聊头像", systemImage: "camera")
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 16).padding(.vertical, 7)
                                        .modifier(Glass(shape: Capsule()))
                                }.buttonStyle(.plain)
                            }
                            Button {
                                remarkDraft = conversation.displayName
                                showingRemarkEditor = true
                            } label: {
                                HStack(spacing: 5) {
                                    Text(conversation.displayName)
                                        .font(.system(size: 14))
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)

                            Button { showingGroup = true } label: {
                                Label("添加成员", systemImage: "person.badge.plus")
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 9)
                                    .modifier(Glass(shape: Capsule()))
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))

                        detailButton("查找聊天内容", icon: "magnifyingglass") { showingSearch = true }
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))

                        VStack(spacing: 0) {
                            ChatActivityPreference(conversationID: conversation.id)
                            Divider().opacity(0.24)
                            AICrossContextToggle(conversationID: conversation.id)
                            Divider().opacity(0.24)
                            Toggle(isOn: $isMuted) {
                                Label("消息免打扰", systemImage: "bell.slash")
                            }
                            .padding(.vertical, 14)
                            Divider().opacity(0.24)
                            Toggle(isOn: Binding(
                                get: { conversation.pinned },
                                set: { value in
                                    conversation.pinned = value
                                    onUpdate(conversation)
                                }
                            )) {
                                Label("置顶聊天", systemImage: "pin")
                            }
                            .padding(.vertical, 14)
                            Divider().opacity(0.24)
                            Toggle(isOn: $reminderEnabled) {
                                Label("提醒", systemImage: "bell.badge")
                            }
                            .padding(.vertical, 14)
                            if reminderEnabled {
                                DatePicker("提醒时间", selection: $reminderDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.compact)
                                    .padding(.vertical, 10)
                            }
                        }
                        .padding(.horizontal, 17)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))

                        detailButton("设置当前聊天背景", icon: "photo.on.rectangle") {
                            showingBackground = true
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))

                        detailButton("清空聊天记录", icon: "trash") {
                            showingClearConfirmation = true
                        }
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard !contentReady else { return }
            isMuted = UserDefaults.standard.bool(forKey: "\(keyPrefix).muted")
            reminderEnabled = UserDefaults.standard.bool(forKey: "\(keyPrefix).reminder")
            // Let the navigation animation finish before mounting several live glass surfaces.
            try? await Task.sleep(for: .milliseconds(240))
            contentReady = true
        }
        .onChange(of: isMuted) { _, value in
            UserDefaults.standard.set(value, forKey: "\(keyPrefix).muted")
        }
        .onChange(of: reminderEnabled) { _, value in
            UserDefaults.standard.set(value, forKey: "\(keyPrefix).reminder")
            scheduleReminder(value)
        }
        .onChange(of: reminderDate) { _, _ in
            if reminderEnabled { scheduleReminder(true) }
        }
        .onChange(of: groupAvatarPicker) { _, item in
            Task {
                guard let item else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { throw AlbumError.server("头像无法读取") }
                    conversation.avatarFile = try AIAvatarStore.save(image, id: conversation.id)
                    onUpdate(conversation)
                } catch { groupAvatarError = error.localizedDescription }
                groupAvatarPicker = nil
            }
        }
        .alert("群聊头像", isPresented: Binding(get: { groupAvatarError != nil }, set: { if !$0 { groupAvatarError = nil } })) {
            Button("好") { groupAvatarError = nil }
        } message: { Text(groupAvatarError ?? "") }
        .sheet(isPresented: $showingSearch) {
            NavigationStack { LocalAIChatSearchView(messages: messages, conversation: conversation) }
        }
        .sheet(isPresented: $showingGroup) {
            CreateGroupView(members: availableMembers) { group in
                appendConversation(group)
                showingGroup = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingBackground) {
            ChatBackgroundChoice().presentationDetents([.medium])
        }
        .confirmationDialog("清空此设备上的聊天记录？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清空", role: .destructive) { onClear() }
        } message: {
            Text("只清空这位联系人的本机聊天记录。")
        }
        .alert("修改备注", isPresented: $showingRemarkEditor) {
            TextField("输入备注", text: $remarkDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                conversation.remark = remarkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                onUpdate(conversation)
            }
        } message: {
            Text("备注只在你的设备上显示，AI 看不见。")
        }
        .alert("提醒", isPresented: Binding(
            get: { notificationError != nil },
            set: { if !$0 { notificationError = nil } }
        )) {
            Button("好") { notificationError = nil }
        } message: { Text(notificationError ?? "") }
    }

    private var availableMembers: [AIConversation] {
        guard let data = conversationsJSON.data(using: .utf8),
              let saved = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [conversation] }
        return saved.filter { $0.kind != "group" }
    }

    private func detailButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 23)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 16))
            .padding(.horizontal, 17)
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appendConversation(_ value: AIConversation) {
        guard let data = conversationsJSON.data(using: .utf8),
              var saved = try? JSONDecoder().decode([AIConversation].self, from: data) else { return }
        saved.append(value)
        guard let encoded = try? JSONEncoder().encode(saved),
              let string = String(data: encoded, encoding: .utf8) else { return }
        conversationsJSON = string
    }

    private func scheduleReminder(_ enabled: Bool) {
        let identifier = "configured-ai-reminder-\(conversation.id)"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    await MainActor.run {
                        reminderEnabled = false
                        notificationError = "请在系统设置中允许熊窝发送通知。"
                    }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = conversation.displayName
                content.body = "你设置的聊天提醒到了"
                content.sound = .default
                let interval = max(1, reminderDate.timeIntervalSinceNow)
                try await center.add(UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                ))
            } catch {
                await MainActor.run { notificationError = "提醒设置失败：\(error.localizedDescription)" }
            }
        }
    }
}

private struct LocalAIChatSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("myNickname") private var myNickname = "我"
    let messages: [LocalAIMessage]
    let conversation: AIConversation
    @State private var query = ""

    private var results: [LocalAIMessage] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? messages : messages.filter { $0.text.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            List(results) { message in
                ChatSearchResultRow(
                    sender: message.role == "user" ? (myNickname.isEmpty ? "我" : myNickname) : conversation.displayName,
                    text: message.text.isEmpty && message.stickerPath != nil ? "[表情]" : message.text,
                    date: message.createdAt
                ) {
                    if message.role == "user" {
                        MyAvatar(size: 44)
                    } else {
                        AIConversationAvatar(conversation: conversation, size: 44)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.opacity(0.64))
            .searchable(text: $query, prompt: "查找聊天内容")
        }
        .navigationTitle("查找聊天内容")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        }
    }
}

// ===== 聊天页 =====
private struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 62
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


private struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let preview: UIImage?

    var isImage: Bool { preview != nil }
}

private struct MediaGroupInfo {
    static let prefix = "[[bear-album|"

    // Transport grouping is independent of the user's visual album choice.
    static func batchCaption(_ text: String) -> String {
        guard text.hasPrefix("[[bear-batch|"), let end = text.range(of: "]]") else { return text }
        let header = text[text.index(text.startIndex, offsetBy: 13)..<end.lowerBound]
            .split(separator: "|", omittingEmptySubsequences: false)
        guard header.count == 3, !header[0].isEmpty,
              let index = Int(header[1]), let count = Int(header[2]),
              count > 1, index >= 0, index < count else { return text }
        var caption = String(text[end.upperBound...])
        if caption.first == "\n" { caption.removeFirst() }
        return caption
    }

    let id: String
    let index: Int
    let count: Int
    let caption: String

    static func encode(id: String, index: Int, count: Int, caption: String) -> String {
        let header = "\(prefix)\(id)|\(index)|\(count)]]"
        return caption.isEmpty ? header : header + "\n" + caption
    }

    static func parse(_ text: String) -> MediaGroupInfo? {
        guard text.hasPrefix(prefix), let end = text.range(of: "]]") else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let header = text[start..<end.lowerBound].split(separator: "|", omittingEmptySubsequences: false)
        guard header.count == 3,
              let index = Int(header[1]),
              let count = Int(header[2]) else { return nil }
        var caption = String(text[end.upperBound...])
        if caption.first == "\n" { caption.removeFirst() }
        return MediaGroupInfo(id: String(header[0]), index: index, count: count, caption: caption)
    }
}

private struct PendingAttachmentCard: View {
    let item: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = item.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 24))
                        Text(item.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 104, height: 68)
                    .modifier(BubbleGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)))
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

private struct AlbumCoverTile: View {
    let name: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Color.white.opacity(0.18)
                    .overlay(Image(systemName: "photo").font(.system(size: 34)))
            } else {
                Color.white.opacity(0.18)
                    .overlay(ProgressView())
            }
        }
        .frame(width: 190, height: 238)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: name) { await load() }
    }

    @MainActor
    private func load() async {
        if let data = await ChatImageCache.data(for: name), let cached = UIImage(data: data) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: API.fileURL(name))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            ChatImageCache.store(data, name: name)
            image = decoded
        } catch {
            failed = true
        }
    }
}

private struct MediaAlbumBubble: View {
    let messages: [Msg]
    let reactions: [String]
    let onImage: (URL) -> Void
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onRetract: () -> Void
    let onDelete: () -> Void
    /// 「选择文字」: enters system text selection for the given selection key.
    let onSelectText: (String) -> Void
    let onJumpToReply: (Int) -> Void
    let onAvatarDoubleTap: () -> Void
    let onExpansionChange: (Bool) -> Void
    var canRetract = false
    @State private var selectedIndex = 0
    @State private var expanded = false
    @Environment(\.chatPeerConversation) private var peer

    private var selectionKey: String { "album:\(messages.first?.id ?? 0)" }

    private var favoriteAction: (() async throws -> Void)? {
        guard let first = messages.first else { return nil }
        let peerName = peer?.displayName
        return { try await FavoriteStore.shared.add(message: first, peerName: peerName) }
    }

    private var messageMenu: MessageContextMenu {
        MessageContextMenu(
            copyText: displayedCaption,
            selectionKey: selectionKey,
            onReply: onReply,
            onReact: onReact,
            onMoreReactions: onMoreReactions,
            onSelectText: onSelectText,
            onFavorite: favoriteAction,
            onRetract: canRetract ? onRetract : nil,
            onDelete: onDelete
        )
    }

    private var mine: Bool { messages.first?.from == "me" }
    private var caption: String {
        guard let first = messages.first else { return "" }
        return MediaGroupInfo.parse(first.text)?.caption ?? ""
    }
    private var reply: ReplyInfo? { ReplyInfo.parse(caption) }
    private var displayedCaption: String { reply?.body ?? caption }
    private var files: [String] { messages.compactMap(\.file) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine {
                Spacer(minLength: 0)
            } else {
                Avatar(isMe: false)
                    .onTapGesture(count: 2, perform: onAvatarDoubleTap)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
                if !files.isEmpty {
                    if expanded {
                        VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
                            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                                ChatImageView(name: file, onOpen: { onImage(API.fileURL(file)) })
                            }
                            expandButton
                        }
                        .transition(.opacity)
                    } else {
                        HStack(alignment: .bottom, spacing: 10) {
                            if mine { expandButton }
                            albumPager
                            if !mine { expandButton }
                        }
                    }
                }

                if reply != nil || !displayedCaption.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        if let reply {
                            Button { onJumpToReply(reply.messageID) } label: {
                                HStack(spacing: 7) {
                                    Capsule().fill(Color.pink.opacity(0.58)).frame(width: 3, height: 31)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(reply.sender)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.pink.opacity(0.78))
                                        Text(reply.preview)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if !displayedCaption.isEmpty {
                            SelectableMarkdownText(text: displayedCaption, selectionKey: selectionKey)
                        }
                    }
                    .modifier(ChatTextBubblePadding())
                    .modifier(ChatTextBubbleBackground(mine: mine))
                }

                if !reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(reactions, id: \.self) { emoji in
                            Text(emoji)
                                .font(.system(size: 15))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                        }
                    }
                    .modifier(BubbleGlass(shape: Capsule()))
                }

                if let message = messages.first {
                    Text(message.timestampText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.78))
                        .padding(.horizontal, 4)
                }
            }
            .modifier(messageMenu)

            if mine { Avatar(isMe: true) } else { Spacer(minLength: 0) }
        }
    }

    private var expandButton: some View {
        Button {
            let next = !expanded
            withAnimation(.easeInOut(duration: 0.22)) {
                expanded = next
            }
            onExpansionChange(next)
        } label: {
            Text(expanded ? "收起" : "展开 \(messages.count)")
                .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.72))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.11), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, expanded ? 0 : 14)
    }

    private var albumPager: some View {
        ZStack(alignment: .topLeading) {
            if files.count > 2 {
                AlbumCoverTile(name: files[(selectedIndex + 2) % files.count])
                    .scaleEffect(0.93, anchor: .bottomLeading)
                    .rotationEffect(.degrees(3.0), anchor: .bottomLeading)
                    .offset(x: 16, y: 8)
                    .allowsHitTesting(false)
            }
            if files.count > 1 {
                AlbumCoverTile(name: files[(selectedIndex + 1) % files.count])
                    .scaleEffect(0.965, anchor: .bottomLeading)
                    .rotationEffect(.degrees(1.5), anchor: .bottomLeading)
                    .offset(x: 8, y: 4)
                    .allowsHitTesting(false)
            }

            TabView(selection: $selectedIndex) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    AlbumCoverTile(name: file)
                        .tag(index)
                        .onTapGesture { onImage(API.fileURL(file)) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: 190, height: 238)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("\(min(selectedIndex + 1, files.count))/\(files.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.42), in: Capsule())
                .offset(x: 137, y: 198)
                .allowsHitTesting(false)
        }
        .frame(width: 212, height: 250, alignment: .topLeading)
        .clipped()
    }
}

private struct RetractedNoticeRow: View {
    let canReEdit: Bool
    let onReEdit: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("你撤回了一条消息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if canReEdit {
                Button("重新编辑", action: onReEdit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
    }
}

struct PatSystemRow: View {
    let info: PatInfo
    let timestamp: String
    let onEdit: () -> Void
    @AppStorage("assistantRemark") private var assistantRemark = "助手"

    var body: some View {
        VStack(spacing: 2) {
            Text(timestamp)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Button(action: onEdit) {
                Text(info.displayText(assistantName: assistantRemark))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}


private struct ChatTimeline: View, Equatable {
    private struct Row: Identifiable {
        let message: Msg
        let messageIndex: Int
        let partIndex: Int
        let text: String?
        var pat: PatInfo? = nil
        var isFirst = true
        var id: String { "\(message.id):\(partIndex)" }
        var scrollID: AnyHashable {
            partIndex == 0 ? AnyHashable(message.id) : AnyHashable(id)
        }
    }

    /// Pulls `[[拍一拍|后缀]]` lines out of an assistant message, matching the group chat rule.
    private static func extractPats(_ text: String, actor: String) -> (pats: [PatInfo], rest: String) {
        var pats: [PatInfo] = []
        var lines: [String] = []
        let target = UserDefaults.standard.string(forKey: "myNickname") ?? "我"
        for line in text.components(separatedBy: "\n") {
            if let values = LocalReplyMarkup.fields(line, tag: "拍一拍") {
                let suffix = values.first?.trimmingCharacters(in: .whitespaces) ?? ""
                pats.append(PatInfo(actor: actor, target: target, suffix: suffix.isEmpty ? "" : " \(suffix)"))
            } else {
                lines.append(line)
            }
        }
        return (pats, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // The parent supplies one coherent snapshot; observing the store here too
    // rendered old cached rows once before the new snapshot reached the view.
    let store: ChatStore
    let messages: [Msg]
    let reactions: [Int: [String]]
    let answered: Set<Int>
    let revealedPartCounts: [Int: Int]
    let activities: [Int: ChatActivity]
    let hasEarlierMessages: Bool
    let onLoadEarlier: () -> Void
    let highlightedMessageID: Int?
    let unreadStartMessageID: Int?
    let onImage: (URL) -> Void
    let onReply: (Msg) -> Void
    let onSelectText: (String) -> Void
    let onReact: (Int, String) -> Void
    let onMoreReactions: (Int) -> Void
    let onRetract: (Msg) -> Void
    let onDelete: (Msg) -> Void
    let onJumpToReply: (Int) -> Void
    let onAvatarDoubleTap: () -> Void
    let onEditPat: () -> Void
    let onAlbumExpansion: (Int, Bool) -> Void
    let onApproval: (Msg, ApprovePayload) -> Void
    let bottomInset: CGFloat
    let retractedIDs: Set<Int>
    let onReEdit: (Msg) -> Void
    let forwardedIDs: Set<Int>
    /// Font and bubble style; part of equality so appearance changes redraw the rows.
    var appearanceKey: String = ""

    /// 只有还没交给助手、且刚发不久的自己的消息才能撤回。
    private func canRetract(_ message: Msg) -> Bool {
        guard message.from == "me", !forwardedIDs.contains(message.id) else { return false }
        let raw = message.ts > 10_000_000_000 ? Double(message.ts) / 1000 : Double(message.ts)
        return Date().timeIntervalSince1970 - raw < 120
    }

    static func == (lhs: ChatTimeline, rhs: ChatTimeline) -> Bool {
        lhs.store === rhs.store &&
        lhs.retractedIDs == rhs.retractedIDs &&
        lhs.forwardedIDs == rhs.forwardedIDs &&
        lhs.messages == rhs.messages &&
        lhs.reactions == rhs.reactions &&
        lhs.answered == rhs.answered &&
        lhs.revealedPartCounts == rhs.revealedPartCounts &&
        lhs.activities == rhs.activities &&
        lhs.hasEarlierMessages == rhs.hasEarlierMessages &&
        lhs.highlightedMessageID == rhs.highlightedMessageID &&
        lhs.unreadStartMessageID == rhs.unreadStartMessageID &&
        lhs.bottomInset == rhs.bottomInset &&
        lhs.appearanceKey == rhs.appearanceKey
    }

    private func albumMessages(id: String) -> [Msg] {
        messages
            .filter { MediaGroupInfo.parse($0.text)?.id == id }
            .sorted {
                (MediaGroupInfo.parse($0.text)?.index ?? 0) <
                (MediaGroupInfo.parse($1.text)?.index ?? 0)
            }
    }

    private var rows: [Row] {
        messages.enumerated().flatMap { index, message -> [Row] in
            let canSplit = message.from != "me" && message.file == nil &&
                PatInfo.parse(message.text) == nil &&
                MediaGroupInfo.parse(message.text) == nil &&
                LocationInfo.parse(message.text) == nil &&
                store.approvePayload(for: message) == nil
            if canSplit, message.displayedText.contains("[[拍一拍") {
                let extracted = Self.extractPats(message.displayedText, actor: store.localPeer?.displayName ?? "助手")
                if !extracted.pats.isEmpty {
                    var result = extracted.pats.enumerated().map { offset, pat in
                        Row(message: message, messageIndex: index, partIndex: -1 - offset, text: nil,
                            pat: pat, isFirst: offset == 0)
                    }
                    let textParts = extracted.rest.isEmpty ? []
                        : MessageBubbleSplitter.parts(extracted.rest, enabled: true)
                    result += textParts.prefix(revealedPartCounts[message.id] ?? Int.max).enumerated().map {
                        Row(message: message, messageIndex: index, partIndex: $0.offset, text: $0.element, isFirst: false)
                    }
                    return result
                }
            }
            let parts = canSplit
                ? MessageBubbleSplitter.parts(message.displayedText, enabled: true) : []
            guard parts.count > 1 else {
                return [Row(message: message, messageIndex: index, partIndex: 0, text: nil)]
            }
            return parts.prefix(revealedPartCounts[message.id] ?? Int.max).enumerated().map {
                Row(message: message, messageIndex: index, partIndex: $0.offset, text: $0.element, isFirst: $0.offset == 0)
            }
        }
    }

    var body: some View {
        // iMessage 式列表：List 底层是 UITableView，只建看得见的行、
        // 滚出屏幕的 cell 直接复用；新消息只在尾部插入一行，不重建整个列表。
        List {
            if hasEarlierMessages {
                Button("查看更早的消息", action: onLoadEarlier)
                    .font(.system(size: 13))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(rows) { row in
                let message = row.message
                let index = row.messageIndex
                if row.isFirst && (index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: messages[index - 1].date)) {
                    ChatDateDivider(date: message.date)
                }
                if row.isFirst && message.id == unreadStartMessageID {
                    ChatUnreadDivider()
                }
                if let pat = row.pat {
                    PatSystemRow(info: pat, timestamp: message.timestampText, onEdit: {})
                        .id(row.scrollID)
                } else if retractedIDs.contains(message.id) {
                    if row.partIndex == 0 && (MediaGroupInfo.parse(message.text)?.index ?? 0) == 0 {
                        RetractedNoticeRow(canReEdit: store.canReEdit(message)) { onReEdit(message) }
                            .id(message.id)
                    }
                } else if let approval = store.approvePayload(for: message) {
                    if !store.isAnswered(message) {
                        ApprovalPromptRow(msg: message, payload: approval) {
                            onApproval(message, approval)
                        }
                        .id(message.id)
                        .modifier(ChatMessageHighlight(active: highlightedMessageID == message.id))
                    }
                } else if message.from == "me" &&
                            (message.text.hasPrefix("【已确认】") || message.text.hasPrefix("【已跳过】")) {
                    EmptyView()
                } else if let pat = PatInfo.parse(message.text) {
                    PatSystemRow(info: pat, timestamp: message.timestampText, onEdit: onEditPat)
                        .id(message.id)
                        .modifier(ChatMessageHighlight(active: highlightedMessageID == message.id))
                } else if let group = MediaGroupInfo.parse(message.text) {
                    if group.index == 0 {
                        MediaAlbumBubble(
                            messages: albumMessages(id: group.id),
                            reactions: reactions[message.id] ?? [],
                            onImage: onImage,
                            onReply: { onReply(message) },
                            onReact: { onReact(message.id, $0) },
                            onMoreReactions: { onMoreReactions(message.id) },
                            onRetract: { onRetract(message) },
                            onDelete: { onDelete(message) },
                            onSelectText: onSelectText,
                            onJumpToReply: onJumpToReply,
                            onAvatarDoubleTap: onAvatarDoubleTap,
                            onExpansionChange: { onAlbumExpansion(message.id, $0) },
                            canRetract: canRetract(message)
                        )
                        .id(message.id)
                        .modifier(ChatMessageHighlight(active: highlightedMessageID == message.id))
                    }
                } else if !message.text.isEmpty || message.file != nil {
                    Bubble(
                        msg: message,
                        reactions: reactions[message.id] ?? [],
                        onImage: onImage,
                        onReply: { onReply(message) },
                        onReact: { onReact(message.id, $0) },
                        onMoreReactions: { onMoreReactions(message.id) },
                        onRetract: { onRetract(message) },
                        onDelete: { onDelete(message) },
                        onSelectText: onSelectText,
                        onJumpToReply: onJumpToReply,
                        onAvatarDoubleTap: onAvatarDoubleTap,
                        partText: row.text,
                        showsReplyPreview: row.partIndex == 0,
                        visiblePartCount: Int.max,
                        activity: row.partIndex == 0 ? activities[message.id] : nil,
                        canRetract: canRetract(message)
                    )
                    .id(row.scrollID)
                    .modifier(ChatMessageHighlight(active: highlightedMessageID == message.id))
                }
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Color.clear
                .frame(height: bottomInset)
                .id("chat-bottom-anchor")
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct ChatUnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.pink.opacity(0.30)).frame(height: 0.5)
            Text("以下是新消息")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.pink.opacity(0.88))
                .fixedSize()
            Rectangle().fill(Color.pink.opacity(0.30)).frame(height: 0.5)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ChatDateDivider: View {
    let date: Date

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: .now) {
            return date.formatted(.dateTime.month().day())
        }
        return date.formatted(.dateTime.year().month().day())
    }

    var body: some View {
        // Today's divider is redundant with the per-message times; only earlier days are marked.
        if !Calendar.current.isDateInToday(date) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
    }
}

private struct ChatMessageHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.pink.opacity(active ? 0.22 : 0))
                    .padding(-5)
            }
            .scaleEffect(active ? 1.018 : 1)
    }
}

@Observable
private final class ChatDraftBuffer {
    var text = ""
}

// ===== 输入框独立出来：草稿状态只在这里观测 =====
// ChatView 原来三十多个 @State 里混着正在输入的草稿，敲一个字整个聊天页
// body 就跟着跑一遍；现在草稿、表情面板页签、语音按住态都归这个子树所有，
// 打字只重画输入框这一块，聊天页本身不再被每一次按键触动。
private struct ChatComposerView: View {
    @State private var draftBuffer = ChatDraftBuffer()
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var voicePressActive = false
    /// Finished recording waiting in the review bar (discard / play / send).
    @State private var recordedVoice: RecordedVoice?
    @State private var voicePreview: AVAudioPlayer?
    @State private var voicePreviewPlaying = false
    @State private var recordingStartedAt: Date?

    let draftKey: String
    let peerName: String
    let store: ChatStore
    let emojis: [String]
    @ObservedObject var voice: VoiceController
    @ObservedObject var stickers: StickerLibrary
    @ObservedObject var locationProvider: OneShotLocationProvider
    @Binding var replyingTo: Msg?
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var combineAfterSending: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var stickerPhoto: PhotosPickerItem?
    @Binding var showingAttachments: Bool
    @Binding var showingReactions: Bool
    @Binding var showingCamera: Bool
    @Binding var showingFilePicker: Bool
    @Binding var showingQuota: Bool
    @Binding var uploading: Bool
    @Binding var reEditText: String?
    var inputFocused: FocusState<Bool>.Binding
    let onSend: (String, @escaping (String) -> Void) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onVoiceError: (String) -> Void
    let onSendSticker: (LocalSticker) -> Void
    let onStagePhotos: ([PhotosPickerItem]) -> Void

    private var canCombinePendingImages: Bool {
        pendingAttachments.count >= 2 && pendingAttachments.allSatisfy(\.isImage)
    }

    var body: some View {
        composerContent
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ComposerHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(ComposerHeightPreferenceKey.self) { height in
                onHeightChange(height)
            }
            .onAppear {
                if draftBuffer.text.isEmpty {
                    draftBuffer.text = UserDefaults.standard.string(forKey: draftKey) ?? ""
                }
            }
            .onDisappear {
                draftSaveTask?.cancel()
                UserDefaults.standard.set(draftBuffer.text, forKey: draftKey)
            }
            .onChange(of: draftBuffer.text) { _, text in
                store.pingTyping(text)
                draftSaveTask?.cancel()
                draftSaveTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    UserDefaults.standard.set(text, forKey: draftKey)
                }
            }
            .onChange(of: reEditText) { _, text in
                guard let text else { return }
                draftBuffer.text = text
                replyingTo = nil
                inputFocused.wrappedValue = true
                reEditText = nil
            }
    }

    private func sendDraft(_ text: String) {
        onSend(text) { raw in
            if draftBuffer.text.isEmpty { draftBuffer.text = raw }
        }
    }

    private var composerContent: some View {
        VStack(spacing: 10) {
            if let replyingTo {
                ChatReplyComposerCard(
                    title: "回复 \(replyingTo.from == "me" ? "我" : peerName)",
                    preview: replyingTo.previewText
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil }
                }
            }

            if !pendingAttachments.isEmpty {
                pendingAttachmentTray
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showingAttachments {
                attachmentMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }

            ChatInputRow(
                buffer: draftBuffer,
                inputFocused: inputFocused,
                isRecording: voice.isRecording,
                isTranscribing: voice.isTranscribing,
                uploading: uploading,
                hasAttachments: !pendingAttachments.isEmpty,
                menuOpen: showingAttachments || showingReactions,
                recordingStartedAt: recordingStartedAt,
                recordedVoice: recordedVoice,
                previewPlaying: voicePreviewPlaying,
                onVoiceTap: toggleTranscription,
                onHoldStart: beginVoicePress,
                onHoldEnd: endVoicePress,
                onTogglePlus: {
                    inputFocused.wrappedValue = false
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        if showingAttachments || showingReactions {
                            showingAttachments = false
                            showingReactions = false
                        } else {
                            showingAttachments = true
                        }
                    }
                },
                onDiscardVoice: discardRecordedVoice,
                onPlayVoice: togglePreviewPlayback,
                onSendVoice: sendRecordedVoice,
                onSend: sendDraft
            )
            // With the bar's 10pt this gives a 28pt inset per side, matching the system Messages bar.
            .padding(.horizontal, 18)
        }
        // Stickers open in a bottom sheet in place of the keyboard area, so the input bar
        // stays at the bottom instead of being pushed up over the messages.
        .sheet(isPresented: $showingReactions) {
            reactionPanel
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .presentationDetents([.height(330), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(330)))
                .presentationCornerRadius(28)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard (showingAttachments || showingReactions),
                          value.startLocation.y > 50,
                          value.translation.height > 48,
                          value.translation.height > abs(value.translation.width) * 1.2 else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        showingAttachments = false
                        showingReactions = false
                    }
                }
        )
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            showingAttachments = false
            onStagePhotos(items)
        }
        .onChange(of: stickerPhoto) { _, item in
            guard let item else { return }
            stickerPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run {
                    stickers.add(data: data)
                }
            }
        }
    }

    private var pendingAttachmentTray: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("待发送 \(pendingAttachments.count)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if canCombinePendingImages {
                    PendingCombineToggle(isOn: $combineAfterSending)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pendingAttachments) { item in
                        PendingAttachmentCard(item: item) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                pendingAttachments.removeAll { $0.id == item.id }
                                if !canCombinePendingImages { combineAfterSending = false }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(10)
        .modifier(NativeGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    /// Vertical glass menu opened by the round plus button, iMessage style.
    private var attachmentMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                showingAttachments = false
                showingCamera = true
            } label: {
                ComposerMenuRow(title: "相机", systemImage: "camera.fill", tint: .gray)
            }

            PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 9, matching: .any(of: [.images, .videos])) {
                ComposerMenuRow(title: "照片", systemImage: "photo.on.rectangle", tint: .orange)
            }

            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    showingAttachments = false
                    showingReactions = true
                }
            } label: {
                ComposerMenuRow(title: "表情包", systemImage: "face.smiling.inverse", tint: .cyan)
            }

            Button {
                showingAttachments = false
                showingFilePicker = true
            } label: {
                ComposerMenuRow(title: "文件", systemImage: "folder.fill", tint: .blue)
            }

            Button {
                showingAttachments = false
                locationProvider.request { location in
                    Task {
                        await store.send(LocationInfo.encode(
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude
                        ))
                    }
                }
            } label: {
                ComposerMenuRow(title: locationProvider.isLocating ? "定位中" : "位置", systemImage: "location.fill", tint: .green)
            }

            if ServerConfig.workbenchWebURL != nil {
                Button {
                    showingAttachments = false
                    showingQuota = true
                } label: {
                    ComposerMenuRow(title: "额度", systemImage: "gauge.with.dots.needle.33percent", tint: .yellow)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 230, alignment: .leading)
        .modifier(NativeGlass(shape: RoundedRectangle(cornerRadius: 30, style: .continuous)))
    }

    /// Sticker panel (stickers only).
    private var reactionPanel: some View {
        VStack(spacing: 10) {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    PhotosPicker(selection: $stickerPhoto, matching: .images) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .medium))
                            Text("添加")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ForEach(stickers.items) { sticker in
                        Button {
                            onSendSticker(sticker)
                        } label: {
                            StickerThumbnail(url: sticker.url)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 16)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var panelHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.25))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onTapGesture {
                closeOpenPanel()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if value.translation.height > 28 {
                            closeOpenPanel()
                        }
                    }
            )
    }

    private func closeOpenPanel() {
        guard showingAttachments || showingReactions else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            showingAttachments = false
            showingReactions = false
        }
    }

    private func toggleTranscription() {
        inputFocused.wrappedValue = false
        if voice.isTranscribing {
            voice.stopTranscription()
        } else {
            showingReactions = false
            showingAttachments = false
            let existing = draftBuffer.text
            Task {
                do { try await voice.startTranscription { draftBuffer.text = existing + $0 } }
                catch { onVoiceError(error.localizedDescription) }
            }
        }
    }

    private func beginVoicePress() {
        inputFocused.wrappedValue = false
        voice.stopTranscription()
        showingReactions = false
        showingAttachments = false
        voicePressActive = true
        discardRecordedVoice()
        Task {
            do {
                try await voice.startRecording(shouldStart: { voicePressActive })
                if voice.isRecording { recordingStartedAt = Date() }
            } catch {
                onVoiceError(error.localizedDescription)
            }
        }
    }

    /// Releasing the press stops recording and leaves the clip in the review bar.
    private func endVoicePress() {
        voicePressActive = false
        recordingStartedAt = nil
        guard let url = voice.finishRecording() else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            recordedVoice = RecordedVoice(url: url, duration: voice.lastRecordingDuration)
        }
    }

    private func discardRecordedVoice() {
        voicePreview?.stop()
        voicePreview = nil
        voicePreviewPlaying = false
        if let clip = recordedVoice {
            try? FileManager.default.removeItem(at: clip.url)
        }
        recordedVoice = nil
    }

    private func togglePreviewPlayback() {
        guard let clip = recordedVoice else { return }
        if voicePreviewPlaying {
            voicePreview?.pause()
            voicePreviewPlaying = false
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        if voicePreview == nil { voicePreview = try? AVAudioPlayer(contentsOf: clip.url) }
        guard let player = voicePreview else { return }
        player.play()
        voicePreviewPlaying = true
        let length = max(player.duration - player.currentTime, 0.1)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(length))
            if voicePreview === player, !player.isPlaying { voicePreviewPlaying = false }
        }
    }

    private func sendRecordedVoice() {
        guard let clip = recordedVoice, !uploading else { return }
        voicePreview?.stop()
        voicePreview = nil
        voicePreviewPlaying = false
        recordedVoice = nil
        let url = clip.url
        Task {
            uploading = true
            defer { uploading = false }
            guard let data = try? Data(contentsOf: url) else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            if let saved = await store.upload(data, name: url.lastPathComponent) {
                await store.send("", file: saved)
            } else {
                onVoiceError("语音上传失败，请重试。")
            }
        }
    }

}

struct ChatView: View {

    @ObservedObject var store: ChatStore
    @AppStorage(ChatFontChoice.storageKey) private var chatFontRaw = ChatFontChoice.system.rawValue
    @AppStorage(ChatBubbleStyle.storageKey) private var chatBubbleStyleRaw = ChatBubbleStyle.glass.rawValue
    @Binding var isPinned: Bool
    let groupMembers: [AIConversation]
    let onCreateGroup: (AIConversation) -> Void
    let unreadStartMessageID: Int?
    let onReachedLatest: () -> Void
    @StateObject private var voice = VoiceController()
    @State private var voiceError: String?
    @State private var jumpToMessageID: Int?
    @State private var highlightedMessageID: Int?
    @State private var highlightTask: Task<Void, Never>?
    @State private var reactionTargetID: Int?
    @State private var replyingTo: Msg?
    @State private var reEditText: String?
    @State private var showingPatEditor = false
    @State private var approvalSheet: ApprovalSheetItem?
    @State private var panelScrollTask: Task<Void, Never>?
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var bgLoadTask: Task<Void, Never>?
    @State private var hasMeasuredComposer = false
    @State private var initialScrollReady = false
    /// 系统选字模式：系统手柄 + 系统菜单接管；为 true 时禁止 List 自动滚到底。
    @State private var isSystemSelecting = false
    @State private var timelineRefreshPending = false
    @State private var timelineMessages: [Msg] = []
    @State private var timelineLimit = ChatStore.messagePageSize
    @State private var timelineStartID: Int?
    @State private var hasEarlierMessages = false
    @State private var composerHeight: CGFloat = 57
    @AppStorage("claudeHiddenThroughID") private var hiddenThroughID = 0
    @StateObject private var locationProvider = OneShotLocationProvider()
    @StateObject private var stickers = StickerLibrary()
    @FocusState private var inputFocused: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var combineAfterSending = false
    @State private var attachmentError: String?
    @State private var retractNotice: String?
    @State private var stickerPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var viewer: ViewerItem?
    @State private var showingAttachments = false
    @State private var showingReactions = false
    @State private var showingCamera = false
    @State private var showingFilePicker = false
    @State private var showingChatDetails = false
    @State private var showingQuota = false
    @AppStorage("bgVersion") private var bgVersion = 0
    @State private var bgImage: UIImage?

    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("patSuffix") private var patSuffix = "并给他两个亿"
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""

    /// Device-local AI peer; nil means the mailbox conversation.
    private var localPeer: AIConversation? { store.localPeer }
    private var peerName: String { localPeer?.displayName ?? assistantRemark }
    private var draftKey: String { localPeer.map { "chatDraft.\($0.id)" } ?? "chatDraft.claude" }
    private var peerStatus: String {
        if store.isPeerTyping { return "对方正在输入…" }
        return store.localError == nil ? "在线" : "连接异常"
    }
    private var effectiveHiddenThroughID: Int { localPeer == nil ? hiddenThroughID : 0 }

    private let bottomAnchor = "chat-bottom-anchor"
    private let emojis = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "🥰",
        "😍", "😘", "😋", "😎", "🤩", "🥳", "😏",
        "🥺", "😭", "😤", "😡", "🤯", "😴", "🤔",
        "🙄", "😶", "🫠", "🤡", "👀", "👍", "🫶",
        "❤️", "💗", "✨", "🎉", "🔥", "🌚", "🫪"
    ]


    private func refreshTimeline(_ source: [Msg]? = nil) {
        // Reloading rows during system selection would move or drop the selected text.
        if isSystemSelecting {
            timelineRefreshPending = true
            return
        }
        // Run on message/history changes, never on each composer keystroke.
        // 自己撤回的消息保留在时间线里，渲染成撤回提示。
        let eligible = (source ?? store.msgs).filter { $0.id > effectiveHiddenThroughID && !store.isHiddenLocally($0.id) && ($0.from == "me" || !store.isRetracted($0.id)) }
        // Keep the first displayed row stable while replies arrive. Sliding a
        // suffix window removed a row from the top for every appended bubble.
        var start = timelineStartID.flatMap { id in eligible.firstIndex { $0.id == id } }
            ?? max(0, eligible.count - timelineLimit)
        // A page must not start in the middle of a combined photo album.
        if start < eligible.count, let album = MediaGroupInfo.parse(eligible[start].text), album.index > 0 {
            while start > 0, MediaGroupInfo.parse(eligible[start - 1].text)?.id == album.id { start -= 1 }
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasEarlierMessages = start > 0 || store.hasOlderMessages
            timelineStartID = start < eligible.count ? eligible[start].id : nil
            // 新消息只往尾部追加：窗口起点不变时，新窗口就是旧窗口加几条，
            // 直接 append，List 只插入新行；窗口滑动、撤回、隐藏时
            // 前缀对不上，再整窗替换。
            let newWindow = Array(eligible.dropFirst(start))
            if newWindow.count >= timelineMessages.count,
               Array(newWindow.prefix(timelineMessages.count)) == timelineMessages {
                timelineMessages.append(contentsOf: newWindow.dropFirst(timelineMessages.count))
            } else {
                timelineMessages = newWindow
            }
        }
    }

    var body: some View {
        chatPresentations
            .environment(\.chatPeerConversation, localPeer)
    }

    private var chatPresentations: some View {
        chatScreen
        .navigationDestination(isPresented: $showingChatDetails) {
            if let localPeer {
                ConfiguredAIChatDetailsView(
                    conversation: Binding(
                        get: { store.localPeer ?? localPeer },
                        set: { store.updateLocalPeer($0) }
                    ),
                    messages: Binding(
                        get: { store.localMessages },
                        set: { store.replaceLocalMessages($0) }
                    ),
                    onUpdate: persistLocalConversation,
                    onClear: { store.clearLocalHistory() }
                )
            } else {
                ChatDetailsView(
                    messages: store.msgs,
                    isPinned: $isPinned,
                    hiddenThroughID: $hiddenThroughID,
                    groupMembers: groupMembers,
                    onCreateGroup: onCreateGroup,
                    onJumpToMessage: { jumpToMessageID = $0 }
                )
            }
        }
        .alert("发送失败", isPresented: Binding(
            get: { store.localError != nil },
            set: { if !$0 { store.localError = nil } }
        )) {
            Button("好") { store.localError = nil }
        } message: {
            Text(store.localError ?? "")
        }
        .sheet(isPresented: $showingQuota) {
            Group {
                if let localPeer {
                    ProviderWalletView(conversation: localPeer)
                } else {
                    ClaudeQuotaView()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var chatScreen: some View {
        // GeometryReader 量顶栏高度和屏幕尺寸：List 要伸到顶栏底下，长按预览要按窗口坐标定位。
        GeometryReader { geo in
        ZStack {
            chatBackground
            if store.hasLoadedInitialMessages || !store.msgs.isEmpty {
                chatMainArea(geo: geo)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.primary.opacity(0.58))
            }
        }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(peerName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(peerStatus)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(store.isPeerTyping ? Color.pink.opacity(0.82) : Color.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .modifier(ToolbarMatchedGlass(shape: Capsule()))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingChatDetails = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("聊天详情")
            }
        }

        .alert("语音", isPresented: Binding(
            get: { voiceError != nil },
            set: { if !$0 { voiceError = nil } }
        )) {
            Button("好") { voiceError = nil }
        } message: {
            Text(voiceError ?? "")
        }
        .alert("附件", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("好") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .alert("撤回", isPresented: Binding(
            get: { retractNotice != nil },
            set: { if !$0 { retractNotice = nil } }
        )) {
            Button("好") { retractNotice = nil }
        } message: {
            Text(retractNotice ?? "")
        }
        .onAppear {
            store.start()
            refreshTimeline()
            reloadBG()
            markLocalPeerActive(true)
        }
        .onDisappear {
            store.stop()
            voice.stopTranscription()
            panelScrollTask?.cancel()
            highlightTask?.cancel()
            draftSaveTask?.cancel()
            bgLoadTask?.cancel()
            markLocalPeerActive(false)
        }
        .onReceive(store.$msgs) { messages in refreshTimeline(messages) }
        .onReceive(store.$retractedMessageIDs) { _ in
            // @Published emits before storage changes.
            Task { @MainActor in refreshTimeline() }
        }
        .onReceive(store.$hiddenMessageIDs) { _ in
            Task { @MainActor in refreshTimeline() }
        }
        .onChange(of: hiddenThroughID) { _, _ in refreshTimeline() }
        .onChange(of: bgVersion) { _, _ in reloadBG() }
        .sheet(isPresented: $showingPatEditor) {
            PatSettingsView(suffix: $patSuffix)
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
        }

        .sheet(item: $approvalSheet) { item in
            ApprovalSheetView(store: store, item: item)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { reactionTargetID != nil },
            set: { if !$0 { reactionTargetID = nil } }
        )) {
            ReactionPickerView(emojis: emojis) { emoji in
                if let reactionTargetID {
                    store.toggleReaction(emoji, for: reactionTargetID)
                }
                self.reactionTargetID = nil
            }
            .presentationDetents([.height(330)])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThickMaterial)
        }
    }

    private var chatBackground: some View {
        Group {
            if let bg = bgImage {
                GeometryReader { geo in
                    Image(uiImage: bg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .overlay(Color.black.opacity(0.025))
                .ignoresSafeArea()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.90, blue: 0.95),
                            Color(red: 0.91, green: 0.88, blue: 1.00),
                            Color(red: 1.00, green: 0.96, blue: 0.90)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(Color.pink.opacity(0.26))
                        .frame(width: 260, height: 260)
                        .blur(radius: 45)
                        .offset(x: 130, y: -250)
                    Circle()
                        .fill(Color.purple.opacity(0.18))
                        .frame(width: 300, height: 300)
                        .blur(radius: 55)
                        .offset(x: -150, y: 260)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func reloadBG() {
        bgLoadTask?.cancel()
        guard bgVersion > 0 else {
            bgImage = nil
            return
        }
        // 背景图从磁盘读 + 解码挪出主线程：进聊天页第一帧不再被一张大图堵住，
        // 图解好回到主线程再挂上；换背景时取消上一张的加载。
        bgLoadTask = Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) {
                guard let loaded = UIImage(contentsOfFile: SettingsView.bgPath.path) else { return nil as UIImage? }
                return loaded.preparingForDisplay()
            }.value
            guard !Task.isCancelled else { return }
            bgImage = image
        }
    }

    private func jumpWithoutAnimation(
        _ proxy: ScrollViewProxy,
        to id: some Hashable,
        anchor: UnitPoint
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: anchor)
        }
    }

    @ViewBuilder
    private func chatMainArea(geo: GeometryProxy) -> some View {
                ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    // List 直接撑满：之前外层还套着 ScrollView，List 在竖向
                    // ScrollView 里高度会被压成 0，聊天页一片空白。
                    ChatTimeline(
                            store: store,
                            messages: timelineMessages,
                            reactions: store.reactions,
                            answered: store.answered,
                            revealedPartCounts: store.revealedPartCounts,
                            activities: store.activities,
                            hasEarlierMessages: hasEarlierMessages,
                            onLoadEarlier: {
                                let anchor = timelineMessages.first?.id
                                Task { @MainActor in
                                    if store.hasOlderMessages {
                                        // 窗口之外还有更早的历史，先去服务器取一页。
                                        let fetched = await store.loadOlderMessages()
                                        if fetched > 0 { timelineLimit += fetched }
                                    } else {
                                        // 已经全在内存里了，只多显示一页。
                                        timelineLimit = timelineMessages.count + ChatStore.messagePageSize
                                    }
                                    timelineStartID = nil
                                    refreshTimeline()
                                    if let anchor {
                                        await Task.yield()
                                        jumpWithoutAnimation(proxy, to: anchor, anchor: .top)
                                    }
                                }
                            },
                            highlightedMessageID: highlightedMessageID,
                            unreadStartMessageID: unreadStartMessageID,
                            onImage: { viewer = ViewerItem(url: $0) },
                            onReply: { message in
                                replyingTo = message
                                showingAttachments = false
                                showingReactions = false
                                inputFocused = true
                            },
                            onSelectText: { enterSystemSelection(key: $0) },
                            onReact: { messageID, emoji in
                                store.toggleReaction(emoji, for: messageID)
                            },
                            onMoreReactions: { messageID in
                                reactionTargetID = messageID
                            },
                            onRetract: { retractMessage($0) },
                            onDelete: { message in
                                store.hideLocally(message)
                            },
                            onJumpToReply: { jumpToMessageID = $0 },
                            onAvatarDoubleTap: sendPat,
                            onEditPat: { showingPatEditor = true },
                            onAlbumExpansion: { messageID, isExpanded in
                                guard !isExpanded else { return }
                                DispatchQueue.main.async {
                                    jumpWithoutAnimation(proxy, to: messageID, anchor: .center)
                                }
                            },
                            onApproval: { message, payload in
                                approvalSheet = ApprovalSheetItem(msg: message, payload: payload)
                            },
                            bottomInset: composerHeight + 1,
                            retractedIDs: store.retractedMessageIDs,
                            onReEdit: { message in
                                reEditText = message.displayedText
                            },
                            forwardedIDs: store.forwardedMessageIDs,
                            appearanceKey: chatFontRaw + "|" + chatBubbleStyleRaw
                        )
                        .equatable()
                        .padding(.horizontal, 14)
                        .contentMargins(.top, geo.safeAreaInsets.top + 8, for: .scrollContent)
                        .chatInitialBottomAnchor(followsSizeChanges: !isSystemSelecting)
                        .transparentTopScrollEdge()
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(
                            SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                                guard isSystemSelecting,
                                      !ChatTextSelection.isSelectionInteraction(at: value.location) else { return }
                                isSystemSelecting = false
                                NotificationCenter.default.post(name: .clearChatTextSelection, object: nil)
                                ChatTextSelection.endSystemSelection()
                            }
                        )

                    ChatComposerView(
                        draftKey: draftKey,
                        peerName: peerName,
                        store: store,
                        emojis: emojis,
                        voice: voice,
                        stickers: stickers,
                        locationProvider: locationProvider,
                        replyingTo: $replyingTo,
                        pendingAttachments: $pendingAttachments,
                        combineAfterSending: $combineAfterSending,
                        selectedPhotos: $selectedPhotos,
                        stickerPhoto: $stickerPhoto,
                        showingAttachments: $showingAttachments,
                        showingReactions: $showingReactions,
                        showingCamera: $showingCamera,
                        showingFilePicker: $showingFilePicker,
                        showingQuota: $showingQuota,
                        uploading: $uploading,
                        reEditText: $reEditText,
                        inputFocused: $inputFocused,
                        onSend: { text, restore in sendDraft(text, restoreDraft: restore) },
                        onHeightChange: { height in
                            guard height > 0, abs(height - composerHeight) > 0.5 else { return }
                            composerHeight = height
                            // 输入框换行只改底边距，不贴底滚动：贴底由 sizeChanges 锚点自己处理，
                            // 再 scrollTo 会把正在往上翻的人一把拽到底，打字时页面一跳。
                            if !hasMeasuredComposer {
                                hasMeasuredComposer = true
                                if initialScrollReady { followPanel(proxy) }
                            }
                        },
                        onVoiceError: { voiceError = $0 },
                        onSendSticker: { sticker in sendSticker(sticker) },
                        onStagePhotos: { items in stagePhotos(items) }
                    )

                }
                .task {
                    guard !initialScrollReady else { return }
                    // 只定位一次：等 Lazy 行、缓存图和输入框几次布局都落定
                    // （约 260ms）再一次跳到底。之前 0/90/260ms 各跳一次，
                    // 进页时页面会连抖三下。
                    await Task.yield()
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled else { return }
                    jumpWithoutAnimation(proxy, to: bottomAnchor, anchor: .bottom)
                    initialScrollReady = true
                    onReachedLatest()
                }
                .onChange(of: timelineMessages.last?.id) { _, _ in
                    // 新消息（任一方）到达时贴底，键盘弹起时也不会被输入栏挡住。
                    followPanel(proxy)
                    onReachedLatest()
                    if let message = store.msgs.last,
                       let payload = store.approvePayload(for: message),
                       !store.isAnswered(message) {
                        approvalSheet = ApprovalSheetItem(msg: message, payload: payload)
                    }
                }
                .onChange(of: hiddenThroughID) { _, _ in
                    guard !isSystemSelecting else { return }
                    jumpWithoutAnimation(proxy, to: bottomAnchor, anchor: .bottom)
                }
                .onChange(of: isSystemSelecting) { _, selecting in
                    if !selecting && timelineRefreshPending {
                        timelineRefreshPending = false
                        refreshTimeline()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    followPanel(proxy)
                }
                .onChange(of: showingReactions) { _, _ in followPanel(proxy) }
                .onChange(of: showingAttachments) { _, _ in followPanel(proxy) }
                .onChange(of: inputFocused) { _, focused in
                    if focused {
                        showingAttachments = false
                        showingReactions = false
                        followPanel(proxy)
                    }
                }
                .onChange(of: jumpToMessageID) { _, id in
                    guard let id else { return }
                    if !timelineMessages.contains(where: { $0.id == id }),
                       let index = store.msgs.firstIndex(where: { $0.id == id }) {
                        timelineLimit = max(timelineLimit, store.msgs.count - index)
                        timelineStartID = nil
                        refreshTimeline()
                    }
                    highlightTask?.cancel()
                    highlightTask = Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(id, anchor: .center)
                            highlightedMessageID = id
                        }
                        jumpToMessageID = nil
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        try? await Task.sleep(for: .milliseconds(900))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.38)) {
                            highlightedMessageID = nil
                        }
                    }
                }
                .fullScreenCover(item: $viewer) { v in ImageViewer(url: v.url) }
                .fullScreenCover(isPresented: $showingCamera) {
                    CameraPicker(onImage: { image in uploadCameraImage(image) },
                                 onVideo: { url in stageVideoFile(url) }).ignoresSafeArea()
                }
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [.item],
                    allowsMultipleSelection: true
                ) { result in
                    guard case .success(let urls) = result else { return }
                    stageFiles(urls)
                }
            }
    }

    private func followPanel(_ proxy: ScrollViewProxy) {
        // 系统选字时不自动滚到底，否则选区会跑开。
        guard !isSystemSelecting else { return }
        panelScrollTask?.cancel()
        panelScrollTask = Task { @MainActor in
            // Follow the resize twice instead of hammering scrollTo throughout typing/panel animation.
            for delay in [UInt64(0), 220] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }


    /// 「选择文字」: system selection handles and the system edit menu on that message.
    private func enterSystemSelection(key: String) {
        isSystemSelecting = ChatTextSelection.beginSystemSelection(key: key)
    }

    private func sendDraft(_ rawText: String, restoreDraft: @escaping (String) -> Void) {
        guard !uploading else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        let replyTarget = replyingTo
        let shouldCombine = combineAfterSending && attachments.count >= 2 && attachments.allSatisfy(\.isImage)
        guard !text.isEmpty || !attachments.isEmpty else { return }

        func payload(_ body: String) -> String {
            guard let replyTarget else { return body }
            let sender = replyTarget.from == "me" ? "我" : peerName
            return ReplyInfo.encode(message: replyTarget, sender: sender, body: body)
        }

        showingAttachments = false
        showingReactions = false
        // Sent items leave the composer immediately. Only unsuccessful items
        // return to it; the captured batch remains alive during the transfer.
        pendingAttachments = []
        replyingTo = nil
        combineAfterSending = false
        uploading = true
        let lease = ChatSendBackgroundLease()

        Task {
            defer { uploading = false; lease.end() }

            if attachments.isEmpty {
                if !(await store.send(payload(text))) {
                    if replyingTo == nil { replyingTo = replyTarget }
                    restoreDraft(rawText)
                    attachmentError = "消息发送未确认，请检查网络和聊天记录后重试。"
                }
                return
            }

            var uploaded: [(item: PendingAttachment, name: String)] = []
            for item in attachments {
                if let saved = await store.upload(item.data, name: item.name) {
                    if item.isImage { ChatImageCache.store(item.data, name: saved) }
                    uploaded.append((item, saved))
                }
            }

            guard !uploaded.isEmpty else {
                pendingAttachments.insert(contentsOf: attachments, at: 0)
                combineAfterSending = shouldCombine
                if replyingTo == nil { replyingTo = replyTarget }
                restoreDraft(rawText)
                attachmentError = "附件上传未完成，图片和文字已保留，可以重试。"
                return
            }

            var sentIDs: Set<UUID> = []
            var captionSent = false
            if shouldCombine, uploaded.count >= 2, uploaded.allSatisfy({ $0.item.isImage }) {
                let groupID = UUID().uuidString
                for (index, entry) in uploaded.enumerated() {
                    let groupedText = MediaGroupInfo.encode(
                        id: groupID,
                        index: index,
                        count: uploaded.count,
                        caption: index == 0 ? payload(text) : ""
                    )
                    guard await store.send(groupedText, file: entry.name) else { break }
                    sentIDs.insert(entry.item.id)
                    if index == 0 { captionSent = true }
                }
            } else {
                let batchID = UUID().uuidString
                let isImageBatch = uploaded.count >= 2 && uploaded.allSatisfy { $0.item.isImage }
                for (index, entry) in uploaded.enumerated() {
                    let caption = index == 0 ? payload(text) : ""
                    let body = isImageBatch
                        ? "[[bear-batch|\(batchID)|\(index)|\(uploaded.count)]]\n" + caption
                        : caption
                    guard await store.send(body, file: entry.name) else { break }
                    sentIDs.insert(entry.item.id)
                    if index == 0 { captionSent = true }
                }
            }

            let failed = attachments.filter { !sentIDs.contains($0.id) }
            pendingAttachments.insert(contentsOf: failed, at: 0)
            if !captionSent {
                if replyingTo == nil { replyingTo = replyTarget }
                restoreDraft(rawText)
            }
            if sentIDs.count < attachments.count {
                combineAfterSending = shouldCombine && pendingAttachments.count >= 2
                attachmentError = "有 \(attachments.count - sentIDs.count) 个附件发送未完成，已保留供重试。"
            } else {
                combineAfterSending = false
            }
        }
    }

    private func retractMessage(_ message: Msg) {
        let targets: [Msg]
        if let group = MediaGroupInfo.parse(message.text) {
            targets = store.msgs.filter { MediaGroupInfo.parse($0.text)?.id == group.id }
        } else {
            targets = [message]
        }
        Task {
            var failed = false
            for target in targets {
                if !(await store.retract(target)) { failed = true }
            }
            if failed { retractNotice = "消息已送达，无法撤回。"; await store.poll() }
        }
    }

    private func uploadCameraImage(_ image: UIImage) {
        showingAttachments = false
        let data = downscale(image, maxSide: 2048)
        withAnimation(.easeOut(duration: 0.18)) {
            pendingAttachments.append(
                PendingAttachment(
                    data: data,
                    name: "img-\(UUID().uuidString).jpg",
                    preview: UIImage(data: data)
                )
            )
        }
    }

    /// 拍摄得到的视频文件：读入后作为普通附件待发送。
    private func stageVideoFile(_ url: URL) {
        showingAttachments = false
        Task {
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "没有读到拍摄的视频。"
                return
            }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
            withAnimation(.easeOut(duration: 0.18)) {
                pendingAttachments.append(PendingAttachment(data: data, name: "vid-\(UUID().uuidString).\(ext)", preview: nil))
            }
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) {
        Task {
            var staged: [PendingAttachment] = []
            for item in items {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    guard data.count <= 200 * 1024 * 1024 else {
                        attachmentError = "视频超过 200 MB，发不了。"
                        continue
                    }
                    let type = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                    let ext = type?.preferredFilenameExtension ?? "mov"
                    staged.append(PendingAttachment(data: data, name: "vid-\(UUID().uuidString).\(ext)", preview: nil))
                    continue
                }
                guard let original = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: original) else { continue }
                let data = downscale(image, maxSide: 2048)
                staged.append(
                    PendingAttachment(
                        data: data,
                        name: "img-\(UUID().uuidString).jpg",
                        preview: UIImage(data: data)
                    )
                )
            }
            if staged.isEmpty {
                attachmentError = "没有读到可发送的图片。"
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    pendingAttachments.append(contentsOf: staged)
                }
            }
        }
    }

    private func stageFiles(_ urls: [URL]) {
        showingAttachments = false
        Task {
            var staged: [PendingAttachment] = []
            var failedCount = 0
            for url in urls {
                let secured = url.startAccessingSecurityScopedResource()
                defer {
                    if secured { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url) else {
                    failedCount += 1
                    continue
                }
                let limit = API.isVideo(url.lastPathComponent) ? 200 : 20
                guard data.count <= limit * 1024 * 1024 else {
                    failedCount += 1
                    continue
                }
                let fallback = "file-\(UUID().uuidString)"
                let name = url.lastPathComponent.isEmpty ? fallback : url.lastPathComponent
                staged.append(
                    PendingAttachment(
                        data: data,
                        name: name,
                        preview: UIImage(data: data)
                    )
                )
            }
            if !staged.isEmpty {
                withAnimation(.easeOut(duration: 0.18)) {
                    pendingAttachments.append(contentsOf: staged)
                }
            }
            if failedCount > 0 {
                attachmentError = "有 \(failedCount) 个文件无法读取或超过 20 MB。"
            }
        }
    }

    private func sendSticker(_ sticker: LocalSticker) {
        guard !uploading else { return }
        showingReactions = false
        uploading = true
        let lease = ChatSendBackgroundLease()
        Task {
            defer { uploading = false; lease.end() }
            guard let data = try? Data(contentsOf: sticker.url) else { return }
            if let saved = await store.upload(data, name: sticker.url.lastPathComponent) {
                ChatImageCache.store(data, name: saved)
                let replyText: String
                if let replyingTo {
                    let sender = replyingTo.from == "me" ? "我" : peerName
                    replyText = ReplyInfo.encode(message: replyingTo, sender: sender, body: "")
                } else {
                    replyText = ""
                }
                if await store.send(replyText, file: saved) {
                    self.replyingTo = nil
                } else {
                    attachmentError = "表情包发送未确认，请检查聊天记录后重试。"
                }
            } else {
                attachmentError = "表情包上传未完成，请重试。"
            }
        }
    }

    private func markLocalPeerActive(_ active: Bool) {
        guard let localPeer else { return }
        if active {
            UserDefaults.standard.set(localPeer.id, forKey: LocalAIInbox.activeKey)
        } else if UserDefaults.standard.string(forKey: LocalAIInbox.activeKey) == localPeer.id {
            UserDefaults.standard.removeObject(forKey: LocalAIInbox.activeKey)
        }
    }

    private func persistLocalConversation(_ updated: AIConversation) {
        store.updateLocalPeer(updated)
        guard let data = conversationsJSON.data(using: .utf8),
              var conversations = try? JSONDecoder().decode([AIConversation].self, from: data),
              let index = conversations.firstIndex(where: { $0.id == updated.id }) else { return }
        conversations[index] = updated
        guard let encoded = try? JSONEncoder().encode(conversations),
              let string = String(data: encoded, encoding: .utf8) else { return }
        conversationsJSON = string
    }

    private func sendPat() {
        let cleanSuffix = patSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = PatInfo.encode(
            actor: "我",
            target: peerName,
            suffix: cleanSuffix.isEmpty ? "" : " \(cleanSuffix)"
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await store.send(text) }
    }
}

struct RecordedVoice: Equatable {
    let url: URL
    let duration: TimeInterval
}

/// One row of the plus menu: colored round icon and title.
private struct ComposerMenuRow: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint.gradient, in: Circle())
            Text(title)
                .font(.system(size: 17, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// iMessage-style input bar: round plus on the left, long capsule field with a
/// waveform (empty) or blue send arrow (text) inside on the right. Long-pressing
/// the empty field records a voice clip; on release the review bar appears.
private struct ChatInputRow: View {
    @AppStorage(ChatFontChoice.storageKey) private var composerFontRaw = ChatFontChoice.system.rawValue
    private var composerFont: ChatFontChoice { ChatFontChoice(rawValue: composerFontRaw) ?? .system }
    @Bindable var buffer: ChatDraftBuffer
    let inputFocused: FocusState<Bool>.Binding
    let isRecording: Bool
    let isTranscribing: Bool
    let uploading: Bool
    let hasAttachments: Bool
    let menuOpen: Bool
    let recordingStartedAt: Date?
    let recordedVoice: RecordedVoice?
    let previewPlaying: Bool
    let onVoiceTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let onTogglePlus: () -> Void
    let onDiscardVoice: () -> Void
    let onPlayVoice: () -> Void
    let onSendVoice: () -> Void
    let onSend: (String) -> Void

    private static let sendBlue = Color(red: 0.23, green: 0.56, blue: 0.98)

    private var hasText: Bool {
        !buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { hasText || hasAttachments }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let recordedVoice {
                circleButton(systemName: "xmark", action: onDiscardVoice)
                    .accessibilityLabel("取消语音")
                voiceBar(duration: recordedVoice.duration, live: false)
            } else {
                circleButton(systemName: isRecording ? "xmark" : "plus",
                             rotation: menuOpen && !isRecording ? 45 : 0,
                             action: onTogglePlus)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: menuOpen)
                    .opacity(isRecording ? 0.5 : 1)
                    .allowsHitTesting(!isRecording)
                    .accessibilityLabel("更多")
                // The field (and its hold recognizer) stays mounted while recording so
                // the release still reaches it; the live bar is drawn on top.
                field
                    .opacity(isRecording ? 0.001 : 1)
                    .overlay {
                        if isRecording {
                            voiceBar(duration: nil, live: true)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("信息", text: $buffer.text, axis: .vertical)
                .font(composerFont.swiftUIFont)
                .lineLimit(1...5)
                .focused(inputFocused)
                .padding(.leading, 16)
                .padding(.vertical, 9)
                .overlay {
                    // Empty, unfocused field: tap focuses, long press records.
                    if !hasText && !inputFocused.wrappedValue {
                        VoicePressSurface(
                            onTap: { inputFocused.wrappedValue = true },
                            onHoldStart: onHoldStart,
                            onHoldEnd: onHoldEnd
                        )
                    }
                }

            Group {
                if canSend || uploading {
                    Button {
                        guard canSend, !uploading else { return }
                        let outgoing = buffer.text
                        buffer.text = ""
                        onSend(outgoing)
                    } label: {
                        Group {
                            if uploading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 36, height: 32)
                        .background(Self.sendBlue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading)
                    .accessibilityLabel("发送")
                } else {
                    Button(action: onVoiceTap) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isTranscribing ? Color.pink : Color.secondary)
                            .symbolEffect(.variableColor.iterative, isActive: isTranscribing)
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isTranscribing ? "停止语音转文字" : "语音转文字，长按输入框录音")
                }
            }
            .padding(.trailing, 6)
            .padding(.bottom, 4)
        }
        .frame(minHeight: 40)
        .modifier(NativeGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true))
    }

    private func voiceBar(duration: TimeInterval?, live: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: onPlayVoice) {
                Image(systemName: live ? "mic.fill" : (previewPlaying ? "pause.fill" : "play.fill"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(live ? Color.red : Color.primary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(live)

            HStack(spacing: 3) {
                ForEach(0..<18, id: \.self) { i in
                    Capsule()
                        .fill(Color.primary.opacity(0.65))
                        .frame(width: 2.5, height: live ? CGFloat(6 + (i * 7) % 11) : 8)
                }
            }
            .frame(maxWidth: .infinity)

            Group {
                if live, let start = recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 0.5)) { context in
                        Text("+ " + Self.clock(context.date.timeIntervalSince(start)))
                    }
                } else {
                    Text("+ " + Self.clock(duration ?? 0))
                }
            }
            .font(.system(size: 15, weight: .medium).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.10), in: Capsule())

            Button(action: onSendVoice) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 32)
                    .background(Self.sendBlue, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(live || uploading)
            .opacity(live ? 0.45 : 1)
            .accessibilityLabel("发送语音")
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .modifier(NativeGlass(shape: Capsule(), interactive: true))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Fixed 44pt glass circle. The glass is non-interactive and clipped to the button so
    /// it can never grow or morph beyond the button; only the symbol rotates.
    private func circleButton(systemName: String, rotation: Double = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 40, height: 40)
        .modifier(NativeGlass(shape: Circle()))
        .clipShape(Circle())
        .fixedSize()
    }
}

private struct PatSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var suffix: String
    @State private var draft = ""

    var body: some View {
        ZStack {
            AppBackdrop()
            VStack(spacing: 0) {
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Text("设置拍一拍")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("完成") {
                        suffix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .padding(.horizontal, 20)
                .frame(height: 54)

                VStack(alignment: .leading, spacing: 14) {
                    Text("朋友拍你时，会显示在聊天里的系统提示后面。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    TextField("例如：并给了你一颗糖", text: $draft)
                        .font(.system(size: 16))
                        .padding(.horizontal, 15)
                        .frame(height: 50)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
                    Text("预览：我拍了拍「你」 \(draft)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
        .onAppear { draft = suffix }
    }
}

private struct ReactionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let emojis: [String]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
                    spacing: 12
                ) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button {
                            onSelect(emoji)
                            dismiss()
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("选择消息表情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

struct AttachmentTile: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct LocalSticker: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
}

final class StickerLibrary: ObservableObject {
    @Published private(set) var items: [LocalSticker] = []

    fileprivate static let folderURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ChatStickers", isDirectory: true)
    }()

    init() {
        load()
    }

    func add(data: Data) {
        guard let image = UIImage(data: data) else { return }
        try? FileManager.default.createDirectory(
            at: Self.folderURL,
            withIntermediateDirectories: true
        )
        let file = Self.folderURL.appendingPathComponent("sticker-\(UUID().uuidString).jpg")
        try? downscale(image, maxSide: 1024).write(to: file, options: .atomic)
        load()
    }

    private func load() {
        try? FileManager.default.createDirectory(
            at: Self.folderURL,
            withIntermediateDirectories: true
        )
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls
            .filter { API.isImage($0.lastPathComponent) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(LocalSticker.init(url:))
    }
}

private enum StickerImageCache {
    static let images = NSCache<NSString, UIImage>()

    static func image(for url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

struct StickerThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
                    .overlay(Image(systemName: "photo"))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onAppear {
            image = StickerImageCache.image(for: url)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onImage: (UIImage) -> Void
    var onVideo: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        if onVideo != nil {
            controller.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            controller.videoQuality = .typeHigh
        }
        controller.delegate = context.coordinator
        controller.allowsEditing = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo?(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

final class OneShotLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isLocating = false
    private let manager = CLLocationManager()
    private var completion: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request(completion: @escaping (CLLocation) -> Void) {
        self.completion = completion
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            isLocating = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        isLocating = false
        guard let location = locations.last else { return }
        completion?(location)
        completion = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLocating = false
        completion = nil
    }
}

// ===== 朋友圈 =====
// 朋友圈网页由服务器维护，App 负责沉浸式打开和返回主界面。
private struct MomentsWebTab: View {
    @State private var loading = true
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let url = ServerConfig.momentsBase {
                WorkspaceWebView(url: url, isLoading: $loading)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView("未设置服务器地址", systemImage: "server.rack",
                                       description: Text("在设置里填写你自己部署的服务器地址后，这里会打开朋友圈网页。"))
            }

            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .accessibilityLabel("返回对话")

            if loading, ServerConfig.momentsBase != nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 21)
                    .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

struct MomentPost: Identifiable {
    let id = UUID()
    let author: String
    let text: String
    let time: String
    let symbol: String
    let tint: Color
    let mine: Bool
    let contactHint: String?

    static let samples: [MomentPost] = [
        MomentPost(author: "puppy", text: "今天也在认真把熊窝一点点做好。", time: "刚刚", symbol: "pawprint.fill", tint: Color(red: 0.98, green: 0.63, blue: 0.75), mine: false, contactHint: "puppy"),
        MomentPost(author: "助手", text: "晚风很好，适合慢慢走一会儿。", time: "18:26", symbol: "sparkles", tint: Color(red: 0.63, green: 0.58, blue: 0.90), mine: false, contactHint: "ayan"),
        MomentPost(author: "助手", text: "代码终于安静地跑起来了。", time: "17:40", symbol: "ellipsis.curlybraces", tint: Color(red: 0.84, green: 0.56, blue: 0.42), mine: false, contactHint: "claude")
    ]
}

struct MomentsView: View {
    @AppStorage("myNickname") private var nickname = "我"
    @AppStorage("mySignature") private var signature = "今天也要好好生活"
    @AppStorage("momentsBgVersion") private var momentsBgVersion = 0
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @State private var posts = MomentPost.samples
    @State private var showingComposer = false
    @State private var showingBackgroundPicker = false
    @State private var backgroundImage: UIImage?
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                momentsBackground

                ScrollView {
                    LazyVStack(spacing: 0) {
                        VStack(spacing: 9) {
                            MyAvatar(size: 78)
                                .overlay(Circle().strokeBorder(.white.opacity(0.82), lineWidth: 2))
                                .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
                            Text(nickname.isEmpty ? "我" : nickname)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                            Text(signature.isEmpty ? "还没有填写签名" : signature)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.black.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .foregroundStyle(.black.opacity(0.86))
                        .textShadowForPhotoBackground()
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                        .padding(.bottom, 28)

                        ForEach(posts) { post in
                            MomentRow(
                                post: post,
                                conversation: matchingContact(for: post),
                                assistantRemark: assistantRemark
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 66)
                    .padding(.bottom, 34)
                }
                .scrollIndicators(.hidden)

                VStack {
                    HStack(spacing: 11) {
                        Button(action: onClose) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("返回对话")

                        Text("朋友圈")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.82))
                            .textShadowForPhotoBackground()

                        Spacer()

                        Button { showingBackgroundPicker = true } label: {
                            Image(systemName: "photo.on.rectangle.angled")
                        }
                        .accessibilityLabel("更换朋友圈背景")

                        Button { showingComposer = true } label: {
                            Image(systemName: "camera.fill")
                        }
                        .accessibilityLabel("发朋友圈")
                    }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
                    .padding(.horizontal, 17)
                    .frame(height: 50)

                    Spacer()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $showingComposer) {
                MomentComposer { text in
                    posts.insert(
                        MomentPost(
                            author: nickname.isEmpty ? "我" : nickname,
                            text: text,
                            time: "刚刚",
                            symbol: "person.fill",
                            tint: Color(red: 1.00, green: 0.67, blue: 0.80),
                            mine: true,
                            contactHint: nil
                        ),
                        at: 0
                    )
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingBackgroundPicker) {
                MomentBackgroundChoice()
                    .presentationDetents([.height(280)])
                    .presentationDragIndicator(.visible)
            }
            .onAppear { reloadBackground() }
            .onChange(of: momentsBgVersion) { _, _ in reloadBackground() }
        }
    }

    @ViewBuilder
    private var momentsBackground: some View {
        if let backgroundImage {
            GeometryReader { geometry in
                Image(uiImage: backgroundImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(Color.white.opacity(0.38))
                    .overlay(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.08), .white.opacity(0.50)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .ignoresSafeArea()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.90, blue: 0.95),
                        Color(red: 0.94, green: 0.91, blue: 1.00),
                        Color(red: 1.00, green: 0.96, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(.white.opacity(0.38))
                    .frame(width: 300, height: 300)
                    .blur(radius: 28)
                    .offset(x: 145, y: -260)
                Circle()
                    .fill(Color.pink.opacity(0.16))
                    .frame(width: 340, height: 340)
                    .blur(radius: 55)
                    .offset(x: -160, y: 290)
            }
            .ignoresSafeArea()
        }
    }

    private func reloadBackground() {
        backgroundImage = momentsBgVersion > 0
            ? UIImage(contentsOfFile: SettingsView.momentsBgPath.path)
            : nil
    }

    private func matchingContact(for post: MomentPost) -> AIConversation? {
        guard let hint = post.contactHint?.lowercased(),
              let data = conversationsJSON.data(using: .utf8),
              let contacts = try? JSONDecoder().decode([AIConversation].self, from: data) else { return nil }

        if hint == "claude" {
            return contacts.first { $0.id == "claude" }
        }

        return contacts.first { contact in
            guard contact.kind != "group", contact.id != "claude" else { return false }
            let searchable = [
                contact.id, contact.name, contact.remark ?? "", contact.provider ?? "",
                contact.model ?? "", contact.baseURL ?? ""
            ].joined(separator: " ").lowercased()
            if searchable.contains(hint) { return true }
            if hint == "puppy" {
                return searchable.contains("gpt-5.6")
            }
            return false
        }
    }
}

struct MomentRow: View {
    let post: MomentPost
    let conversation: AIConversation?
    let assistantRemark: String

    private var authorName: String {
        if post.contactHint == "claude" { return assistantRemark }
        return conversation?.displayName ?? post.author
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 8) {
                Text(authorName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(post.tint.opacity(0.95))
                Text(post.text)
                    .font(.system(size: 16))
                    .foregroundStyle(.black.opacity(0.82))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(post.time)
                        .font(.system(size: 12))
                        .foregroundStyle(.black.opacity(0.46))
                    Spacer()
                    Button {} label: {
                        Image(systemName: "heart")
                    }
                    Button {} label: {
                        Image(systemName: "bubble.right")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.91, green: 0.42, blue: 0.61))
            }
            .textShadowForPhotoBackground()
        }
        .padding(.vertical, 17)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.10))
                .frame(height: 0.5)
                .padding(.leading, 56)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if post.mine {
            MyAvatar(size: 44)
        } else if let conversation {
            AIConversationAvatar(conversation: conversation, size: 44)
        } else if post.contactHint == "claude" {
            ContactAvatar(kind: .claude, size: 44)
        } else {
            ZStack {
                Circle()
                    .fill(post.tint.opacity(0.22))
                Image(systemName: post.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(post.tint)
            }
            .frame(width: 44, height: 44)
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.7)
            )
        }
    }
}

private extension View {
    func textShadowForPhotoBackground() -> some View {
        shadow(color: .white.opacity(0.82), radius: 1.4, x: 0, y: 0.6)
    }
}

private struct MomentBackgroundChoice: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("momentsBgVersion") private var momentsBgVersion = 0
    @State private var photo: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 14) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("从相册选择背景", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .modifier(Glass(shape: Capsule()))
                    }
                    .buttonStyle(.plain)

                    Button {
                        try? FileManager.default.removeItem(at: SettingsView.momentsBgPath)
                        momentsBgVersion = 0
                        dismiss()
                    } label: {
                        Label("恢复默认背景", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(15)
                            .modifier(Glass(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .navigationTitle("朋友圈背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        try downscale(image, maxSide: 2200).write(to: SettingsView.momentsBgPath)
                        momentsBgVersion += 1
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .alert("背景保存失败", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }
}

struct MomentComposer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onPublish: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                TextEditor(text: $text)
                    .font(.system(size: 17))
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
                    .padding(16)
            }
            .navigationTitle("发朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        onPublish(value)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// ===== 「我」的主页 =====
struct MeView: View {
    @State private var nickname = UserDefaults.standard.string(forKey: "myNickname") ?? "我"
    @State private var signature = UserDefaults.standard.string(forKey: "mySignature") ?? "今天也要好好生活"
    @AppStorage("avatarVersion") private var avatarVersion = 0
    @AppStorage("momentsBgVersion") private var momentsBackgroundVersion = 0
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var pendingAvatarImage: UIImage?
    @State private var showingAvatarCrop = false
    @State private var showingMomentsBackgroundPicker = false
    @State private var profileSaveTask: Task<Void, Never>?
    @ObservedObject private var avatars = Avatars.shared

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()

                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 11) {
                            PhotosPicker(selection: $avatarPhoto, matching: .images) {
                                ZStack(alignment: .bottomTrailing) {
                                    MyAvatar(size: 96)
                                        .id(avatarVersion)
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 29, height: 29)
                                        .background(Color.pink, in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.78), lineWidth: 2))
                                }
                            }
                            .buttonStyle(.plain)

                            Text(nickname.isEmpty ? "我" : nickname)
                                .font(.system(size: 27, weight: .bold))
                            Text(signature.isEmpty ? "还没有填写签名" : signature)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text("昵称")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                TextField("填写昵称", text: $nickname)
                                    .fontWeight(.medium)
                                    .multilineTextAlignment(.trailing)
                                    .submitLabel(.done)
                            }
                            .padding(.vertical, 15)

                            Divider().opacity(0.24)

                            HStack(alignment: .top, spacing: 12) {
                                Text("签名")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                                Spacer(minLength: 12)
                                TextField("填写签名", text: $signature, axis: .vertical)
                                    .fontWeight(.medium)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(1...3)
                            }
                            .padding(.vertical, 15)
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, 16)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))

                        VStack(spacing: 0) {
                            NavigationLink { FavoritesView() } label: {
                                profileMenuRow("收藏", systemImage: "star")
                            }.buttonStyle(.plain)
                            Divider().opacity(0.24)
                            NavigationLink { SharedAlbumsView() } label: {
                                profileMenuRow("相册", systemImage: "photo.stack")
                            }.buttonStyle(.plain)
                            Divider().opacity(0.24)
                            NavigationLink { ThemeSettingsView() } label: {
                                profileMenuRow("主题", systemImage: "paintpalette")
                            }
                            .buttonStyle(.plain)

                            Divider().opacity(0.24)

                            NavigationLink {
                                SettingsView()
                            } label: {
                                profileMenuRow("设置", systemImage: "gearshape.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 17)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: avatarPhoto) { _, item in
                loadAvatarForCropping(item)
            }
            .onChange(of: nickname) { _, _ in scheduleProfileSave() }
            .onChange(of: signature) { _, _ in scheduleProfileSave() }
            .onDisappear {
                profileSaveTask?.cancel()
                saveProfileImmediately()
            }
            .fullScreenCover(isPresented: $showingAvatarCrop) {
                if let pendingAvatarImage {
                    AvatarCropView(image: pendingAvatarImage) { cropped in
                        saveAvatar(cropped)
                    }
                }
            }
            .sheet(isPresented: $showingMomentsBackgroundPicker) {
                NativeMomentsBackgroundPicker(backgroundVersion: $momentsBackgroundVersion)
                    .presentationDetents([.height(270)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func profileMenuRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
    }

    private func scheduleProfileSave() {
        profileSaveTask?.cancel()
        let pendingNickname = nickname
        let pendingSignature = signature
        profileSaveTask = Task {
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(pendingNickname, forKey: "myNickname")
            UserDefaults.standard.set(pendingSignature, forKey: "mySignature")
        }
    }

    private func saveProfileImmediately() {
        UserDefaults.standard.set(nickname, forKey: "myNickname")
        UserDefaults.standard.set(signature, forKey: "mySignature")
    }

    private func loadAvatarForCropping(_ item: PhotosPickerItem?) {
        guard let item else { return }
        avatarPhoto = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                pendingAvatarImage = image
                showingAvatarCrop = true
            }
        }
    }

    private func saveAvatar(_ image: UIImage) {
        let jpg = downscale(image, maxSide: 800)
        try? jpg.write(to: SettingsView.avatarPath)
        avatars.me = image
        avatarVersion += 1
        pendingAvatarImage = nil
    }
}

private struct AvatarCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    let onSave: (UIImage) -> Void
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var cropSide: CGFloat = 320

    init(image: UIImage, onSave: @escaping (UIImage) -> Void) {
        self.image = Self.normalized(image)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 22) {
                    Spacer(minLength: 20)
                    GeometryReader { geo in
                        let side = min(geo.size.width - 32, 380)
                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: side, height: side)
                                .scaleEffect(zoom)
                                .offset(offset)
                                .clipShape(Circle())
                                .gesture(dragGesture)
                                .simultaneousGesture(magnifyGesture)

                            Circle()
                                .strokeBorder(.white.opacity(0.88), lineWidth: 2)
                                .frame(width: side, height: side)
                                .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { cropSide = side }
                        .onChange(of: side) { _, value in cropSide = value }
                    }
                    .aspectRatio(1, contentMode: .fit)

                    VStack(spacing: 7) {
                        Text("移动和缩放照片")
                            .font(.system(size: 17, weight: .semibold))
                        Text("圆框内的部分会作为头像")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)

                    Spacer(minLength: 26)
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("裁剪头像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(croppedImage())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(.pink)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(
                        width: settledOffset.width + value.translation.width,
                        height: settledOffset.height + value.translation.height
                    ),
                    zoom: zoom
                )
            }
            .onEnded { _ in
                settledOffset = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(settledZoom * value, 1), 5)
                offset = clampedOffset(offset, zoom: zoom)
            }
            .onEnded { _ in
                settledZoom = zoom
                offset = clampedOffset(offset, zoom: zoom)
                settledOffset = offset
            }
    }

    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat) -> CGSize {
        let baseScale = max(cropSide / image.size.width, cropSide / image.size.height)
        let renderedWidth = image.size.width * baseScale * zoom
        let renderedHeight = image.size.height * baseScale * zoom
        let limitX = max(0, (renderedWidth - cropSide) / 2)
        let limitY = max(0, (renderedHeight - cropSide) / 2)
        return CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }

    private func croppedImage() -> UIImage {
        guard let source = image.cgImage else { return image }
        let baseScale = max(cropSide / image.size.width, cropSide / image.size.height)
        let totalScale = baseScale * zoom
        let visibleSide = cropSide / totalScale
        let centerX = image.size.width / 2 - offset.width / totalScale
        let centerY = image.size.height / 2 - offset.height / totalScale
        let rect = CGRect(
            x: max(0, min(image.size.width - visibleSide, centerX - visibleSide / 2)),
            y: max(0, min(image.size.height - visibleSide, centerY - visibleSide / 2)),
            width: visibleSide,
            height: visibleSide
        ).integral
        guard let cropped = source.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    private static func normalized(_ source: UIImage) -> UIImage {
        guard source.imageOrientation != .up || source.scale != 1 else { return source }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }
}

private struct MCPServerEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
}

private struct SkillEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    var sourceName: String?
    var enabled = true
}

@MainActor
private final class CapabilityConfigStore: ObservableObject {
    static let shared = CapabilityConfigStore()
    @Published var mcpServers: [MCPServerEntry] = [] { didSet { persistMCP() } }
    @Published var skills: [SkillEntry] = [] { didSet { persistSkills() } }

    private let mcpKey = "bearDen.mcpServers"
    private let skillKey = "bearDen.skills"

    private init() {
        if let data = UserDefaults.standard.data(forKey: mcpKey),
           let values = try? JSONDecoder().decode([MCPServerEntry].self, from: data) {
            mcpServers = values
        }
        if let data = UserDefaults.standard.data(forKey: skillKey),
           let values = try? JSONDecoder().decode([SkillEntry].self, from: data) {
            skills = values
        }
    }

    private func persistMCP() {
        if let data = try? JSONEncoder().encode(mcpServers) {
            UserDefaults.standard.set(data, forKey: mcpKey)
        }
    }

    private func persistSkills() {
        if let data = try? JSONEncoder().encode(skills) {
            UserDefaults.standard.set(data, forKey: skillKey)
        }
    }
}

private struct MCPManagementView: View {
    @ObservedObject private var store = CapabilityConfigStore.shared
    @State private var showingAdd = false

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.mcpServers.isEmpty {
                        ContentUnavailableView(
                            "还没有 MCP",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("添加名称和服务网址后会出现在这里")
                        )
                        .padding(.top, 100)
                    } else {
                        ForEach($store.mcpServers) { $server in
                            HStack(spacing: 12) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.pink)
                                    .frame(width: 42, height: 42)
                                    .background(Color.pink.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(server.url)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Toggle("", isOn: $server.enabled)
                                    .labelsHidden()
                                    .tint(.pink)
                                Button(role: .destructive) {
                                    store.mcpServers.removeAll { $0.id == server.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                        }
                    }

                    Text("开关变化会保存到本机；助手同步配置后，会在下一次会话启动时生效。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("MCP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddMCPView { entry in
                store.mcpServers.append(entry)
            }
        }
    }
}

private struct AddMCPView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    let onAdd: (MCPServerEntry) -> Void

    private var normalizedAddress: String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        return raw.isEmpty ? "" : "https://\(raw)"
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        URL(string: normalizedAddress)?.host != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("名称").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        TextField("例如：大富翁", text: $name)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                        Text("服务网址").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 5)
                        TextField("spicy-monopoly.lol/mcp", text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .padding(15)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("添加 MCP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(MCPServerEntry(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: normalizedAddress
                        ))
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}

private struct SkillManagementView: View {
    @ObservedObject private var store = CapabilityConfigStore.shared
    @State private var showingAdd = false

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if store.skills.isEmpty {
                        ContentUnavailableView(
                            "还没有 Skill",
                            systemImage: "wand.and.stars",
                            description: Text("可以上传文本文件，也可以直接粘贴内容")
                        )
                        .padding(.top, 100)
                    } else {
                        ForEach($store.skills) { $skill in
                            HStack(spacing: 12) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.purple)
                                    .frame(width: 42, height: 42)
                                    .background(Color.purple.opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(skill.name)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(skill.sourceName ?? "\(skill.content.count) 个字符")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Toggle("", isOn: $skill.enabled)
                                    .labelsHidden()
                                    .tint(.pink)
                                Button(role: .destructive) {
                                    store.skills.removeAll { $0.id == skill.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(14)
                            .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                        }
                    }

                    Text("关闭后助手将看不到对应 Skill；重新打开会在下一次会话启动时生效。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSkillView { entry in
                store.skills.append(entry)
            }
        }
    }
}

private struct AddSkillView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    @State private var sourceName: String?
    @State private var showingImporter = false
    @State private var importError: String?
    let onAdd: (SkillEntry) -> Void

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        Button {
                            showingImporter = true
                        } label: {
                            Label(sourceName ?? "上传 Skill 文件", systemImage: "doc.badge.plus")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .modifier(Glass(shape: Capsule()))
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 9) {
                            Text("名称").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            TextField("Skill 名称", text: $name)
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                            Text("内容").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.top, 5)
                            TextEditor(text: $content)
                                .font(.system(size: 15))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 230)
                                .padding(10)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }
                        .padding(15)
                        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("添加 Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(SkillEntry(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            content: content,
                            sourceName: sourceName
                        ))
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                importSkill(result)
            }
            .alert("文件读取失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func importSkill(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let value = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "熊窝", code: 1, userInfo: [NSLocalizedDescriptionKey: "这个文件不是 UTF-8 文本。"])
            }
            sourceName = url.lastPathComponent
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            content = value
        } catch {
            importError = error.localizedDescription
        }
    }
}

// ===== 设置页 =====
struct SettingsView: View {
    @AppStorage("homeBgVersion") private var homeBgVersion = 0
    @AppStorage("appearanceMode") private var appearanceMode = "light"
    @AppStorage(ChatBubbleStyle.storageKey) private var bubbleStyle = ChatBubbleStyle.glass.rawValue
    @AppStorage("myNickname") private var myNickname = "我"
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("serverBaseURL") private var serverBaseURL = ""
    @State private var backgroundPhoto: PhotosPickerItem?
    @State private var backgroundPreview: UIImage?
    @State private var myAvatarPhoto: PhotosPickerItem?
    @State private var assistantAvatarPhoto: PhotosPickerItem?
    @ObservedObject private var avatars = Avatars.shared

    static var bgPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-bg.jpg")
    }

    static var homeBgPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("home-bg.jpg")
    }

    static var momentsBgPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("moments-bg.jpg")
    }

    static var avatarPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("my-avatar.jpg")
    }

    static var assistantAvatarPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("assistant-avatar.jpg")
    }

    var body: some View {
        ZStack {
            AppBackdrop()

            ScrollView {
                VStack(spacing: 14) {
                    serverCard
                    capabilityCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onDisappear { normalizeServerAddress() }
        .onChange(of: myAvatarPhoto) { _, item in
            saveAvatarPhoto(item, assistant: false)
        }
        .onChange(of: assistantAvatarPhoto) { _, item in
            saveAvatarPhoto(item, assistant: true)
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("服务器地址")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("例如 https://example.com", text: $serverBaseURL)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .onSubmit { normalizeServerAddress() }

            Text("留空则仅用本机功能，填你自己部署的服务器地址。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private func normalizeServerAddress() {
        serverBaseURL = ServerConfig.cleaned
    }

    private func saveAvatarPhoto(_ item: PhotosPickerItem?, assistant: Bool) {
        guard let item else { return }
        if assistant { assistantAvatarPhoto = nil } else { myAvatarPhoto = nil }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            let jpg = downscale(image, maxSide: 800)
            let path = assistant ? Self.assistantAvatarPath : Self.avatarPath
            try? jpg.write(to: path, options: .atomic)
            await MainActor.run {
                if assistant { avatars.assistant = image } else { avatars.me = image }
            }
        }
    }

    private func removeMyAvatar() {
        try? FileManager.default.removeItem(at: Self.avatarPath)
        avatars.me = nil
    }

    private func removeAssistantAvatar() {
        try? FileManager.default.removeItem(at: Self.assistantAvatarPath)
        avatars.assistant = nil
    }

    private var capabilityCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                MCPManagementView()
            } label: {
                settingsLine(icon: "point.3.connected.trianglepath.dotted", title: "MCP 服务", detail: "")
            }
            .buttonStyle(.plain)

            Divider().opacity(0.24)

            NavigationLink {
                SkillManagementView()
            } label: {
                settingsLine(icon: "wand.and.stars", title: "Skills", detail: "")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private func settingsLine(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 16, weight: .medium))
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
    }

}

/// Theme page: bubble style, colors and font, plus home, chat and moments backgrounds.
struct ThemeSettingsView: View {
    @AppStorage("homeBgVersion") private var homeBgVersion = 0
    @AppStorage("appearanceMode") private var appearanceMode = "light"
    @AppStorage("momentsBgVersion") private var momentsBackgroundVersion = 0
    @AppStorage(ChatBubbleStyle.storageKey) private var bubbleStyle = ChatBubbleStyle.glass.rawValue
    @AppStorage(ChatFontChoice.storageKey) private var fontChoice = ChatFontChoice.system.rawValue
    @State private var backgroundPhoto: PhotosPickerItem?
    @State private var backgroundPreview: UIImage?
    @State private var showingChatBackground = false
    @State private var showingMomentsBackground = false

    private var currentStyle: ChatBubbleStyle { ChatBubbleStyle(rawValue: bubbleStyle) ?? .glass }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                VStack(spacing: 14) {
                    bubbleCard
                    fontCard
                    appearanceCard
                    backgroundCard
                    otherBackgroundsCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 110)
            }
        }
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { loadPreview() }
        .onChange(of: backgroundPhoto) { _, item in saveHomeBackground(item) }
        .sheet(isPresented: $showingChatBackground) {
            ChatBackgroundChoice()
                .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showingMomentsBackground) {
            NativeMomentsBackgroundPicker(backgroundVersion: $momentsBackgroundVersion)
                .presentationDetents([.height(270)])
                .presentationDragIndicator(.visible)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var bubbleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("气泡样式")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ChatBubbleStyle.allCases, id: \.rawValue) { style in
                    Button {
                        bubbleStyle = style.rawValue
                    } label: {
                        Text(style.title)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                currentStyle == style ? Color.pink.opacity(0.18) : Color.white.opacity(0.10),
                                in: Capsule()
                            )
                            .overlay(Capsule().strokeBorder(currentStyle == style ? Color.pink.opacity(0.55) : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            bubblePreview

            if currentStyle.supportsColor {
                Divider().opacity(0.24)
                BubbleColorRow(title: "我的气泡", style: currentStyle, mine: true)
                BubbleColorRow(title: "对方气泡", style: currentStyle, mine: false)
            }
        }
        .padding(15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private var bubblePreview: some View {
        VStack(spacing: 10) {
            HStack {
                Text("今天也想你")
                    .font(ChatFontChoice(rawValue: fontChoice)?.swiftUIFont ?? .body)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(ChatTextBubbleBackground(mine: false))
                Spacer()
            }
            HStack {
                Spacer()
                Text("我也是")
                    .font(ChatFontChoice(rawValue: fontChoice)?.swiftUIFont ?? .body)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .modifier(ChatTextBubbleBackground(mine: true))
            }
        }
        .id(bubbleStyle + fontChoice)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fontCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("聊天字体")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ChatFontChoice.allCases, id: \.rawValue) { choice in
                    Button {
                        fontChoice = choice.rawValue
                    } label: {
                        VStack(spacing: 2) {
                            Text("Aa 字").font(choice.swiftUIFont)
                            Text(choice.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            fontChoice == choice.rawValue ? Color.pink.opacity(0.18) : Color.white.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("中文字符在部分字体下会使用系统字形。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("外观")
            Picker("外观", selection: $appearanceMode) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
        }
        .padding(15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private var otherBackgroundsCard: some View {
        VStack(spacing: 0) {
            Button { showingChatBackground = true } label: {
                themeLine(icon: "bubble.left.and.bubble.right", title: "聊天背景")
            }
            .buttonStyle(.plain)
            Divider().opacity(0.24)
            Button { showingMomentsBackground = true } label: {
                themeLine(icon: "photo.on.rectangle.angled", title: "朋友圈背景")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private func themeLine(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 24)
            Text(title).font(.system(size: 16, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主页背景")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            if let backgroundPreview {
                Image(uiImage: backgroundPreview)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 142)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.7)
                    )
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $backgroundPhoto, matching: .images) {
                    Label("选择背景", systemImage: "photo.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    try? FileManager.default.removeItem(at: SettingsView.homeBgPath)
                    backgroundPreview = nil
                    homeBgVersion = 0
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private func loadPreview() {
        backgroundPreview = homeBgVersion > 0 ? UIImage(contentsOfFile: SettingsView.homeBgPath.path) : nil
    }

    private func saveHomeBackground(_ item: PhotosPickerItem?) {
        guard let item else { return }
        backgroundPhoto = nil
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                let jpg = downscale(image, maxSide: 1600)
                try? jpg.write(to: SettingsView.homeBgPath, options: .atomic)
                let preview = UIImage(data: jpg)
                await MainActor.run {
                    backgroundPreview = preview
                    homeBgVersion += 1
                    if let preview {
                        AppBackdropImageCache.store(preview, version: homeBgVersion)
                    }
                }
            }
        }
    }
}

/// Preset swatches plus a free color picker for one side of a bubble style.
private struct BubbleColorRow: View {
    let title: String
    let style: ChatBubbleStyle
    let mine: Bool
    @AppStorage private var hex: String

    init(title: String, style: ChatBubbleStyle, mine: Bool) {
        self.title = title
        self.style = style
        self.mine = mine
        _hex = AppStorage(wrappedValue: ChatBubblePalette.defaultHex(style, mine: mine),
                          ChatBubblePalette.key(style, mine: mine))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium))
            HStack(spacing: 8) {
                ForEach(ChatBubblePalette.presets(style), id: \.self) { preset in
                    Button { hex = preset } label: {
                        Circle()
                            .fill(Color(hexString: preset) ?? .white)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                            .overlay(Circle().strokeBorder(hex.uppercased() == preset ? Color.pink : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                ColorPicker("", selection: Binding(
                    get: { Color(hexString: hex) ?? .white },
                    set: { hex = $0.hexString }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
    }
}

struct RemarkSettingsView: View {
    @AppStorage("assistantRemark") private var assistantRemark = "助手"

    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("助手备注")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("输入备注", text: $assistantRemark)
                        .font(.system(size: 17))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .padding(15)
                .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))

                Text("会同步显示在对话列表、聊天标题和通讯录中")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
        }
        .navigationTitle("修改备注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct AboutView: View {
    var body: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 16) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.pink)
                    .frame(width: 104, height: 104)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))

                Text("熊窝")
                    .font(.system(size: 26, weight: .bold))
                Text("透明 Liquid Glass 聊天客户端")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    aboutLine("版本", value: "0.8.9")
                    Divider().opacity(0.24)
                    aboutLine("界面", value: "SwiftUI")
                }
                .padding(.horizontal, 16)
                .modifier(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
                .padding(.top, 10)
            }
            .padding(.horizontal, 24)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func aboutLine(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 15))
        .padding(.vertical, 15)
    }
}

// 图片统一转 JPEG 并限制最长边，减小上传体积
private func downscale(_ img: UIImage, maxSide: CGFloat) -> Data {
    let s = img.size
    let long = max(s.width, s.height)
    if long <= maxSide, let d = img.jpegData(compressionQuality: 0.85) { return d }
    let k = maxSide / long
    let size = CGSize(width: floor(s.width * k), height: floor(s.height * k))
    let out = UIGraphicsImageRenderer(size: size).image { _ in
        img.draw(in: CGRect(origin: .zero, size: size))
    }
    return out.jpegData(compressionQuality: 0.85) ?? Data()
}


// ===== 头像：从服务器 /api/profile 读，圆角方块 =====
final class Avatars: ObservableObject {
    static let shared = Avatars()
    @Published var dog: UIImage?
    @Published var me: UIImage?
    /// 本机设置的 AI 助手头像（设置页可改）；没有设置时回落到服务器头像。
    @Published var assistant: UIImage?

    init() {
        me = UIImage(contentsOfFile: SettingsView.avatarPath.path)
        assistant = UIImage(contentsOfFile: SettingsView.assistantAvatarPath.path)

        Task { @MainActor in
            guard let base = API.base,
                  let (d, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("api/profile")),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let dogF = ((j["contacts"] as? [String: Any])?["dog"] as? [String: Any])?["avatar"] as? String
            let meF = (j["me"] as? [String: Any])?["avatar"] as? String
            if let f = dogF { self.dog = await Self.load(f) }
            if self.me == nil, let f = meF { self.me = await Self.load(f) }
        }
    }
    static func load(_ f: String) async -> UIImage? {
        guard let (d, _) = try? await URLSession.shared.data(from: API.fileURL(f)), let img = UIImage(data: d) else { return nil }
        let side: CGFloat = 120
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return r.image { _ in
            let sc = max(side / img.size.width, side / img.size.height)
            let w = img.size.width * sc, h = img.size.height * sc
            img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
    }
}

struct MyAvatar: View {
    let size: CGFloat
    @ObservedObject private var avatars = Avatars.shared

    var body: some View {
        Group {
            if let image = avatars.me {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.pink.opacity(0.78), .purple.opacity(0.56)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.09), radius: 4, y: 2)
    }
}

/// Peer of a device-local AI conversation shown in the shared chat view; nil for the mailbox peer.
private struct ChatPeerConversationKey: EnvironmentKey {
    static let defaultValue: AIConversation? = nil
}

extension EnvironmentValues {
    var chatPeerConversation: AIConversation? {
        get { self[ChatPeerConversationKey.self] }
        set { self[ChatPeerConversationKey.self] = newValue }
    }
}

struct Avatar: View {
    let isMe: Bool
    @ObservedObject private var store = Avatars.shared
    @Environment(\.chatPeerConversation) private var peer
    var body: some View {
        if !isMe, let peer {
            AIConversationAvatar(conversation: peer, size: 36)
        } else {
            mailboxAvatar
        }
    }

    private var mailboxAvatar: some View {
        let img = isMe ? store.me : store.dog
        return Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.4)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
    }
}


// ===== 气泡专用：实心底（见下面的 BubbleGlass）；玻璃只留顶栏和输入栏 =====
// Message-only surface: solid fill, no live blur. Unused at the moment;
// kept for reference next to BubbleGlass.
struct MessageGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(uiColor: .systemBackground))
                } else {
                    // 毛玻璃换成普通半透明：系统玻璃每帧都要重采样背景，
                    // 长消息一多就拖慢主线程；纯色半透明不用实时模糊。
                    shape.fill(Color(uiColor: .systemBackground).opacity(0.72))
                }
            }
            .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 0.85))
            .shadow(color: .black.opacity(0.065), radius: 8, y: 3)
    }
}

extension View {
    @ViewBuilder
    func transparentTopScrollEdge() -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
#else
        self
#endif
    }
}

// 消息气泡用实心底：iMessage 那样不透背景、不实时模糊，
// 满屏气泡也不用每帧重采样；玻璃只留给顶栏和输入栏（用 Glass）。
struct BubbleGlass<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(Color(uiColor: .systemBackground))
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.06), radius: 9, y: 3)
    }
}

enum ChatBubbleStyle: String, CaseIterable {
    case glass, droplet, clay, nativeGlass, none
    static let storageKey = "chatBubbleStyle"
    var title: String {
        switch self {
        case .glass: return "玻璃"
        case .droplet: return "水珠"
        case .clay: return "黏土"
        case .nativeGlass: return "原生玻璃"
        case .none: return "无气泡"
        }
    }
    /// Styles whose tint can be chosen per side.
    var supportsColor: Bool { self == .droplet || self == .clay }
}

/// Per-style, per-side bubble tint stored as a hex string.
enum ChatBubblePalette {
    static func key(_ style: ChatBubbleStyle, mine: Bool) -> String {
        "chatBubbleColor.\(style.rawValue).\(mine ? "mine" : "peer")"
    }

    struct Preset {
        let name: String
        /// Solid clay fill.
        let clay: String
        /// Droplet top / middle / bottom tints (used at 58% opacity).
        let droplet: (String, String, String)
    }

    /// Pale macaron palette shared by the droplet and clay styles.
    static let palette: [Preset] = [
        Preset(name: "奶油黄", clay: "F9F0C8", droplet: ("F4F3E1", "FAF8E2", "F6F1D5")),
        Preset(name: "樱花粉", clay: "F4C9E3", droplet: ("F3EAF2", "F7EDF5", "F4E1EE")),
        Preset(name: "雾蓝", clay: "DCE8FC", droplet: ("E6ECF4", "EAF1F9", "DCE7F5")),
        Preset(name: "浅薰衣草", clay: "E6DCF5", droplet: ("E8E7F1", "EFEAF9", "E6E0F5")),
        Preset(name: "薄荷绿", clay: "E1F3DD", droplet: ("E1F0EC", "E4F7F1", "D3EFE5")),
        Preset(name: "蜜桃杏", clay: "FADDC8", droplet: ("F5ECE4", "FAF0E8", "F7E2D4"))
    ]

    static func presetHex(_ p: Preset, _ style: ChatBubbleStyle) -> String {
        style == .clay ? p.clay : p.droplet.1
    }

    static func defaultHex(_ style: ChatBubbleStyle, mine: Bool) -> String {
        presetHex(palette[mine ? 1 : 2], style)
    }

    static func presets(_ style: ChatBubbleStyle) -> [String] {
        palette.map { presetHex($0, style) }
    }

    /// Droplet gradient stops for a stored hex: the preset triple when it matches,
    /// otherwise a triple derived from the chosen color.
    static func dropletStops(_ hex: String) -> (Color, Color, Color) {
        let h = hex.uppercased()
        if let p = palette.first(where: { $0.droplet.1 == h }) {
            return (Color(hexString: p.droplet.0) ?? .white, Color(hexString: p.droplet.1) ?? .white, Color(hexString: p.droplet.2) ?? .white)
        }
        let mid = Color(hexString: h) ?? .white
        return (mid.deepened(0.015), mid, mid.deepened(0.03))
    }

    static func color(_ style: ChatBubbleStyle, mine: Bool) -> Color {
        let raw = UserDefaults.standard.string(forKey: key(style, mine: mine)) ?? defaultHex(style, mine: mine)
        return Color(hexString: raw) ?? Color(hexString: defaultHex(style, mine: mine)) ?? .white
    }
}

extension Color {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Same hue, more saturated and darker; used for clay bases and droplet shadows.
    func deepened(_ amount: CGFloat = 0.16) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(s * 1.35 + 0.08, 1)), brightness: Double(max(v - amount, 0)))
    }
}

/// Chat text font choice, applied to message text.
enum ChatFontChoice: String, CaseIterable {
    case system, rounded, serif, monospaced, chalkboard, noteworthy, avenir
    static let storageKey = "chatFontChoice"

    var title: String {
        switch self {
        case .system: return "系统"
        case .rounded: return "圆体"
        case .serif: return "衬线"
        case .monospaced: return "等宽"
        case .chalkboard: return "粉笔"
        case .noteworthy: return "手写"
        case .avenir: return "Avenir"
        }
    }

    static var current: ChatFontChoice {
        ChatFontChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    func uiFont(size: CGFloat, bold: Bool = false) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        func designed(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
            guard let d = base.fontDescriptor.withDesign(design) else { return base }
            return UIFont(descriptor: d, size: size)
        }
        func named(_ regular: String, _ boldName: String) -> UIFont {
            UIFont(name: bold ? boldName : regular, size: size) ?? base
        }
        switch self {
        case .system: return base
        case .rounded: return designed(.rounded)
        case .serif: return designed(.serif)
        case .monospaced: return designed(.monospaced)
        case .chalkboard: return named("ChalkboardSE-Regular", "ChalkboardSE-Bold")
        case .noteworthy: return named("Noteworthy-Light", "Noteworthy-Bold")
        case .avenir: return named("AvenirNext-Regular", "AvenirNext-Bold")
        }
    }

    var swiftUIFont: Font { Font(uiFont(size: 16)) }
}

/// Small crescent highlight of the droplet bubble: the top border of a 17x10 box with
/// asymmetric rounded top corners, rotated -26 degrees.
private struct DropletHighlight: View {
    var body: some View {
        Path { p in
            // Corner radii 65%/50% scaled to fit (CSS radius clamping).
            let k: CGFloat = 17 / 19.5
            let lx = 11.05 * k, ly = 6.5 * k, rx = 8.5 * k, ry = 5 * k
            p.move(to: CGPoint(x: 0, y: ly))
            p.addQuadCurve(to: CGPoint(x: lx, y: 0), control: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 17 - rx, y: 0))
            p.addQuadCurve(to: CGPoint(x: 17, y: ry), control: CGPoint(x: 17, y: 0))
        }
        .stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .frame(width: 17, height: 10)
        .rotationEffect(.degrees(-26))
        .blur(radius: 0.25)
        .allowsHitTesting(false)
    }
}

/// CSS-style inset box-shadow: a blurred band outside the (spread-adjusted) shape,
/// offset, then masked to the shape.
struct BubbleInsetShadow<S: InsettableShape>: View {
    let shape: S
    let color: Color
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// CSS blur length; SwiftUI blur radius is half of it.
    var blur: CGFloat = 0
    var spread: CGFloat = 0

    var body: some View {
        let band: CGFloat = 40
        shape
            .inset(by: spread - band / 2)
            .stroke(color, lineWidth: band)
            .offset(x: x, y: y)
            .blur(radius: blur / 2)
            .mask(shape)
    }
}

/// Text bubble background. Custom variants are flat fills, gradients and shadows only
/// (no materials or live blur) so they stay cheap in a scrolling list; the native glass
/// variant uses the system glass effect.
struct ChatTextBubbleBackground: ViewModifier {
    let mine: Bool
    @AppStorage(ChatBubbleStyle.storageKey) private var styleRaw = ChatBubbleStyle.glass.rawValue
    @AppStorage private var dropletHex: String
    @AppStorage private var clayHex: String

    init(mine: Bool) {
        self.mine = mine
        _dropletHex = AppStorage(wrappedValue: ChatBubblePalette.defaultHex(.droplet, mine: mine),
                                 ChatBubblePalette.key(.droplet, mine: mine))
        _clayHex = AppStorage(wrappedValue: ChatBubblePalette.defaultHex(.clay, mine: mine),
                              ChatBubblePalette.key(.clay, mine: mine))
    }

    private var style: ChatBubbleStyle { ChatBubbleStyle(rawValue: styleRaw) ?? .glass }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content
                .environment(\.colorScheme, .light)
                .background { shape.fill(Color.white.opacity(0.6)) }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                }
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
        case .droplet:
            let stops = ChatBubblePalette.dropletStops(dropletHex)
            let capsule = Capsule(style: .continuous)
            content
                .environment(\.colorScheme, .light)
                .background {
                    ZStack {
                        capsule.fill(LinearGradient(
                            stops: [.init(color: stops.0.opacity(0.58), location: 0),
                                    .init(color: stops.1.opacity(0.58), location: 0.46),
                                    .init(color: stops.2.opacity(0.58), location: 1)],
                            startPoint: .top, endPoint: .bottom))
                        capsule.fill(LinearGradient(
                            stops: [.init(color: Color(red: 215/255, green: 214/255, blue: 220/255).opacity(0.12), location: 0),
                                    .init(color: Color.white.opacity(0.075), location: 0.30),
                                    .init(color: Color.white.opacity(0.025), location: 0.60),
                                    .init(color: Color(red: 205/255, green: 205/255, blue: 209/255).opacity(0.045), location: 1)],
                            startPoint: .top, endPoint: .bottom))
                    }
                }
                .overlay {
                    ZStack {
                        BubbleInsetShadow(shape: capsule, color: Color(red: 83/255, green: 79/255, blue: 91/255).opacity(0.20), x: 0, y: 5, blur: 8, spread: -5)
                        BubbleInsetShadow(shape: capsule, color: Color.white.opacity(0.20), x: 0, y: 2, blur: 3)
                        BubbleInsetShadow(shape: capsule, color: Color(red: 90/255, green: 86/255, blue: 95/255).opacity(0.055), x: 0, y: -1, blur: 2)
                        BubbleInsetShadow(shape: capsule, color: Color.white.opacity(0.28), x: 0, y: 1, blur: 1)
                    }
                    .allowsHitTesting(false)
                }
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    DropletHighlight()
                        .scaleEffect(x: mine ? 1 : -1, y: 1)
                        .padding(mine ? .leading : .trailing, 10)
                        .padding(.top, 5)
                }
                .compositingGroup()
                .shadow(color: Color(red: 65/255, green: 62/255, blue: 70/255).opacity(0.18), radius: 1, y: 2)
                .shadow(color: Color(red: 65/255, green: 62/255, blue: 70/255).opacity(0.065), radius: 2.5, y: 4)
        case .clay:
            let fill = Color(hexString: clayHex) ?? .white
            let rounded = RoundedRectangle(cornerRadius: 30, style: .continuous)
            content
                .environment(\.colorScheme, .light)
                .background { rounded.fill(fill) }
                .overlay {
                    ZStack {
                        BubbleInsetShadow(shape: rounded, color: Color.black.opacity(0.12), x: -8, y: -8, blur: 16)
                        BubbleInsetShadow(shape: rounded, color: Color.white.opacity(0.6), x: 8, y: 8, blur: 16)
                    }
                    .allowsHitTesting(false)
                }
                .compositingGroup()
                .shadow(color: Color(red: 90/255, green: 60/255, blue: 120/255).opacity(0.18), radius: 12, x: 10, y: 14)
        case .nativeGlass:
            // Message-app proportions: 18pt continuous corners, light side tint, no tail.
            let tint = (Color(hexString: dropletHex) ?? .white).opacity(0.22)
            content
                .modifier(TintedNativeGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint))
                .environment(\.colorScheme, .light)
        case .none:
            content
                .shadow(color: Color.black.opacity(0.35), radius: 1.5, y: 0.5)
        }
    }
}

/// Inner padding for text bubbles; the native glass style uses message-app metrics
/// (12pt horizontal, 8pt vertical, bubble capped at 75% of the screen width).
struct ChatTextBubblePadding: ViewModifier {
    @AppStorage(ChatBubbleStyle.storageKey) private var styleRaw = ChatBubbleStyle.glass.rawValue

    func body(content: Content) -> some View {
        if ChatBubbleStyle(rawValue: styleRaw) == .nativeGlass {
            MaxWidthLayout(maxWidth: UIScreen.main.bounds.width * 0.75) {
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        } else {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
    }
}

/// Caps the width proposed to its single child without stretching it.
struct MaxWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Regular system glass lightly tinted; material fallback before iOS 26.
struct TintedNativeGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color

    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
#else
        content.background(.ultraThinMaterial, in: shape)
#endif
    }
}

/// The same light-scheme system glass the navigation bar uses for its buttons; shared by
/// the chat title capsule and the native-glass bubble style so they render identically.
struct ToolbarMatchedGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .modifier(NativeGlass(shape: shape))
            .environment(\.colorScheme, .light)
    }
}

/// System Liquid Glass on iOS 26; material fallback on earlier systems.
struct NativeGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
#else
        content.background(.ultraThinMaterial, in: shape)
#endif
    }
}

private extension View {
    @ViewBuilder
    func chatInitialBottomAnchor(followsSizeChanges: Bool = true) -> some View {
        if #available(iOS 18.0, *) {
            // One modifier chain for both states: switching branches would rebuild the
            // list and throw away its scroll position.
            self
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(followsSizeChanges ? .bottom : nil, for: .sizeChanges)
                .defaultScrollAnchor(.bottom, for: .alignment)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }
}

private struct VoicePressSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    final class Coordinator: NSObject {
        var parent: VoicePressSurface
        init(_ parent: VoicePressSurface) { self.parent = parent }
        @objc func tapped() { parent.onTap() }
        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: parent.onHoldStart()
            case .ended, .cancelled, .failed: parent.onHoldEnd()
            default: break
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 24
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
}

@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var isRecording = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var hasTap = false

    private func microphonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startTranscription(onUpdate: @escaping (String) -> Void) async throws {
        guard !isTranscribing else { return }
        guard await microphonePermission() else {
            throw VoiceIssue.permission("请在系统设置中允许熊窝使用麦克风。")
        }
        let speechPermission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechPermission == .authorized else {
            throw VoiceIssue.permission("请在系统设置中允许语音识别。")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            throw VoiceIssue.permission("当前无法使用语音转文字，请稍后重试。")
        }
        stopTranscription()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let input = engine.inputNode
        if hasTap { input.removeTap(onBus: 0); hasTap = false }
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        hasTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasTap = false
            self.request = nil
            throw error
        }
        isTranscribing = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isTranscribing else { return }
                if let result {
                    onUpdate(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.stopTranscription()
                }
            }
        }
    }

    func stopTranscription() {
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isTranscribing = false
        if !isRecording { try? AVAudioSession.sharedInstance().setActive(false) }
    }

    func startRecording(shouldStart: () -> Bool) async throws {
        guard await microphonePermission() else {
            throw VoiceIssue.permission("请在系统设置中允许熊窝使用麦克风。")
        }
        guard shouldStart() else { return }
        stopTranscription()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard shouldStart(), recorder.record() else { return }
        self.recorder = recorder
        recordingURL = url
        isRecording = true
    }

    /// Length of the clip returned by the last `finishRecording()`.
    private(set) var lastRecordingDuration: TimeInterval = 0

    func finishRecording() -> URL? {
        guard let recorder, let url = recordingURL else { return nil }
        let duration = recorder.currentTime
        lastRecordingDuration = duration
        recorder.stop()
        self.recorder = nil
        recordingURL = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        if duration < 0.35 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    enum VoiceIssue: LocalizedError {
        case permission(String)
        var errorDescription: String? {
            if case .permission(let message) = self { return message }
            return nil
        }
    }
}

struct VoiceMessagePlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        Button {
            if playing {
                player?.pause()
                playing = false
            } else {
                player?.pause()
                player = AVPlayer(url: url)
                player?.play()
                playing = true
            }
        } label: {
            Label(playing ? "暂停语音" : "播放语音", systemImage: playing ? "pause.fill" : "waveform")
                .font(.system(size: 16, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .modifier(BubbleGlass(shape: Capsule()))
        }
        .buttonStyle(.plain)
        .onDisappear { player?.pause() }
    }
}

private struct ChatDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var contactSync = BearContactProfileSync.shared
    let messages: [Msg]
    @Binding var isPinned: Bool
    @Binding var hiddenThroughID: Int
    let groupMembers: [AIConversation]
    let onCreateGroup: (AIConversation) -> Void
    let onJumpToMessage: (Int) -> Void

    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    @AppStorage("claudeMuted") private var isMuted = false
    @AppStorage("claudeReminderEnabled") private var reminderEnabled = false
    @State private var reminderDate = Date.now.addingTimeInterval(3600)
    @State private var showingSearch = false
    @State private var showingGroup = false
    @State private var showingBackground = false
    @State private var showingClearConfirmation = false
    @State private var showingRemarkEditor = false
    @State private var remarkDraft = ""
    @State private var notificationError: String?
    @State private var contentReady = false

    var body: some View {
        ZStack {
            AppBackdrop()
            if contentReady {
                ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        ContactAvatar(kind: .claude, size: 68)
                        if !contactSync.status.isEmpty {
                            Text(contactSync.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Button {
                            remarkDraft = assistantRemark
                            showingRemarkEditor = true
                        } label: {
                            HStack(spacing: 5) {
                                Text(assistantRemark)
                                    .font(.system(size: 14))
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            showingGroup = true
                        } label: {
                            Label("添加成员", systemImage: "person.badge.plus")
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .modifier(Glass(shape: Capsule()))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 25, style: .continuous)))

                    VStack(spacing: 0) {
                        detailsButton("查找聊天内容", icon: "magnifyingglass") { showingSearch = true }
                    }
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))

                    VStack(spacing: 0) {
                        ChatActivityPreference(conversationID: "claude")
                        Divider().opacity(0.24)
                        Toggle(isOn: $isMuted) {
                            Label("消息免打扰", systemImage: "bell.slash")
                        }
                        .padding(.vertical, 14)
                        Divider().opacity(0.24)
                        Toggle(isOn: $isPinned) {
                            Label("置顶聊天", systemImage: "pin")
                        }
                        .padding(.vertical, 14)
                        Divider().opacity(0.24)
                        Toggle(isOn: $reminderEnabled) {
                            Label("提醒", systemImage: "bell.badge")
                        }
                        .padding(.vertical, 14)
                        if reminderEnabled {
                            DatePicker("提醒时间", selection: $reminderDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 17)
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                    .onChange(of: reminderEnabled) { _, enabled in scheduleReminder(enabled) }
                    .onChange(of: reminderDate) { _, _ in
                        if reminderEnabled { scheduleReminder(true) }
                    }

                    detailsButton("设置当前聊天背景", icon: "photo.on.rectangle") {
                        showingBackground = true
                    }
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                    detailsButton("清空聊天记录", icon: "trash") {
                        showingClearConfirmation = true
                    }
                    .modifier(Glass(shape: RoundedRectangle(cornerRadius: 23, style: .continuous)))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard !contentReady else { return }
            // Mounting all live glass cards during the push animation blocks the main thread.
            try? await Task.sleep(for: .milliseconds(240))
            contentReady = true
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                ChatSearchView(messages: messages.filter { $0.id > hiddenThroughID }) { id in
                    showingSearch = false
                    onJumpToMessage(id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingGroup) {
            CreateGroupView(members: groupMembers) { conversation in
                onCreateGroup(conversation)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingBackground) {
            ChatBackgroundChoice()
                .presentationDetents([.medium])
        }
        .confirmationDialog("清空此设备上的聊天记录？", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                hiddenThroughID = messages.last?.id ?? hiddenThroughID
            }
        } message: {
            Text("会清空本机显示的历史消息，服务器上的记录不会删除。")
        }
        .alert("提醒", isPresented: Binding(
            get: { notificationError != nil },
            set: { if !$0 { notificationError = nil } }
        )) {
            Button("好") { notificationError = nil }
        } message: { Text(notificationError ?? "") }
        .alert("修改备注", isPresented: $showingRemarkEditor) {
            TextField("输入备注", text: $remarkDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let clean = remarkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { assistantRemark = clean }
            }
        } message: {
            Text("备注会同步显示在对话列表和聊天标题。")
        }
    }

    private func detailsButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 23)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 16))
            .padding(.horizontal, 17)
            .padding(.vertical, 17)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleReminder(_ enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["claude-chat-reminder"])
        guard enabled else { return }
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    reminderEnabled = false
                    notificationError = "请在系统设置中允许熊窝发送通知。"
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = assistantRemark
                content.body = "你设置的聊天提醒到了"
                content.sound = .default
                let interval = max(1, reminderDate.timeIntervalSinceNow)
                let request = UNNotificationRequest(
                    identifier: "claude-chat-reminder",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                )
                try await center.add(request)
            } catch {
                notificationError = "提醒设置失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct ChatSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("myNickname") private var myNickname = "我"
    @AppStorage("assistantRemark") private var assistantRemark = "助手"
    let messages: [Msg]
    let onSelect: (Int) -> Void
    @State private var query = ""

    private var matches: [Msg] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            List(matches) { message in
                Button {
                    onSelect(message.id)
                    dismiss()
                } label: {
                    ChatSearchResultRow(
                        sender: message.from == "me" ? (myNickname.isEmpty ? "我" : myNickname) : assistantRemark,
                        text: message.displayedText.isEmpty ? message.previewText : message.displayedText,
                        date: message.date
                    ) {
                        if message.from == "me" {
                            MyAvatar(size: 44)
                        } else {
                            ContactAvatar(kind: .claude, size: 44)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.opacity(0.64))
        }
        .searchable(text: $query, prompt: "搜索聊天内容")
        .navigationTitle("查找聊天内容")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
    }
}

// Shared by the server-backed and configured-AI searches so sender identity and
// contrast stay consistent, regardless of the app's pink button tint.
private struct ChatSearchResultRow<AvatarContent: View>: View {
    let sender: String
    let text: String
    let date: Date
    @ViewBuilder let avatar: () -> AvatarContent

    private static var dateFormat: Date.FormatStyle {
        .dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN"))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(sender).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        timestamp
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sender)
                        timestamp
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.8))

                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timestamp: some View {
        Text(date.formatted(Self.dateFormat))
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ChatBackgroundChoice: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bgVersion") private var bgVersion = 0
    @State private var photo: PhotosPickerItem?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackdrop()
                VStack(spacing: 18) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("从相册选择背景", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .modifier(Glass(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                    Button {
                        try? FileManager.default.removeItem(at: SettingsView.bgPath)
                        bgVersion = 0
                        dismiss()
                    } label: {
                        Label("恢复默认背景", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .modifier(Glass(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("聊天背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        try downscale(image, maxSide: 2000).write(to: SettingsView.bgPath)
                        bgVersion += 1
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .alert("背景保存失败", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}







