import Foundation

// Tools executed on the phone itself (memory, web access) plus the time helpers shared by all
// API assistants. Server-catalogued tools still go through api/ai/call.
enum LocalAITools {
    static let webNames: Set<String> = ["web_search", "web_open"]
    static let memoryNames: Set<String> = ["memory_list", "memory_add", "memory_update", "longterm_update"]
    static func handles(_ name: String) -> Bool { webNames.contains(name) || memoryNames.contains(name) }

    // ===== Time =====
    static let beijing = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN"); f.timeZone = beijing; f.dateFormat = pattern
        return f.string(from: date)
    }

    static func nowLine(_ date: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = beijing
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = names[(calendar.component(.weekday, from: date) - 1) % 7]
        return format(date, "yyyy-MM-dd HH:mm") + " 星期" + weekday
    }

    static func stamp(_ date: Date) -> String { "[" + format(date, "MM-dd HH:mm") + "] " }

    static var timePreamble: String {
        "当前北京时间：\(nowLine())\n历史消息开头的 [MM-dd HH:mm] 是那条消息的发送时间（北京时间），只供参考，你回复时不要写这个前缀。\n\n"
    }

    /// Copies of the messages with their send time prefixed to the text.
    static func stamped(_ messages: [LocalAIMessage]) -> [LocalAIMessage] {
        messages.map { message in var copy = message; copy.text = stamp(message.createdAt) + message.text; return copy }
    }

    /// Removes a time prefix the model may have imitated at the start of its reply.
    static func stripStamp(_ text: String) -> String {
        guard let range = text.range(of: #"^\s*\[\d{2}-\d{2} \d{2}:\d{2}\]\s*"#, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    static func toolHint(memory: Bool) -> String {
        var hint = "\n\n需要最新或不确定的信息时，可以用 web_search 搜索、web_open 打开网页阅读，不要编造。"
        if memory {
            hint += "需要记住、修正或整理关于对方的信息时，可以用 memory_list / memory_add / memory_update 管理记忆卡，用 longterm_update 修改长期记忆；只在确有必要时写，写之前先看已有内容避免重复。"
        }
        return hint
    }

    // ===== Catalog (same shape as the server catalog) =====
    static func catalog(memory: Bool) -> [[String: Any]] {
        func schema(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        var tools: [[String: Any]] = [
            ["name": "web_search", "description": "联网搜索，返回最多 8 条结果（标题、链接、摘要）。",
             "inputSchema": schema(["query": string("搜索关键词")], ["query"])],
            ["name": "web_open", "description": "打开一个网页，返回标题和正文文本（最多约 8000 字）。",
             "inputSchema": schema(["url": string("完整的 http(s) 网址")], ["url"])]
        ]
        guard memory else { return tools }
        tools += [
            ["name": "memory_list", "description": "列出长期记忆的段落和记忆卡（编号、小标题、最后写入者、时间、内容）。",
             "inputSchema": schema([
                "scope": ["type": "string", "enum": ["all", "global", "self"], "description": "all=全部，global=全局，self=只属于你的"],
                "query": string("可选，按关键词筛选")
             ], [])],
            ["name": "memory_add", "description": "新增一张记忆卡。",
             "inputSchema": schema([
                "title": string("小标题，简短"),
                "text": string("记忆内容，一两句陈述"),
                "global": ["type": "boolean", "description": "true=关于对方本人的通用信息，所有助手可见；false=只属于你"]
             ], ["title", "text"])],
            ["name": "memory_update", "description": "修改或归档一张已有记忆卡（用 memory_list 里的编号）。",
             "inputSchema": schema([
                "id": string("记忆卡编号"),
                "title": string("可选，新的小标题"),
                "text": string("可选，新的内容"),
                "archive": ["type": "boolean", "description": "可选，true=归档这张卡"]
             ], ["id"])],
            ["name": "longterm_update", "description": "修改长期记忆中的一个段落（按小标题定位，不存在则新建）。长期记忆每次对话都会整篇带上，只写最重要、长期有效的内容。",
             "inputSchema": schema([
                "scope": ["type": "string", "enum": ["self", "global"], "description": "self=你自己的长期记忆，global=全局长期记忆"],
                "section": string("段落小标题"),
                "text": string("段落内容"),
                "mode": ["type": "string", "enum": ["replace", "append", "delete"], "description": "replace=整段替换（默认），append=追加到末尾，delete=删除该段"]
             ], ["scope", "section"])]
        ]
        return tools
    }

    // ===== Execution =====
    static func execute(_ name: String, _ args: [String: Any], _ conversation: AIConversation) async -> [[String: Any]] {
        do {
            let text: String
            switch name {
            case "web_search": text = try await webSearch(args["query"] as? String ?? "")
            case "web_open": text = try await webOpen(args["url"] as? String ?? "")
            default:
                guard MemoryEngine.isEligible(conversation), MemorySettings.enabled(for: conversation.id) else {
                    return failure("这个助手没有开启记忆")
                }
                text = try await MainActor.run { try MemoryStore.shared.toolCall(name, args, conversation: conversation) }
            }
            return [["type": "text", "text": text]]
        } catch {
            return failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private static func failure(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text, "__bear_error": true]]
    }

    private static func serverGET(_ path: String, _ items: [URLQueryItem]) async throws -> [String: Any] {
        guard let base = API.base,
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AIModelToolError.invalidResponse("未设置服务器地址")
        }
        components.queryItems = items
        guard let url = components.url else { throw AIModelToolError.invalidResponse("请求地址不正确") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        BeardenAuth.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIModelToolError.invalidResponse(object["error"] as? String ?? "联网请求失败")
        }
        return object
    }

    private static func webSearch(_ query: String) async throws -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw AIModelToolError.invalidResponse("缺少搜索关键词") }
        let results = try await serverGET("api/search", [URLQueryItem(name: "q", value: q)])["results"] as? [[String: Any]] ?? []
        guard !results.isEmpty else { return "没有搜到结果。" }
        return results.enumerated().map { index, item in
            "\(index + 1). \(item["title"] as? String ?? "")\n\(item["url"] as? String ?? "")\n\(item["snippet"] as? String ?? "")"
        }.joined(separator: "\n\n")
    }

    private static func webOpen(_ url: String) async throws -> String {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { throw AIModelToolError.invalidResponse("网址需要以 http(s):// 开头") }
        let page = try await serverGET("api/fetch", [URLQueryItem(name: "url", value: value)])
        let text = page["text"] as? String ?? ""
        let more = page["truncated"] as? Bool == true ? "\n\n（正文较长，已截断）" : ""
        return "标题：\(page["title"] as? String ?? "")\n\n\(text.isEmpty ? "（没有读到正文）" : text)\(more)"
    }
}
