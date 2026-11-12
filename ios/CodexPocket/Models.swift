import Foundation

struct ServerProfile: Codable {
    var host = ""
    var port = "22"
    var username = ""
    var hostPublicKey = ""
    var auth = "key"
    var bridgePath = "~/.local/lib/codex-pocket/bridge.py"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "server"),
              let profile = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return profile
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "server") }
}
struct Pane: Decodable, Identifiable {
    let id: String
    let session: String
    let command: String
    let managed: Bool
}
struct ThreadSummary: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }
}
struct ImageReference: Codable, Identifiable, Hashable {
    let id: String
    let source: String
    let local: Bool
}
struct TranscriptItem: Codable, Identifiable {
    let id: String
    let kind: String
    let turnID: String
    let role: String
    let title: String
    let text: String
    let detail: String
    let images: [ImageReference]
    let importance: String
    let status: String
    var questions: [AsyncQuestion]? = nil
    var alwaysVisible: Bool { importance != "collapsed" || !images.isEmpty }
}
struct AsyncQuestion: Codable {
    let title: String
    let options: [String]?
}
struct TimelineRow: Identifiable {
    let id: String
    let items: [TranscriptItem]
    var isGroup: Bool { items.count > 1 || (items.first?.importance == "collapsed" && items.first?.images.isEmpty == true) }
    static func build(_ items: [TranscriptItem], showAll: Bool) -> [Self] {
        if showAll { return items.map { Self(id: $0.id, items: [$0]) } }
        var rows: [Self] = []
        var pending: [TranscriptItem] = []
        func flush() {
            if let first = pending.first {
                rows.append(Self(id: "activity-" + first.id, items: pending))
                pending.removeAll()
            }
        }
        for item in items {
            if item.alwaysVisible { flush(); rows.append(Self(id: item.id, items: [item])) }
            else { pending.append(item) }
        }
        flush()
        return rows
    }
}
struct JSONValue: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode([String: JSONValue].self) { value = v.mapValues(\.value) }
        else if let v = try? c.decode([JSONValue].self) { value = v.map(\.value) }
        else { throw PocketError("无法解析服务器数据") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as [String: Any]: try c.encode(v.mapValues { JSONValue($0) })
        case let v as [Any]: try c.encode(v.map { JSONValue($0) })
        default: try c.encodeNil()
        }
    }
}
struct ApprovalRequest: Decodable, Identifiable {
    let id: String
    let threadID: String
    let method: String
    let params: [String: JSONValue]
    var dictionary: [String: Any] { params.mapValues(\.value) }
    var isQuestion: Bool { method == "item/tool/requestUserInput" }
    var supported: Bool {
        isQuestion || ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method)
    }
    var questions: [InputQuestion] {
        (dictionary["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let id = q["id"] as? String, let question = q["question"] as? String else { return nil }
            return InputQuestion(id: id, title: q["header"] as? String ?? "需要你的回答", question: question, isSecret: q["isSecret"] as? Bool ?? false,
                                 options: (q["options"] as? [[String: Any]] ?? []).compactMap { option in
                                     guard let label = option["label"] as? String else { return nil }
                                     return InputOption(label: label, description: option["description"] as? String ?? "")
                                 })
        }
    }
    var command: String? { dictionary["command"] as? String }
    var summary: String {
        dictionary["reason"] as? String ?? dictionary["command"] as? String ?? "Codex 请求确认后继续。"
    }
}
struct InputQuestion: Identifiable {
    let id: String
    let title: String
    let question: String
    let isSecret: Bool
    let options: [InputOption]
}
struct InputOption: Identifiable {
    let label: String
    let description: String
    var id: String { label }
}
struct ModelOption: Codable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [EffortOption]
    let serviceTiers: [TierOption]?
    let inputModalities: [String]?
    var fastTier: TierOption? { serviceTiers?.first { $0.name.lowercased() == "fast" } }
    var supportsImages: Bool { inputModalities?.contains("image") ?? true }
}
struct EffortOption: Codable, Identifiable {
    let reasoningEffort: String
    let description: String
    var id: String { reasoningEffort }
}
struct TierOption: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
}
struct ComposerSettings: Codable, Equatable {
    var model = ""
    var effort = ""
    var tier = ""
    var requestFields: [String: String] {
        ["model": model, "effort": effort, "tier": tier].filter { !$0.value.isEmpty }
    }
}
struct PendingPhoto: Identifiable {
    let id = UUID()
    let jpeg: Data
}
struct BridgeEnvelope<T: Decodable>: Decodable { let ok: Bool; let data: T?; let error: String? }
struct ServerStatus: Decodable { let version: String; let queue: Bool; let panes: [Pane] }
struct PanesResult: Decodable { let panes: [Pane] }
struct ThreadsResult: Decodable { let threads: [ThreadSummary]; let nextCursor: String? }
struct HistoryPage: Decodable {
    let items: [TranscriptItem]
    let nextCursor: String?
    let approvals: [ApprovalRequest]
    let activeTurn: String?
    let mode: String
    let controllable: Bool
}
struct ModelResult: Decodable { let models: [ModelOption]; let mode: String }
struct NewThreadResult: Decodable { let thread: ThreadSummary }
struct ScreenResult: Decodable { let text: String }
struct NoteResult: Decodable { let note: String }
struct UploadResult: Decodable { let token: String }
struct ImageResult: Decodable { let base64: String }
struct PocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
