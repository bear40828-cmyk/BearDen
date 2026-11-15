import SwiftUI

struct ChatToolStep: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var status: String
    var elapsedMS: Double? = nil
    var detail: String? = nil
}

/// One row of the ordered process timeline returned by the server.
struct ChatTimelineStep: Codable, Equatable, Sendable {
    var type: String                 // "thinking" | "tool"
    var text: String? = nil          // thinking summary
    var id: String? = nil
    var name: String? = nil
    var kind: String? = nil          // terminal | read | write | search | web | mcp | skill | agent | todo | other
    var title: String? = nil
    var status: String? = nil
    var input: String? = nil
    var inputTruncated: Bool? = nil
    var output: String? = nil
    var outputTruncated: Bool? = nil
    var outputLength: Int? = nil
    var elapsedMS: Double? = nil
}

struct ChatActivity: Codable, Equatable, Sendable {
    var thinking: String = ""
    var tools: [ChatToolStep] = []
    var thinkingUnavailable: Bool? = nil
    var steps: [ChatTimelineStep]? = nil
    var summary: String? = nil
    var isEmpty: Bool { thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tools.isEmpty && thinkingUnavailable != true }

    /// Server timeline when present; otherwise rebuilt from the legacy fields.
    var timeline: [ChatTimelineStep] {
        if let steps, !steps.isEmpty { return steps }
        var rows: [ChatTimelineStep] = []
        let text = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { rows.append(ChatTimelineStep(type: "thinking", text: text)) }
        for tool in tools {
            rows.append(ChatTimelineStep(type: "tool", id: tool.id, name: tool.name, kind: ChatActivityStyle.kind(for: tool.name),
                                         title: tool.detail ?? tool.name, status: tool.status, elapsedMS: tool.elapsedMS))
        }
        return rows
    }

    var headline: String {
        if let summary, !summary.isEmpty { return summary }
        if tools.isEmpty { return "思考过程" }
        var names: [String] = []
        for tool in tools {
            let name = ChatActivityStyle.displayName(tool.name)
            if !names.contains(name) { names.append(name) }
        }
        return "使用了 " + names.prefix(2).joined(separator: "、") + (names.count > 2 ? " 等 \(tools.count) 个工具" : "")
    }
}

typealias ChatActivityHandler = @Sendable (ChatActivity) async -> Void

struct ChatActivityPreference: View {
    let conversationID: String
    @AppStorage private var enabled: Bool
    @State private var syncError: String?

    init(conversationID: String) {
        self.conversationID = conversationID
        _enabled = AppStorage(wrappedValue: false, "chat.activity.\(conversationID)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                Label("显示 thinking 和工具步骤", systemImage: "sparkles")
                    .font(.system(size: 15))
            }
            .accessibilityIdentifier("activity.toggle")
            if enabled, let syncError {
                Text(syncError).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .tint(Color(red: 1.00, green: 0.67, blue: 0.80))
        .padding(.vertical, 14)
        .task(id: enabled) {
            guard enabled && conversationID == "claude" else { syncError = nil; return }
            do {
                _ = try await RemoteChatActivityClient.fetch(messageIDs: [1])
                syncError = nil
            } catch RemoteChatActivityClient.SyncError.needsConnection {
                syncError = "未设置服务器地址，无法同步过程记录。"
            } catch {
                syncError = error.localizedDescription
            }
        }
    }
}

enum ChatActivityStyle {
    static func kind(for name: String) -> String {
        if name.hasPrefix("mcp__") { return "mcp" }
        switch name {
        case "Bash", "BashOutput", "KillShell", "KillBash": return "terminal"
        case "Read", "NotebookRead": return "read"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "write"
        case "Grep", "Glob", "ToolSearch", "WebSearch", "LS": return "search"
        case "WebFetch": return "web"
        case "Skill": return "skill"
        case "Agent", "Task", "SendMessage": return "agent"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "todo"
        default: return "other"
        }
    }
    static func icon(_ kind: String?) -> String {
        switch kind {
        case "terminal": return "terminal"
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "search": return "magnifyingglass"
        case "web": return "globe"
        case "mcp": return "puzzlepiece.extension"
        case "skill": return "wand.and.stars"
        case "agent": return "person.2"
        case "todo": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }
    static func displayName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" { return parts[1] }
        return name
    }
    static func looksChinese(_ text: String) -> Bool {
        var letters = 0, han = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(Int(scalar.value)) { han += 1 }
            else if CharacterSet.letters.contains(scalar) && scalar.isASCII { letters += 1 }
        }
        return han * 2 >= letters
    }
    static let accent = Color(red: 0.78, green: 0.70, blue: 1.00)
}

