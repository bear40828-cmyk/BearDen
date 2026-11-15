import Foundation
import Combine

/// Keeps the locally displayed contact profile (my name, assistant remark, pat suffix) in one
/// place and, when a workbench server is configured, pushes it to PUT /api/terminal/chat-profile.
/// The wire format keeps the older `claudeRemark` field name for server compatibility.
@MainActor
final class BearContactProfileSync: ObservableObject {
    static let shared = BearContactProfileSync()
    @Published private(set) var status = ""
    private var lastSent: Data?
    private var task: Task<Void, Never>?

    func schedule(force: Bool = false) {
        let defaults = UserDefaults.standard
        func name(_ key: String, fallback: String) -> String {
            let value = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? fallback : value
        }
        let remark = name("assistantRemark", fallback: "助手")
        let profile = [
            "assistantRemark": remark,
            "claudeRemark": remark,
            "patSuffix": defaults.string(forKey: "patSuffix") ?? "并给他两个亿",
            "myNickname": name("myNickname", fallback: "我")
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: profile, options: .sortedKeys),
              force || data != lastSent else { return }
        task?.cancel()
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                guard let request = WorkbenchAPI.request(path: "/api/terminal/chat-profile", method: "PUT", body: data) else {
                    lastSent = data
                    status = "备注已保存在本机"
                    return
                }
                status = "正在同步备注…"
                let (_, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    status = "备注尚未同步，联网后重试"; return
                }
                lastSent = data
                status = "备注已同步"
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { status = "备注尚未同步，联网后重试" }
            }
        }
    }
}
