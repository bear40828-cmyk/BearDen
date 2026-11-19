import SwiftUI
import UIKit
import NaturalLanguage

// ===== Memory module for API-backed assistants =====
// Sliding window over the chat history, memory cards extracted from messages that
// fall out of the window, and local embedding retrieval of relevant cards.

struct MemoryCard: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var text: String
    /// "global" or an assistant conversation id.
    var scope: String
    /// "active" / "pending" / "archived"
    var status: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var sourceMessageIDs: [String] = []
    var embedding: [Float]? = nil
    var confidence: Double? = nil
    var deleted: Bool? = nil
    /// Short heading shown in the UI and to the assistant.
    var title: String? = nil
    /// "用户" or the assistant's nickname.
    var lastWriter: String? = nil
    var tags: [String]? = nil
    /// nil = memory card; "longterm" = one section of the always-injected document.
    var kind: String? = nil
    var remoteEmbedding: [Float]? = nil
    var remoteModel: String? = nil

    var isLongTerm: Bool { kind == "longterm" }
    var shortID: String { String(id.prefix(8)) }
    var embeddingText: String { [title ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n") }
    var heading: String { (title?.isEmpty == false ? title! : String(text.prefix(16))) }
    var footer: String {
        (lastWriter.map { $0 + " · " } ?? "") + LocalAITools.format(updatedAt, "yyyy-MM-dd HH:mm")
    }
}

enum MemorySettings {
    static let enabledKey = "memory.enabled"
    static let windowKey = "memory.windowTurns"
    static let defaultWindow = 60
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    static var windowTurns: Int {
        let value = UserDefaults.standard.integer(forKey: windowKey)
        return value == 0 ? defaultWindow : min(100, max(20, value))
    }
    static func assistantKey(_ id: String) -> String { "memory.assistant.\(id)" }
    static func enabled(for id: String) -> Bool {
        enabled && (UserDefaults.standard.object(forKey: assistantKey(id)) as? Bool ?? true)
    }
    static let userWriter = "用户"
    /// When a scope has at most this many active cards, all of them are injected.
    static let injectAllLimit = 30

    // Optional dedicated endpoints. Blank fields keep the default behaviour.
    static let summaryBaseKey = "memory.summary.baseURL"
    static let summaryModelKey = "memory.summary.model"
    static let summaryKeyAccount = "memory.summary.apiKey"
    static let embedBaseKey = "memory.embed.baseURL"
    static let embedModelKey = "memory.embed.model"
    static let embedKeyAccount = "memory.embed.apiKey"
    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    struct Endpoint { let base: String; let key: String; let model: String }
    static var summaryEndpoint: Endpoint? {
        let base = value(summaryBaseKey), model = value(summaryModelKey)
        guard !base.isEmpty, !model.isEmpty else { return nil }
        return Endpoint(base: base, key: AIKeychain.load(account: summaryKeyAccount), model: model)
    }
    static var embedEndpoint: Endpoint? {
        let base = value(embedBaseKey), model = value(embedModelKey)
        guard !base.isEmpty, !model.isEmpty else { return nil }
        return Endpoint(base: base, key: AIKeychain.load(account: embedKeyAccount), model: model)
    }
}

// ===== Remote embeddings (OpenAI-compatible /embeddings) =====
enum RemoteEmbedder {
    static func embed(_ texts: [String], _ endpoint: MemorySettings.Endpoint) async throws -> [[Float]] {
        let base = endpoint.base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base.hasSuffix("/embeddings") ? base : base + "/embeddings") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        if !endpoint.key.isEmpty { request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": endpoint.model, "input": texts])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        let vectors = items.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            .map { ($0["embedding"] as? [NSNumber] ?? []).map { $0.floatValue } }
        guard vectors.count == texts.count else { throw URLError(.cannotParseResponse) }
        return vectors
    }
}

// ===== Embeddings =====
enum MemoryEmbedder {
    private static let model: NLEmbedding? = {
        NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) ?? NLEmbedding.sentenceEmbedding(for: .english)
    }()
    private static let lock = NSLock()

    static func embed(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let model, let vector = model.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// Character bigram overlap, used when no sentence embedding is available.
    static func keywordOverlap(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let chars = Array(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            guard chars.count > 1 else { return Set(chars.map(String.init)) }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let ga = grams(a), gb = grams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(min(ga.count, gb.count))
    }

    static func similarity(query: String, queryVector: [Float]?, card: MemoryCard) -> Double {
        if let queryVector, let vector = card.embedding, vector.count == queryVector.count {
            return cosine(queryVector, vector)
        }
        return keywordOverlap(query, card.text)
    }
}

enum MemoryCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

// ===== Store =====
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var all: [MemoryCard] = []
    @Published var banner: MemoryCard? = nil

    var cards: [MemoryCard] { all.filter { $0.deleted != true && !$0.isLongTerm } }
    var everything: [MemoryCard] { all.filter { $0.deleted != true } }
    func longTerm(_ scope: String) -> [MemoryCard] {
        all.filter { $0.deleted != true && $0.isLongTerm && $0.scope == scope }.sorted { $0.createdAt < $1.createdAt }
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory_cards.json")
    }
    private var pushTask: Task<Void, Never>? = nil
    private var pulled = false

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? MemoryCoding.decoder.decode([MemoryCard].self, from: data) {
            all = list
        }
    }

    private func persist(sync: Bool = true) {
        if let data = try? MemoryCoding.encoder.encode(all) { try? data.write(to: Self.fileURL, options: .atomic) }
        if sync { schedulePush() }
    }

    func upsert(_ card: MemoryCard) {
        var value = card
        value.updatedAt = .now
        let previous = all.first(where: { $0.id == card.id })
        if value.embedding == nil || previous?.text != card.text || previous?.title != card.title {
            value.embedding = value.isLongTerm ? nil : MemoryEmbedder.embed(value.embeddingText)
            value.remoteEmbedding = nil; value.remoteModel = nil
        }
        if let index = all.firstIndex(where: { $0.id == card.id }) { all[index] = value } else { all.insert(value, at: 0) }
        persist()
    }

    /// Deletions are kept as tombstones so a server merge does not bring them back.
    func delete(_ id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].deleted = true
        all[index].updatedAt = .now
        all[index].embedding = nil
        persist()
    }

    func setRemoteEmbeddings(_ vectors: [String: [Float]], model: String) {
        guard !vectors.isEmpty else { return }
        for index in all.indices {
            if let vector = vectors[all[index].id] { all[index].remoteEmbedding = vector; all[index].remoteModel = model }
        }
        persist(sync: false)
    }

    /// Window summaries are kept one card per summarization, without de-duplication.
    func addSummary(_ card: MemoryCard) {
        var value = card
        value.embedding = MemoryEmbedder.embed(value.embeddingText)
        all.insert(value, at: 0)
        persist()
    }

    // ===== Assistant tool calls =====
    private func lookup(_ id: String, scopes: Set<String>) -> Int? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count >= 4 else { return nil }
        return all.firstIndex { $0.deleted != true && scopes.contains($0.scope) && $0.id.lowercased().hasPrefix(key) }
    }

    func toolCall(_ name: String, _ args: [String: Any], conversation: AIConversation) throws -> String {
        let writer = conversation.name
        let own: Set<String> = [conversation.id, "global"]
        func str(_ key: String) -> String? {
            (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func fail(_ text: String) -> Error { AIModelToolError.invalidResponse(text) }
        switch name {
        case "memory_list":
            let scope = str("scope") ?? "all"
            let scopes: Set<String> = scope == "global" ? ["global"] : scope == "self" ? [conversation.id] : own
            let q = str("query") ?? ""
            let items = everything.filter { scopes.contains($0.scope) && $0.status != "archived" }
                .filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || ($0.title ?? "").localizedCaseInsensitiveContains(q) }
            guard !items.isEmpty else { return "没有符合条件的记忆。" }
            let lines = items.prefix(80).map { card in
                let kind = card.isLongTerm ? "长期记忆" : (card.status == "pending" ? "记忆卡·待确认" : "记忆卡")
                let where_ = card.scope == "global" ? "全局" : "你的"
                return "[\(card.shortID)] \(kind)·\(where_)｜\(card.heading)（\(card.footer)）\n\(card.text)"
            }
            return lines.joined(separator: "\n\n") + (items.count > 80 ? "\n\n（只列出前 80 条）" : "")
        case "memory_add":
            guard let text = str("text"), !text.isEmpty else { throw fail("缺少内容") }
            let isGlobal = args["global"] as? Bool ?? false
            var card = MemoryCard(text: text, scope: isGlobal ? "global" : conversation.id, status: "active")
            card.title = str("title"); card.lastWriter = writer
            upsert(card)
            return "已记下 [\(card.shortID)] \(card.heading)"
        case "memory_update":
            guard let id = str("id"), let index = lookup(id, scopes: own), !all[index].isLongTerm else { throw fail("找不到这张记忆卡") }
            var card = all[index]
            if let title = str("title"), !title.isEmpty { card.title = title }
            if let text = str("text"), !text.isEmpty { card.text = text }
            if args["archive"] as? Bool == true { card.status = "archived" }
            card.lastWriter = writer
            upsert(card)
            return "已更新 [\(card.shortID)] \(card.heading)"
        case "longterm_update":
            guard let section = str("section"), !section.isEmpty else { throw fail("缺少段落小标题") }
            let scope = str("scope") == "global" ? "global" : conversation.id
            let mode = str("mode") ?? "replace"
            let text = str("text") ?? ""
            let existing = longTerm(scope).first { ($0.title ?? "") == section }
            if mode == "delete" {
                guard let existing else { throw fail("没有这个段落") }
                delete(existing.id)
                return "已删除段落「\(section)」"
            }
            guard !text.isEmpty else { throw fail("缺少段落内容") }
            var card = existing ?? MemoryCard(text: "", scope: scope, status: "active")
            card.kind = "longterm"; card.title = section; card.lastWriter = writer
            card.text = mode == "append" && !card.text.isEmpty ? card.text + "\n" + text : text
            upsert(card)
            return "已更新\(scope == "global" ? "全局" : "你的")长期记忆段落「\(section)」"
        default:
            throw fail("未知的记忆工具")
        }
    }

    func setStatus(_ id: String, _ status: String) {
        guard var card = all.first(where: { $0.id == id }) else { return }
        card.status = status
        upsert(card)
    }

    /// Adds extracted cards, skipping near-duplicates. Returns the cards that were added.
    @discardableResult
    func addExtracted(_ candidates: [MemoryCard]) -> [MemoryCard] {
        var added: [MemoryCard] = []
        for var candidate in candidates {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            candidate.text = text
            candidate.embedding = MemoryEmbedder.embed(candidate.embeddingText)
            let existing = cards.filter { $0.scope == candidate.scope || $0.scope == "global" }
            let duplicate = existing.contains { card in
                if card.text == text { return true }
                if let a = candidate.embedding, let b = card.embedding, a.count == b.count {
                    return MemoryEmbedder.cosine(a, b) > 0.9
                }
                return MemoryEmbedder.keywordOverlap(text, card.text) > 0.9
            }
            if duplicate { continue }
            all.insert(candidate, at: 0)
            added.append(candidate)
        }
        if !added.isEmpty {
            persist()
            banner = added.first
        }
        return added
    }

    func undoBanner() {
        guard let card = banner else { return }
        all.removeAll { $0.id == card.id }
        persist()
        banner = nil
    }

    // ===== Server sync =====
    private static var endpoint: URL? { API.base?.appendingPathComponent("api/memory") }

    private static func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let bearer = BeardenAuth.bearer { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.push()
        }
    }

    func push() async {
        guard let url = Self.endpoint else { return }
        var request = Self.authorized(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = all.map { card -> MemoryCard in var copy = card; copy.embedding = nil; copy.remoteEmbedding = nil; copy.remoteModel = nil; return copy }
        struct Body: Encodable { let cards: [MemoryCard] }
        guard let body = try? MemoryCoding.encoder.encode(Body(cards: payload)) else { return }
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Merges the server copy on launch; the newer updatedAt wins per card.
    func pullOnce() async {
        guard !pulled, let url = Self.endpoint else { return }
        pulled = true
        guard let (data, response) = try? await URLSession.shared.data(for: Self.authorized(url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        struct Body: Decodable { let cards: [MemoryCard] }
        guard let remote = try? MemoryCoding.decoder.decode(Body.self, from: data).cards else { return }
        var changed = false
        for var card in remote {
            if let index = all.firstIndex(where: { $0.id == card.id }) {
                if card.updatedAt > all[index].updatedAt {
                    card.embedding = card.deleted == true || card.isLongTerm ? nil : MemoryEmbedder.embed(card.embeddingText)
                    all[index] = card
                    changed = true
                }
            } else {
                card.embedding = card.deleted == true || card.isLongTerm ? nil : MemoryEmbedder.embed(card.embeddingText)
                all.append(card)
                changed = true
            }
        }
        all.sort { $0.createdAt > $1.createdAt }
        if changed { persist(sync: false) }
        if remote.count != all.count || changed { await push() }
    }
}

// ===== Engine: window, retrieval, extraction =====
enum MemoryEngine {
    static let batchTurns = 20
    private static let inFlight = InFlight()
    private final class InFlight: @unchecked Sendable {
        private let lock = NSLock(); private var ids = Set<String>()
        func begin(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.insert(id).inserted }
        func end(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }
    }

    static func isEligible(_ conversation: AIConversation) -> Bool {
        conversation.kind != "group"
    }

    /// Index where the last `turns` user turns start.
    static func windowStart(_ messages: [LocalAIMessage], turns: Int) -> Int {
        var count = 0
        for index in stride(from: messages.count - 1, through: 0, by: -1) where messages[index].role == "user" {
            count += 1
            if count == turns { return index }
        }
        return 0
    }

    static func window(_ messages: [LocalAIMessage], conversation: AIConversation) -> [LocalAIMessage] {
        guard isEligible(conversation), MemorySettings.enabled(for: conversation.id) else { return messages }
        return Array(messages[windowStart(messages, turns: MemorySettings.windowTurns)...])
    }

    /// Long-term documents plus memory cards for the system prompt, or an empty string.
    static func contextBlock(for messages: [LocalAIMessage], conversation: AIConversation) async -> String {
        guard isEligible(conversation), MemorySettings.enabled(for: conversation.id) else { return "" }
        let (globalDoc, ownDoc, cards) = await MainActor.run { () -> ([MemoryCard], [MemoryCard], [MemoryCard]) in
            let store = MemoryStore.shared
            return (store.longTerm("global"), store.longTerm(conversation.id),
                    store.cards.filter { $0.status == "active" && ($0.scope == "global" || $0.scope == conversation.id) })
        }
        var out = ""
        func section(_ card: MemoryCard) -> String { "### \(card.heading)（\(card.footer)）\n\(card.text)" }
        if !globalDoc.isEmpty || !ownDoc.isEmpty {
            out += "\n\n长期记忆（每次对话都会带上；可用 longterm_update 修改）："
            if !globalDoc.isEmpty { out += "\n\n【全局】\n" + globalDoc.map(section).joined(separator: "\n\n") }
            if !ownDoc.isEmpty { out += "\n\n【只属于你】\n" + ownDoc.map(section).joined(separator: "\n\n") }
        }
        let chosen: [MemoryCard]
        if cards.count <= MemorySettings.injectAllLimit {
            chosen = cards.sorted { $0.updatedAt > $1.updatedAt }
        } else if let query = messages.last(where: { $0.role == "user" })?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            chosen = await retrieve(query, from: cards)
        } else { chosen = [] }
        if !chosen.isEmpty {
            let lines = chosen.map { "- [\($0.shortID)] \($0.heading)：\($0.text)（\($0.footer)）" }.joined(separator: "\n")
            out += "\n\n记忆卡（来自以往对话，自然参考即可，不必逐条提起；方括号里是编号）：\n\(lines)"
        }
        return out
    }

    static func retrieve(_ query: String, from cards: [MemoryCard], k: Int = 5) async -> [MemoryCard] {
        if let endpoint = MemorySettings.embedEndpoint {
            do {
                var vectors: [String: [Float]] = [:]
                let missing = Array(cards.filter { $0.remoteModel != endpoint.model || $0.remoteEmbedding == nil }.prefix(256))
                for start in stride(from: 0, to: missing.count, by: 32) {
                    let chunk = Array(missing[start..<min(start + 32, missing.count)])
                    let result = try await RemoteEmbedder.embed(chunk.map(\.embeddingText), endpoint)
                    for (card, vector) in zip(chunk, result) { vectors[card.id] = vector }
                }
                let fresh = vectors
                if !fresh.isEmpty { await MainActor.run { MemoryStore.shared.setRemoteEmbeddings(fresh, model: endpoint.model) } }
                guard let q = try await RemoteEmbedder.embed([query], endpoint).first else { throw URLError(.cannotParseResponse) }
                let ranked = cards.compactMap { card -> (MemoryCard, Double)? in
                    let vector = fresh[card.id] ?? (card.remoteModel == endpoint.model ? card.remoteEmbedding : nil)
                    guard let vector else { return nil }
                    return (card, MemoryEmbedder.cosine(q, vector))
                }.filter { $0.1 >= 0.3 }.sorted { $0.1 > $1.1 }.prefix(k)
                return ranked.map(\.0)
            } catch {
                // Fall through to the on-device embedding.
            }
        }
        let vector = MemoryEmbedder.embed(query)
        return cards
            .map { ($0, MemoryEmbedder.similarity(query: query, queryVector: vector, card: $0)) }
            .filter { $0.1 >= 0.35 }
            .sorted { $0.1 > $1.1 }
            .prefix(k).map(\.0)
    }

    private static func cursorKey(_ id: String) -> String { "memory.cursor.\(id)" }

    /// When at least `batchTurns` user turns have left the window since the last extraction,
    /// asks the same assistant to extract durable facts from them in the background.
    static func scheduleExtraction(all messages: [LocalAIMessage], conversation: AIConversation, apiKey: String) {
        guard isEligible(conversation), MemorySettings.enabled(for: conversation.id), !apiKey.isEmpty else { return }
        let start = windowStart(messages, turns: MemorySettings.windowTurns)
        guard start > 0 else { return }
        let defaults = UserDefaults.standard
        var from = 0
        if let cursor = defaults.string(forKey: cursorKey(conversation.id)),
           let index = messages.firstIndex(where: { $0.id.uuidString == cursor }) {
            from = index + 1
        }
        guard from < start else { return }
        let slice = Array(messages[from..<start]).filter { $0.withdrawn != true }
        guard slice.filter({ $0.role == "user" }).count >= batchTurns else { return }
        guard inFlight.begin(conversation.id) else { return }
        let lastID = messages[start - 1].id.uuidString
        Task.detached(priority: .utility) {
            defer { inFlight.end(conversation.id) }
            guard let (summary, candidates) = try? await extract(slice, conversation: conversation, apiKey: apiKey) else { return }
            defaults.set(lastID, forKey: cursorKey(conversation.id))
            await MainActor.run {
                if let summary { MemoryStore.shared.addSummary(summary) }
                _ = MemoryStore.shared.addExtracted(candidates)
            }
        }
    }

    static let extractionPrompt = """
    下面是一段较早的聊天记录（已滑出最近的对话窗口）。请完成两件事：
    1. summary：用几句中文概括这段对话的主要内容和情绪，写给以后的自己看。
    2. facts：只提取值得长期记住的内容：关于用户本人的事实、偏好、习惯、重要经历或计划，以及你们关系里的重要约定。忽略寒暄、一次性的小事和已经过时的信息。
    只输出 JSON 对象，不要任何解释，格式：
    {"summary": "……", "facts": [{"title": "四到八个字的小标题", "text": "用一句简短的中文陈述", "confidence": 0.0到1.0, "global": true或false}]}
    global 为 true 表示与具体助手无关、关于用户本人的通用信息。没有值得记住的事实时 facts 为 []。
    """

    static func summaryTitle(_ slice: [LocalAIMessage]) -> String {
        guard let first = slice.first?.createdAt, let last = slice.last?.createdAt else { return "对话摘要" }
        let sameDay = LocalAITools.format(first, "yyyyMMdd") == LocalAITools.format(last, "yyyyMMdd")
        return "对话摘要 " + LocalAITools.format(first, "MM/dd HH:mm") + "–" + LocalAITools.format(last, sameDay ? "HH:mm" : "MM/dd HH:mm")
    }

    static func extract(_ slice: [LocalAIMessage], conversation: AIConversation, apiKey: String) async throws -> (MemoryCard?, [MemoryCard]) {
        let transcript = slice.map { message -> String in
            LocalAITools.stamp(message.createdAt) + (message.role == "user" ? "用户：" : "助手：") + String(message.text.prefix(600))
        }.joined(separator: "\n")
        let prompt = extractionPrompt + "\n\n聊天记录：\n" + transcript
        let reply: String
        if let endpoint = MemorySettings.summaryEndpoint {
            reply = try await AIProviderClient.send(
                messages: [LocalAIMessage(role: "user", text: prompt)],
                model: endpoint.model, baseURL: endpoint.base, apiKey: endpoint.key,
                format: "OpenAI 兼容", nickname: conversation.name
            )
        } else {
            reply = try await AIProviderClient.send(
                messages: [LocalAIMessage(role: "user", text: prompt)],
                model: conversation.model ?? "",
                baseURL: conversation.baseURL ?? "",
                apiKey: apiKey,
                format: conversation.interfaceFormat ?? "OpenAI 兼容",
                nickname: conversation.name
            )
        }
        var summaryText: String? = nil
        var items: [[String: Any]] = []
        if let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
           let data = String(reply[open...close]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["facts"] != nil || object["summary"] != nil {
            summaryText = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            items = object["facts"] as? [[String: Any]] ?? []
        } else if let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close,
                  let data = String(reply[open...close]).data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            items = list
        } else {
            throw CocoaError(.coderReadCorrupt)
        }
        let sources = slice.map { $0.id.uuidString }
        var summary: MemoryCard? = nil
        if let summaryText, !summaryText.isEmpty {
            var card = MemoryCard(text: summaryText, scope: conversation.id, status: "active", sourceMessageIDs: sources)
            card.title = summaryTitle(slice); card.tags = ["摘要"]; card.lastWriter = conversation.name
            summary = card
        }
        let facts: [MemoryCard] = items.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            let confidence = (item["confidence"] as? Double) ?? (item["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            let isGlobal = item["global"] as? Bool ?? false
            var card = MemoryCard(text: text, scope: isGlobal ? "global" : conversation.id,
                                  status: confidence >= 0.75 ? "active" : "pending",
                                  sourceMessageIDs: sources, confidence: confidence)
            card.title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            card.lastWriter = conversation.name
            return card
        }
        return (summary, facts)
    }
}

// ===== Banner =====
struct MemoryBannerOverlay: View {
    @ObservedObject private var store = MemoryStore.shared

    var body: some View {
        VStack {
            if let card = store.banner {
                HStack(spacing: 10) {
                    Image(systemName: "heart.text.square")
                    Text("记住了：\(card.heading)").lineLimit(2).font(.system(size: 14))
                    Spacer(minLength: 4)
                    Button("撤销") { store.undoBanner() }.font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: card.id) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if store.banner?.id == card.id { withAnimation { store.banner = nil } }
                }
            }
            Spacer()
        }
        .animation(.spring(duration: 0.3), value: store.banner?.id)
    }
}

// ===== 记忆空间 =====
private struct MemoryAssistantRef: Identifiable, Hashable { let id: String; let name: String }

struct MemorySpaceView: View {
    enum Filter: Hashable { case all, global, assistant(String), archived, pending }

    @ObservedObject private var store = MemoryStore.shared
    @AppStorage(MemorySettings.enabledKey) private var enabled = true
    @AppStorage(MemorySettings.windowKey) private var windowTurns = MemorySettings.defaultWindow
    @AppStorage("aiConversationsJSON") private var conversationsJSON = ""
    @State private var filter: Filter
    @State private var query = ""
    @State private var editing: MemoryCard? = nil
    @State private var shareURL: URL? = nil
    @State private var showingModels = false

    init(assistantID: String? = nil) {
        _filter = State(initialValue: assistantID.map { .assistant($0) } ?? .all)
    }

    private var assistants: [MemoryAssistantRef] {
        guard let data = conversationsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([AIConversation].self, from: data) else { return [] }
        return list.filter(MemoryEngine.isEligible).filter { $0.baseURL != nil }
            .map { MemoryAssistantRef(id: $0.id, name: $0.displayName) }
    }

    private func scopeName(_ scope: String) -> String {
        scope == "global" ? "全局记忆" : (assistants.first { $0.id == scope }?.name ?? "助手记忆")
    }

    private var filtered: [MemoryCard] {
        let base: [MemoryCard]
        switch filter {
        case .all: base = store.cards.filter { $0.status != "archived" }
        case .global: base = store.cards.filter { $0.scope == "global" && $0.status != "archived" }
        case .assistant(let id): base = store.cards.filter { $0.scope == id && $0.status != "archived" }
        case .archived: base = store.cards.filter { $0.status == "archived" }
        case .pending: base = store.cards.filter { $0.status == "pending" }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? base : base.filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.title ?? "").localizedCaseInsensitiveContains(q) }
    }

    private var longTermScope: String {
        if case .assistant(let id) = filter { return id }
        return "global"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                settings
                longTermSection
                HStack {
                    Text("记忆卡").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button {
                        let scope: String
                        if case .assistant(let id) = filter { scope = id } else { scope = "global" }
                        editing = MemoryCard(text: "", scope: scope, status: "active")
                    } label: { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)) }
                }
                TextField("搜索记忆", text: $query)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                chips
                if filtered.isEmpty {
                    Text("还没有记忆卡").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(filtered) { card in
                    cardRow(card).onTapGesture { editing = card }
                }
                exports
            }
            .padding(16)
        }
        .navigationTitle("记忆空间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.pullOnce() }
        .sheet(item: $editing) { card in
            MemoryCardEditor(card: card, assistants: assistants, scopeName: scopeName)
        }
        .sheet(isPresented: $showingModels) { MemoryModelSettingsView() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { MemoryActivityView(url: shareURL) }
        }
    }

    private var header: some View {
        let week = Date.now.addingTimeInterval(-7 * 24 * 3600)
        return VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                Label("记忆", systemImage: "heart.text.square").font(.system(size: 18, weight: .bold))
            }
            Text("让 AI 在不同对话中记住重要的事情。").font(.system(size: 14)).foregroundStyle(.secondary)
            HStack {
                stat(store.cards.count, "记忆卡片")
                Spacer()
                stat(store.cards.filter { $0.createdAt > week }.count, "最近新增")
                Spacer()
                stat(store.cards.filter { $0.status == "pending" }.count, "待确认")
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func stat(_ value: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 28, weight: .bold))
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 \(windowTurns) 轮原样发送").font(.system(size: 14, weight: .medium))
            Slider(value: Binding(get: { Double(windowTurns) }, set: { windowTurns = Int($0) }), in: 20...100, step: 5)
            if case .assistant(let id) = filter {
                AssistantMemoryToggle(id: id)
            }
            Button { showingModels = true } label: {
                HStack {
                    Label("记忆总结模型与向量接口", systemImage: "slider.horizontal.3").font(.system(size: 14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var longTermSection: some View {
        let sections = store.longTerm(longTermScope)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("长期记忆").font(.system(size: 22, weight: .bold))
                Text(scopeName(longTermScope)).font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    var card = MemoryCard(text: "", scope: longTermScope, status: "active")
                    card.kind = "longterm"
                    editing = card
                } label: { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)) }
            }
            Text("每次对话都会整篇带上。全局的所有助手共用，助手自己的只给它。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if sections.isEmpty {
                Text("还没有内容").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            ForEach(sections) { card in
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.heading).font(.system(size: 16, weight: .semibold))
                    Text(card.text).font(.system(size: 15))
                    Text(card.footer).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { editing = card }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", .all)
                chip("全局", .global)
                ForEach(assistants) { chip($0.name, .assistant($0.id)) }
                chip("待确认", .pending)
                chip("归档", .archived)
            }
        }
    }

    private func chip(_ title: String, _ value: Filter) -> some View {
        Button { filter = value } label: {
            Text(title).font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(filter == value ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func cardRow(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scopeName(card.scope)).font(.system(size: 13)).foregroundStyle(.secondary)
                if card.status == "pending" { Text("待确认").font(.system(size: 12)).foregroundStyle(.orange) }
                if card.status == "archived" { Text("已归档").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(card.tags ?? [], id: \.self) { tag in
                    Text(tag).font(.system(size: 12)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer()
            }
            if let title = card.title, !title.isEmpty {
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            Text(card.text).font(.system(size: 16))
            Text(card.footer).font(.system(size: 12)).foregroundStyle(.secondary)
            if card.status == "pending" {
                HStack {
                    Button("确认") { store.setStatus(card.id, "active") }.buttonStyle(.borderedProminent)
                    Button("丢弃") { store.delete(card.id) }.buttonStyle(.bordered)
                }.font(.system(size: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
    }

    private var exports: some View {
        HStack {
            Button("导出记忆") { shareURL = MemoryExport.memories(store.everything) }
                .buttonStyle(.bordered)
            Button("导出聊天记录") { shareURL = MemoryExport.chats(conversationsJSON: conversationsJSON) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

private struct AssistantMemoryToggle: View {
    let id: String
    @AppStorage private var on: Bool
    init(id: String) {
        self.id = id
        _on = AppStorage(wrappedValue: true, MemorySettings.assistantKey(id))
    }
    var body: some View { Toggle("这个助手使用记忆", isOn: $on).font(.system(size: 14)) }
}

private struct MemoryCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var card: MemoryCard
    let assistants: [MemoryAssistantRef]
    let scopeName: (String) -> String
    private var store: MemoryStore { MemoryStore.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("小标题") {
                    TextField("小标题", text: Binding(get: { card.title ?? "" }, set: { card.title = $0 }))
                }
                Section("内容") { TextField("记忆内容", text: $card.text, axis: .vertical).lineLimit(3...12) }
                if store.everything.contains(where: { $0.id == card.id }) {
                    Section("最后写入") { Text(card.footer).foregroundStyle(.secondary) }
                }
                Section("范围") {
                    Picker("范围", selection: $card.scope) {
                        Text("全局记忆").tag("global")
                        ForEach(assistants) { Text($0.name).tag($0.id) }
                    }
                }
                if card.isLongTerm, store.everything.contains(where: { $0.id == card.id }) {
                    Section { Button("删除", role: .destructive) { store.delete(card.id); dismiss() } }
                }
                if !card.isLongTerm, store.cards.contains(where: { $0.id == card.id }) {
                    Section {
                        if card.status == "pending" {
                            Button("确认") { card.status = "active"; save() }
                        }
                        Button(card.status == "archived" ? "恢复" : "归档") {
                            card.status = card.status == "archived" ? "active" : "archived"; save()
                        }
                        Button("删除", role: .destructive) { store.delete(card.id); dismiss() }
                    }
                }
            }
            .navigationTitle(card.isLongTerm ? "长期记忆" : "记忆卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        card.text = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
        card.title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !card.text.isEmpty else { return }
        card.lastWriter = MemorySettings.userWriter
        store.upsert(card)
        dismiss()
    }
}

private struct MemoryModelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MemorySettings.summaryBaseKey) private var summaryBase = ""
    @AppStorage(MemorySettings.summaryModelKey) private var summaryModel = ""
    @AppStorage(MemorySettings.embedBaseKey) private var embedBase = ""
    @AppStorage(MemorySettings.embedModelKey) private var embedModel = ""
    @State private var summaryKey = AIKeychain.load(account: MemorySettings.summaryKeyAccount)
    @State private var embedKey = AIKeychain.load(account: MemorySettings.embedKeyAccount)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Base URL（如 https://api.example.com/v1）", text: $summaryBase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key", text: $summaryKey)
                    TextField("模型", text: $summaryModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("记忆总结模型") } footer: {
                    Text("用于提取记忆卡和对话摘要，OpenAI 兼容接口。留空则使用该助手自己的聊天模型。")
                }
                Section {
                    TextField("Base URL（/embeddings 所在路径）", text: $embedBase)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API Key", text: $embedKey)
                    TextField("模型（如 BAAI/bge-m3）", text: $embedModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("向量接口") } footer: {
                    Text("用于检索相关记忆卡，OpenAI 兼容 /embeddings。留空则使用手机自带的向量。")
                }
            }
            .navigationTitle("记忆模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("保存") { save(); dismiss() } }
            }
        }
    }

    private func store(_ value: String, _ account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { AIKeychain.delete(account: account) } else { try? AIKeychain.save(trimmed, account: account) }
    }

    private func save() {
        store(summaryKey, MemorySettings.summaryKeyAccount)
        store(embedKey, MemorySettings.embedKeyAccount)
    }
}

enum MemoryExport {
    private static func write(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private static var stamp: String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: .now)
    }

    static func memories(_ cards: [MemoryCard]) -> URL? {
        let list = cards.map { card -> MemoryCard in var copy = card; copy.embedding = nil; copy.remoteEmbedding = nil; return copy }
        guard let data = try? MemoryCoding.encoder.encode(list) else { return nil }
        return write(data, name: "memory-\(stamp).json")
    }

    static func chats(conversationsJSON: String) -> URL? {
        struct Chat: Encodable { let id: String; let name: String; let messages: [LocalAIMessage] }
        let list = (conversationsJSON.data(using: .utf8)).flatMap { try? JSONDecoder().decode([AIConversation].self, from: $0) } ?? []
        let chats: [Chat] = list.compactMap { conversation in
            guard let data = UserDefaults.standard.data(forKey: "configuredAI.messages.\(conversation.id)"),
                  let messages = try? JSONDecoder().decode([LocalAIMessage].self, from: data) else { return nil }
            return Chat(id: conversation.id, name: conversation.displayName, messages: messages)
        }
        guard let data = try? MemoryCoding.encoder.encode(chats) else { return nil }
        return write(data, name: "chats-\(stamp).json")
    }
}

private struct MemoryActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