/// Collapsible header shown above a reply; opens the process timeline sheet.
struct ChatActivityControls: View {
    let activity: ChatActivity
    @AppStorage private var enabled: Bool
    @State private var showing = false

    init(activity: ChatActivity, conversationID: String) {
        self.activity = activity
        _enabled = AppStorage(wrappedValue: false, "chat.activity.\(conversationID)")
    }

    var body: some View {
        if enabled && !activity.isEmpty {
            Button { showing = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: activity.tools.isEmpty ? "sparkles" : ChatActivityStyle.icon(activity.timeline.last(where: { $0.type == "tool" })?.kind))
                        .font(.system(size: 12))
                    Text(activity.headline).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.vertical, 5).padding(.horizontal, 3)
                .frame(maxWidth: 280, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看过程记录")
            .accessibilityValue(activity.headline)
            .sheet(isPresented: $showing) {
                ChatActivitySheet(activity: activity) { showing = false }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(26)
                    .preferredColorScheme(.dark)
            }
            .onChange(of: enabled) { _, value in if !value { showing = false } }
        }
    }
}

struct ChatActivitySheet: View {
    let activity: ChatActivity
    let close: () -> Void
    @AppStorage("chat.activity.translateAll") private var translateAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = activity.timeline
                    if rows.contains(where: { $0.type == "thinking" && !ChatActivityStyle.looksChinese($0.text ?? "") }) {
                        Toggle(isOn: $translateAll) {
                            Text("思考摘要显示中文").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .tint(ChatActivityStyle.accent)
                        .padding(.bottom, 16)
                        .accessibilityIdentifier("activity.translateAll")
                    }
                    if rows.isEmpty || (activity.thinkingUnavailable == true && !rows.contains { $0.type == "thinking" }) {
                        Text("这条回复没有回传可显示的思考摘要。")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, step in
                        ChatTimelineRow(step: step, isLast: index == rows.count - 1, translateAll: translateAll)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 18)
            }
            .navigationTitle("过程记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) }
            }
        }
    }
}

struct ChatTimelineRow: View {
    let step: ChatTimelineStep
    let isLast: Bool
    let translateAll: Bool
    @State private var expanded = false
    @State private var translated: String?
    @State private var showTranslation: Bool?
    @State private var translating = false
    @State private var translateError: String?

    private var isThinking: Bool { step.type == "thinking" }
    private var source: String { step.text ?? "" }
    private var needsTranslation: Bool { isThinking && !ChatActivityStyle.looksChinese(source) }
    private var wantsTranslation: Bool { needsTranslation && (showTranslation ?? translateAll) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker.frame(width: 26, height: 26)
                if !isLast {
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 26)
            Group {
                if isThinking { thinkingBody } else { toolBody }
            }
            .padding(.bottom, isLast ? 4 : 18)
        }
        .task(id: wantsTranslation) {
            guard wantsTranslation, translated == nil, !translating else { return }
            await translate()
        }
    }

    @ViewBuilder private var marker: some View {
        if isThinking {
            Circle().fill(Color.secondary.opacity(0.55)).frame(width: 8, height: 8)
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                Image(systemName: ChatActivityStyle.icon(step.kind))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(step.status == "failed" ? Color.orange : Color.primary.opacity(0.85))
            }
        }
    }

    private var thinkingBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(wantsTranslation ? (translated ?? source) : source)
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
            if needsTranslation {
                HStack(spacing: 10) {
                    Button {
                        showTranslation = !wantsTranslation
                    } label: {
                        Text(translating ? "翻译中…" : (wantsTranslation ? "原文" : "译"))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChatActivityStyle.accent)
                    .accessibilityLabel(wantsTranslation ? "显示原文" : "翻译成中文")
                    if let translateError { Text(translateError).font(.system(size: 11)).foregroundStyle(.orange) }
                }
            }
        }
        .padding(.top, 4)
    }

    private var toolBody: some View {
        NavigationLink {
            ChatToolDetailView(step: step)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title ?? step.name ?? "工具")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusLine).font(.system(size: 11))
                        .foregroundStyle(step.status == "failed" ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
            .padding(.top, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title ?? step.name ?? "工具")
    }

    private var statusLine: String {
        let name = ChatActivityStyle.displayName(step.name ?? "")
        let state = step.status == "running" ? "执行中" : (step.status == "failed" ? "执行失败" : "已完成")
        var parts = [name, state].filter { !$0.isEmpty }
        if let ms = step.elapsedMS, ms >= 1000 { parts.append(String(format: "%.1f 秒", ms / 1000)) }
        return parts.joined(separator: " · ")
    }

    private func translate() async {
        translating = true; translateError = nil
        defer { translating = false }
        do { translated = try await ThinkingTranslator.translate(source) }
        catch { translateError = "翻译失败"; showTranslation = false }
    }
}

