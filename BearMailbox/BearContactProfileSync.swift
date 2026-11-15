import Foundation
import Combine

/// Keeps the locally displayed contact profile (my name, assistant remark,
/// pat suffix) in one place. The open-source build has no server to sync
/// these to: the profile sync used to go through the removed terminal
/// service, so scheduling now only records the latest local values.
@MainActor
final class BearContactProfileSync: ObservableObject {
    static let shared = BearContactProfileSync()
    @Published private(set) var status = ""
    private var lastSent: Data?

    func schedule(force: Bool = false) {
        let defaults = UserDefaults.standard
        func name(_ key: String, fallback: String) -> String {
            let value = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? fallback : value
        }
        let profile = [
            "assistantRemark": name("assistantRemark", fallback: "助手"),
            "patSuffix": defaults.string(forKey: "patSuffix") ?? "并给他两个亿",
            "myNickname": name("myNickname", fallback: "我")
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: profile, options: .sortedKeys),
              force || data != lastSent else { return }
        lastSent = data
        status = "备注已保存在本机"
    }
}
