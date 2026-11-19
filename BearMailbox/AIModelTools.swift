import Foundation

enum AIModelToolError: LocalizedError {
    case invalidResponse(String)
    var errorDescription: String? { if case .invalidResponse(let text) = self { return text }; return nil }
}

// The model chooses function calls; the phone executes only catalogued functions through the
// owner's authenticated session. A model never receives the Moments cookie or another AI's token.
enum AIModelTools {
    static func sendResponses(messages: [LocalAIMessage], conversation: AIConversation, accessToken: String, onActivity: ChatActivityHandler? = nil) async throws -> String {
        LocalAITools.stripStamp(try await sendResponsesCore(messages: LocalAITools.stamped(messages), conversation: conversation, accessToken: accessToken, onActivity: onActivity))
    }
    private static func sendResponsesCore(messages: [LocalAIMessage], conversation: AIConversation, accessToken: String, onActivity: ChatActivityHandler? = nil) async throws -> String {
        var activity = ChatActivity()
        let memoryTools = MemoryEngine.isEligible(conversation) && MemorySettings.enabled(for: conversation.id)
        let memoryBlock = await MemoryEngine.contextBlock(for: messages, conversation: conversation)
        let catalog = ((try? await fetchCatalog()) ?? []) + LocalAITools.catalog(memory: memoryTools)
        var input: [[String: Any]] = messages.filter { $0.withdrawn != true }.map { message in
            if message.role == "assistant" { return ["role":"assistant", "content":message.text] }
            let blocks = userContent(message, format: "openai") as? [[String: Any]] ?? []
            return ["role":"user", "content":blocks.map { value in
                if value["type"] as? String == "text" { return ["type":"input_text", "text":value["text"] ?? ""] }
                return ["type":"input_image", "image_url":(value["image_url"] as? [String: Any])?["url"] ?? ""]
            }]
        }
        for _ in 0..<8 {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"; request.timeoutInterval = 120
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model":conversation.model ?? "", "store":false, "stream":false,
                "instructions":LocalAITools.timePreamble + "你在熊窝里的昵称是\(conversation.name)。只有真正执行工具后才能声称已操作朋友圈、相册、收藏；不可用时明确说明。" + LocalAITools.toolHint(memory: memoryTools) + "\n\n\(MessageBubbleSplitter.promptInstruction)" + memoryBlock,
                "input":input,
                "tools":catalog.map { ["type":"function", "name":$0["name"] ?? "", "description":$0["description"] ?? "", "parameters":$0["inputSchema"] ?? [:]] }
            ])
            let result = try await api(request)
            let outputs = result["output"] as? [[String: Any]] ?? []
            let thoughts = outputs.filter { $0["type"] as? String == "reasoning" }
                .flatMap { $0["summary"] as? [[String: Any]] ?? [] }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            await recordThinking(thoughts, activity: &activity, onActivity: onActivity)
            let calls = outputs.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty {
                if let text = result["output_text"] as? String, !text.isEmpty { return text }
                return outputs.compactMap { ($0["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") }.joined(separator: "\n")
            }
            input += outputs
            for call in calls {
                let args = ((call["arguments"] as? String)?.data(using: .utf8)).flatMap { try? json($0) } ?? [:]
                let response = await tracedExecute(call["name"] as? String ?? "", args, conversation, activity: &activity, onActivity: onActivity)
                input.append(["type":"function_call_output", "call_id":call["call_id"] ?? "", "output":toolText(response)])
                let imageBlocks: [[String: Any]] = images(response).map { ["type":"input_image", "image_url":"data:\($0["mimeType"] ?? "image/jpeg");base64,\($0["data"] ?? "")"] }
                if !imageBlocks.isEmpty { input.append(["role":"user", "content":imageBlocks]) }
            }
        }
        throw AIModelToolError.invalidResponse("工具调用次数已达上限")
    }
    private static func fetchCatalog() async throws -> [[String: Any]] {
        let data = try await SharedAlbumsAPI.request("api/ai/tools")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    }
    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIModelToolError.invalidResponse("供应商返回了无法识别的数据") }
        return object
    }
    private static func api(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIModelToolError.invalidResponse("没有收到模型响应") }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? json(data))?["error"] as? [String: Any]
            throw AIModelToolError.invalidResponse(reason?["message"] as? String ?? "模型请求失败（\(http.statusCode)）")
        }
        return try json(data)
    }
    private static func recordThinking(_ text: String, activity: inout ChatActivity,
                                       onActivity: ChatActivityHandler?) async {
        guard !text.isEmpty else { return }
        let room = max(0, 64000 - activity.thinking.count)
        guard room > 0 else { return }
        if !activity.thinking.isEmpty { activity.thinking += "\n\n" }
        activity.thinking += String(text.prefix(room))
        await onActivity?(activity)
    }

    private static func tracedExecute(_ name: String, _ arguments: [String: Any],
                                      _ conversation: AIConversation, activity: inout ChatActivity,
                                      onActivity: ChatActivityHandler?) async -> [[String: Any]] {
        let id = UUID().uuidString
        let start = Date()
        activity.tools.append(ChatToolStep(id: id, name: name, status: "running", detail: visibleToolPurpose(name)))
        await onActivity?(activity)
        let output = await execute(name, arguments, conversation)
        if let index = activity.tools.firstIndex(where: { $0.id == id }) {
            activity.tools[index].status = output.contains { $0["__bear_error"] as? Bool == true } ? "failed" : "completed"
            activity.tools[index].elapsedMS = Date().timeIntervalSince(start) * 1000
        }
        await onActivity?(activity)
        return output
    }

    private static func visibleToolPurpose(_ name: String) -> String {
        switch name {
        case "web_search": return "联网搜索"
        case "web_open": return "打开网页阅读"
        case "memory_list": return "查看记忆"
        case "memory_add": return "记下一条记忆"
        case "memory_update": return "修改记忆卡"
        case "longterm_update": return "修改长期记忆"
        default: break
        }
        let value = name.lowercased()
        if value.contains("album") || value.contains("photo") { return "查看或处理相册图片" }
        if value.contains("memory") || value.contains("engram") { return "读取或更新长期记忆" }
        if value.contains("moment") { return "查看或更新朋友圈" }
        if value.contains("search") { return "搜索内容" }
        if value.contains("read") || value.contains("list") { return "读取内容" }
        if value.contains("write") || value.contains("save") || value.contains("update") { return "修改或保存内容" }
        return "调用此工具完成操作"
    }

    private static func execute(_ name: String, _ arguments: [String: Any], _ conversation: AIConversation) async -> [[String: Any]] {
        if LocalAITools.handles(name) { return await LocalAITools.execute(name, arguments, conversation) }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["conversation_id": conversation.id, "nickname": conversation.name, "name": name, "arguments": arguments])
            guard let base = SharedAlbumsAPI.base else {
                return [["type": "text", "text": "未设置服务器地址", "__bear_error": true]]
            }
            var req = URLRequest(url: base.appendingPathComponent("api/ai/call"))
            req.httpMethod = "POST"; req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (result, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let error = (try? json(result))?["error"] as? String ?? "共享功能暂不可用"
                return [["type": "text", "text": error, "__bear_error": true]]
            }
            let value = try json(result)
            var content = value["content"] as? [[String: Any]] ?? [["type": "text", "text": "工具没有返回内容"]]
            if value["isError"] as? Bool == true {
                content.append(["type": "text", "text": "", "__bear_error": true])
            }
            return content
        } catch { return [["type": "text", "text": "工具调用失败：\(error.localizedDescription)", "__bear_error": true]] }
    }
    private static func toolText(_ content: [[String: Any]]) -> String {
        content.map { ($0["text"] as? String) ?? ($0["type"] as? String == "image" ? "[已返回图片，请查看下一条视觉输入]" : "[附件]") }.joined(separator: "\n")
    }
    private static func images(_ content: [[String: Any]]) -> [[String: Any]] {
        content.filter { $0["type"] as? String == "image" && $0["data"] is String }
    }
    private static func userContent(_ message: LocalAIMessage, format: String) -> Any {
        var parts: [[String: Any]] = [["type": "text", "text": message.text]]
        for file in message.attachments ?? [] {
            guard let values = try? file.modelContent() else { continue }
            parts += values
        }
        if let stickerURL = message.stickerURL, let data = try? Data(contentsOf: stickerURL) {
            parts.append(["type":"image", "data": data.base64EncodedString(), "mimeType":"image/jpeg"])
        }
        if format == "anthropic" {
            return parts.compactMap { value -> [String: Any]? in
                if value["type"] as? String == "text" { return value }
                guard let data = value["data"] as? String else { return nil }
                return ["type": "image", "source": ["type": "base64", "media_type": value["mimeType"] ?? "image/jpeg", "data": data]]
            }
        }
        if format == "gemini" {
            return parts.map { value in
                if let text = value["text"] { return ["text": text] }
                return ["inlineData": ["mimeType": value["mimeType"] ?? "image/jpeg", "data": value["data"] ?? ""]]
            }
        }
        return parts.map { value in
            if let text = value["text"] { return ["type": "text", "text": text] }
            return ["type": "image_url", "image_url": ["url": "data:\(value["mimeType"] ?? "image/jpeg");base64,\(value["data"] ?? "")"]]
        }
    }

    // OpenAI-compatible SSE. A tool call is assembled before execution, while text deltas
    // are passed to the chat view immediately. Some gateways ignore stream:true and return
    // ordinary JSON; that response is handled as a fallback.
    private static func streamChatCompletion(
        _ request: URLRequest,
        onDelta: @Sendable (String) async -> Void
    ) async throws -> [String: Any] {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIModelToolError.invalidResponse("没有收到模型响应")
        }
        var fullText = ""
        var reasoningText = ""
        var rawLines: [String] = []
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        for try await line in bytes.lines {
            if !(200..<300).contains(http.statusCode) {
                if rawLines.joined().count < 2048 { rawLines.append(line) }
                continue
            }
            guard line.hasPrefix("data:") else {
                if !line.isEmpty && rawLines.joined().count < 4096 { rawLines.append(line) }
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (event["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            reasoningText += delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            if let text = delta["content"] as? String, !text.isEmpty {
                fullText += text
                await onDelta(text)
            }
            for item in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = item["index"] as? Int else { continue }
                var call = calls[index] ?? ("", "", "")
                if let id = item["id"] as? String { call.id += id }
                if let function = item["function"] as? [String: Any] {
                    if let name = function["name"] as? String { call.name += name }
                    if let arguments = function["arguments"] as? String { call.arguments += arguments }
                }
                calls[index] = call
            }
        }
        if !(200..<300).contains(http.statusCode) {
            let body = rawLines.joined(separator: "\n")
            let reason = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let detail = (reason?["error"] as? [String: Any])?["message"] as? String
            throw AIModelToolError.invalidResponse(detail ?? "模型请求失败（\(http.statusCode)）")
        }
        if fullText.isEmpty && calls.isEmpty,
           let data = rawLines.joined(separator: "\n").data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (result["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] {
            return message
        }
        var message: [String: Any] = ["role": "assistant", "content": fullText]
        if !reasoningText.isEmpty { message["reasoning_content"] = reasoningText }
        if !calls.isEmpty {
            message["tool_calls"] = calls.keys.sorted().compactMap { index -> [String: Any]? in
                guard let call = calls[index] else { return nil }
                return [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments]
                ]
            }
        }
        return message
    }

    static func send(messages fullHistory: [LocalAIMessage], conversation: AIConversation, apiKey: String,
                     groupID: String? = nil,
                     onActivity: ChatActivityHandler? = nil,
                     onDelta: (@Sendable (String) async -> Void)? = nil) async throws -> String {
        LocalAITools.stripStamp(try await sendCore(messages: fullHistory, conversation: conversation, apiKey: apiKey,
                                                   groupID: groupID, onActivity: onActivity, onDelta: onDelta))
    }

    private static func sendCore(messages fullHistory: [LocalAIMessage], conversation: AIConversation, apiKey: String,
                                 groupID: String?,
                                 onActivity: ChatActivityHandler?,
                                 onDelta: (@Sendable (String) async -> Void)?) async throws -> String {
        var activity = ChatActivity()
        // Memory: only the recent window goes out verbatim; older turns live on as memory cards.
        // Group replies (groupID set) still carry the member's own memory and tools; only
        // windowing and extraction are limited to the member's private chat.
        let privateChat = groupID == nil
        let memoryTools = MemoryEngine.isEligible(conversation) && MemorySettings.enabled(for: conversation.id)
        let windowed = privateChat ? MemoryEngine.window(fullHistory, conversation: conversation) : fullHistory
        let messages = LocalAITools.stamped(windowed)
        let memoryBlock = await MemoryEngine.contextBlock(for: windowed, conversation: conversation)
        if privateChat { MemoryEngine.scheduleExtraction(all: fullHistory, conversation: conversation, apiKey: apiKey) }
        let format = (conversation.interfaceFormat ?? "").lowercased()
        let catalog: [[String: Any]]
        // Chat remains usable offline from Moments, but we never advertise unavailable tools.
        do { catalog = try await fetchCatalog() + LocalAITools.catalog(memory: memoryTools) } catch { catalog = LocalAITools.catalog(memory: memoryTools) }
        let system = LocalAITools.timePreamble + "你在熊窝里的昵称是\(conversation.name)。你只有在真正调用工具并收到结果后才能说已查看、发布、评论或修改；没有工具时请说明需要在熊窝验证共享功能。自然地和用户对话。" + LocalAITools.toolHint(memory: memoryTools) + "\n\n\(MessageBubbleSplitter.promptInstruction)" + memoryBlock
        let normalized = (conversation.baseURL ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !apiKey.isEmpty else { throw AIModelToolError.invalidResponse("请先设置 API Key") }
        if format.contains("anthropic") {
            let endpoint = normalized.hasSuffix("/v1") ? normalized + "/messages" : normalized + "/v1/messages"
            guard let url = URL(string: endpoint) else { throw AIModelToolError.invalidResponse("Base URL 不正确") }
            var history: [[String: Any]] = messages.filter { $0.withdrawn != true }.map { m in ["role": m.role, "content": m.role == "user" ? userContent(m, format: "anthropic") : m.text] }
            for _ in 0..<8 {
                var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 120
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["model": conversation.model ?? "", "max_tokens": 2048, "system": system, "messages": history, "tools": catalog.map { ["name": $0["name"] ?? "", "description": $0["description"] ?? "", "input_schema": $0["inputSchema"] ?? [:]] }])
                let response = try await api(req), blocks = response["content"] as? [[String: Any]] ?? []
                let thoughts = blocks.filter { $0["type"] as? String == "thinking" }
                    .compactMap { $0["thinking"] as? String }.joined(separator: "\n")
                await recordThinking(thoughts, activity: &activity, onActivity: onActivity)
                let calls = blocks.filter { $0["type"] as? String == "tool_use" }
                if calls.isEmpty { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                history.append(["role": "assistant", "content": blocks])
                var results: [[String: Any]] = []
                for call in calls {
                    let output = await tracedExecute(call["name"] as? String ?? "", call["input"] as? [String: Any] ?? [:], conversation, activity: &activity, onActivity: onActivity)
                    var content: [[String: Any]] = [["type":"text", "text":toolText(output)]]
                    content += images(output).map { ["type":"image", "source":["type":"base64", "media_type":$0["mimeType"] ?? "image/jpeg", "data":$0["data"] ?? ""]] }
                    results.append(["type":"tool_result", "tool_use_id":call["id"] ?? "", "content":content])
                }
                history.append(["role":"user", "content":results])
            }
        } else if format.contains("gemini") {
            let endpoint = normalized.hasSuffix("/v1beta") ? normalized + "/models/\(conversation.model ?? ""):generateContent" : normalized + "/v1beta/models/\(conversation.model ?? ""):generateContent"
            guard var components = URLComponents(string: endpoint) else { throw AIModelToolError.invalidResponse("Base URL 不正确") }
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = components.url else { throw AIModelToolError.invalidResponse("Base URL 不正确") }
            var history: [[String: Any]] = messages.filter { $0.withdrawn != true }.map { ["role": $0.role == "assistant" ? "model" : "user", "parts": $0.role == "user" ? userContent($0, format: "gemini") : [["text":$0.text]]] }
            for _ in 0..<8 {
                var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 120
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["systemInstruction": ["parts": [["text":system]]], "contents":history, "tools": catalog.isEmpty ? [] : [["functionDeclarations":catalog.map { ["name":$0["name"] ?? "", "description":$0["description"] ?? "", "parameters":$0["inputSchema"] ?? [:]] }]]])
                let response = try await api(req)
                let content = (response["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any] ?? [:]
                let parts = content["parts"] as? [[String: Any]] ?? []
                let thoughts = parts.filter { $0["thought"] as? Bool == true }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                await recordThinking(thoughts, activity: &activity, onActivity: onActivity)
                let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
                if calls.isEmpty { return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                history.append(content) // preserve thoughtSignature in the original response
                var results: [[String: Any]] = []
                for call in calls {
                    let name = call["name"] as? String ?? ""
                    let output = await tracedExecute(name, call["args"] as? [String: Any] ?? [:], conversation, activity: &activity, onActivity: onActivity)
                    results.append(["functionResponse":["name":name, "response":["result":toolText(output)]]])
                    results += images(output).map { ["inlineData":["mimeType":$0["mimeType"] ?? "image/jpeg", "data":$0["data"] ?? ""]] }
                }
                history.append(["role":"user", "parts":results])
            }
        } else {
            let endpoint = normalized.hasSuffix("/v1") ? normalized + "/chat/completions" : normalized + "/chat/completions"
            guard let url = URL(string: endpoint) else { throw AIModelToolError.invalidResponse("Base URL 不正确") }
            var history: [[String: Any]] = [["role":"system", "content":system]]
            history += messages.filter { $0.withdrawn != true }.map { ["role":$0.role, "content":$0.role == "user" ? userContent($0, format:"openai") : $0.text] }
            for _ in 0..<8 {
                var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 120
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let compatibleTools: [[String: Any]] = catalog.map { item in
                    ["type":"function", "function": ["name":item["name"] ?? "", "description":item["description"] ?? "", "parameters":item["inputSchema"] ?? [:]]]
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model":conversation.model ?? "", "messages":history,
                    "stream":onDelta != nil, "tools":compatibleTools,
                    "metadata": groupID.map { ["group_id": $0] } ?? [:]
                ])
                let message: [String: Any]
                if let onDelta {
                    do {
                        message = try await streamChatCompletion(req, onDelta: onDelta)
                    } catch {
                        // A compatible endpoint may reject SSE. Keep that conversation usable.
                        req.httpBody = try JSONSerialization.data(withJSONObject: [
                            "model":conversation.model ?? "", "messages":history,
                            "stream":false, "tools":compatibleTools,
                            "metadata": groupID.map { ["group_id": $0] } ?? [:]
                        ])
                        let response = try await api(req)
                        message = (response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
                    }
                } else {
                    let response = try await api(req)
                    message = (response["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
                }
                let thoughts = message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
                await recordThinking(thoughts, activity: &activity, onActivity: onActivity)
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                if calls.isEmpty { return message["content"] as? String ?? "" }
                history.append(message)
                for call in calls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    let args = ((function["arguments"] as? String)?.data(using: .utf8)).flatMap { try? json($0) } ?? [:]
                    let output = await tracedExecute(function["name"] as? String ?? "", args, conversation, activity: &activity, onActivity: onActivity)
                    history.append(["role":"tool", "tool_call_id":call["id"] ?? "", "content":toolText(output)])
                    let imageBlocks = images(output).map { ["type":"image_url", "image_url":["url":"data:\($0["mimeType"] ?? "image/jpeg");base64,\($0["data"] ?? "")"]] }
                    if !imageBlocks.isEmpty { history.append(["role":"user", "content":imageBlocks]) }
                }
            }
        }
        throw AIModelToolError.invalidResponse("工具调用次数已达上限，请重新发送消息")
    }
}