struct ChatToolDetailView: View {
    let step: ChatTimelineStep
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: ChatActivityStyle.icon(step.kind))
                    Text(ChatActivityStyle.displayName(step.name ?? "工具")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(step.status == "running" ? "执行中" : (step.status == "failed" ? "执行失败" : "已完成"))
                        .font(.system(size: 12)).foregroundStyle(step.status == "failed" ? Color.orange : Color.secondary)
                }
                if let title = step.title, !title.isEmpty {
                    Text(title).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                ChatCodeBox(label: "输入", text: step.input, truncatedOnServer: step.inputTruncated == true, totalLength: nil)
                ChatCodeBox(label: "输出", text: step.output, truncatedOnServer: step.outputTruncated == true, totalLength: step.outputLength)
            }
            .padding(20)
        }
        .navigationTitle("工具详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatCodeBox: View {
    let label: String
    let text: String?
    let truncatedOnServer: Bool
    let totalLength: Int?
    @State private var expanded = false
    private let preview = 1200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let long = value.count > preview
            Text(value.isEmpty ? (text == nil ? "暂无记录" : "（空）") : (long && !expanded ? String(value.prefix(preview)) + "…" : value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            if long {
                Button(expanded ? "收起" : "展开全部") { withAnimation { expanded.toggle() } }
                    .font(.system(size: 12)).foregroundStyle(ChatActivityStyle.accent)
            }
            if truncatedOnServer && (expanded || !long) {
                Text(totalLength.map { "内容过长，只显示前一部分（共 \($0) 字）" } ?? "内容过长，只显示前一部分")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Server-side translation (cached on the server); a small in-memory cache avoids repeat calls.
actor ThinkingTranslatorCache {
    static let shared = ThinkingTranslatorCache()
    private var store: [String: String] = [:]
    func get(_ key: String) -> String? { store[key] }
    func set(_ key: String, _ value: String) { store[key] = value }
}

enum ThinkingTranslator {
    struct Response: Decodable { var zh: String }
    /// Server-side translation lived behind the removed terminal service;
    /// the open-source build has no translation endpoint, so callers fall
    /// back to showing the original text.
    static func translate(_ text: String) async throws -> String {
        if let hit = await ThinkingTranslatorCache.shared.get(text) { return hit }
        throw RemoteChatActivityClient.SyncError.needsConnection
    }
}

enum RemoteChatActivityClient {
    enum SyncError: LocalizedError {
        case needsConnection, server(Int)
        var errorDescription: String? {
            switch self {
            case .needsConnection: return "未设置服务器地址，无法同步过程记录。"
            case .server: return "过程记录暂时连接不上，请稍后重试。"
            }
        }
    }
    struct Entry: Decodable { var messageID: Int; var activity: ChatActivity }
    struct Response: Decodable { var entries: [Entry] }

    /// Activity sync lived behind the removed terminal service; the
    /// open-source build has no activity endpoint. Callers treat this as
    /// "not connected" and show the local state instead.
    static func fetch(messageIDs: [Int]) async throws -> [Int: ChatActivity] {
        guard !messageIDs.isEmpty else { return [:] }
        throw SyncError.needsConnection
    }
}

#if DEBUG
struct ChatActivityAcceptanceScreen: View {
    @State private var unavailable = false
    private var activity: ChatActivity {
        ChatActivity(thinking: unavailable ? "" : "这是接口返回的测试摘要。",
                     tools: [ChatToolStep(id: "1", name: "Bash", status: "completed", detail: "查询系统日期和时间")],
                     thinkingUnavailable: unavailable)
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                ChatActivityPreference(conversationID: "acceptance")
                ChatActivityControls(activity: activity, conversationID: "acceptance")
                Button("测试未返回摘要") { unavailable = true }
                if let pat = PatInfo.parse(PatInfo.encode(actor: "我", target: UserDefaults.standard.string(forKey: "assistantRemark") ?? "助手", suffix: "的脑袋")) {
                    PatSystemRow(info: pat, timestamp: "00:00", onEdit: {})
                }
                Spacer()
            }.padding(24).navigationTitle("过程记录验收")
        }
    }
}
#endif
