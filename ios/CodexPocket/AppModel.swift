import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var profile = ServerProfile.load()
    @Published var password = ""
    @Published var connected = false
    @Published var connecting = false
    @Published var demo = false
    @Published var status: ServerStatus?
    @Published var panes: [Pane] = []
    @Published var threads: [ThreadSummary] = []
    @Published var models: [ModelOption] = []
    @Published var selectedThreadID: String?
    @Published var selectedProject = ""
    @Published var nextCursor: String?
    @Published var error: String?
    @Published var catalogError: String?
    @Published var extraProjects = UserDefaults.standard.stringArray(forKey: "projects") ?? []
    let bridge = SSHBridge()
    let imageCache = NSCache<NSString, NSData>()
    var projectPaths: [String] { Array(Set(threads.map(\.cwd) + extraProjects)).filter { !$0.isEmpty }.sorted() }
    var selectedThread: ThreadSummary? { threads.first { $0.id == selectedThreadID } }

    init() { imageCache.totalCostLimit = 32 * 1024 * 1024 }
    func request<T: Decodable>(_ fields: [String: String], as: T.Type) async throws -> T {
        if demo { return try DemoData.response(fields, as: T.self) }
        return try await bridge.request(fields, as: T.self)
    }
    func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            var credential = password
            if profile.auth == "password", credential.isEmpty,
               let data = try Secrets.read(Secrets.passwordName(profile)) {
                credential = String(decoding: data, as: UTF8.self)
            }
            try await bridge.connect(profile, password: credential)
            let result = try await bridge.request(["op": "status"], as: ServerStatus.self)
            try profile.save()
            if profile.auth == "password" {
                try Secrets.write(Data(credential.utf8), name: Secrets.passwordName(profile))
            }
            password = ""; status = result; panes = result.panes
            connected = true; demo = false
        } catch { await bridge.disconnect(); self.error = error.localizedDescription }
    }
    func preview() { demo = true; connected = true; catalogError = nil }
    func disconnect() async {
        connected = false; demo = false; selectedThreadID = nil; selectedProject = ""
        panes = []; threads = []; models = []; nextCursor = nil; status = nil
        imageCache.removeAllObjects()
        await bridge.disconnect()
    }
    func refreshPanes() async {
        do { panes = try await request(["op": "panes"], as: PanesResult.self).panes }
        catch { self.error = error.localizedDescription }
    }
    func refreshThreads(more: Bool = false) async {
        do {
            var args = ["op": "threads"]
            if more, let nextCursor { args["cursor"] = nextCursor }
            let result = try await request(args, as: ThreadsResult.self)
            if more {
                let existing = Set(threads.map(\.id))
                threads += result.threads.filter { !existing.contains($0.id) }
            } else { threads = result.threads }
            nextCursor = result.nextCursor
        } catch { self.error = error.localizedDescription }
    }
    func refreshModels() async {
        do {
            models = try await request(["op": "models"], as: ModelResult.self).models
            catalogError = nil
        } catch { catalogError = error.localizedDescription }
    }
    func addProject(_ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !extraProjects.contains(cleaned) { extraProjects.append(cleaned) }
        UserDefaults.standard.set(extraProjects, forKey: "projects")
        selectedProject = cleaned
    }
    func newThread(cwd: String, settings: ComposerSettings) async throws {
        var args = ["op": "new_thread", "cwd": cwd, "requestID": UUID().uuidString]
        args.merge(settings.requestFields) { _, new in new }
        let result = try await request(args, as: NewThreadResult.self)
        threads.insert(result.thread, at: 0)
        selectedProject = result.thread.cwd
        selectedThreadID = result.thread.id
        saveSettings(settings, thread: result.thread.id)
    }
    func settings(thread: String) -> ComposerSettings {
        guard let data = UserDefaults.standard.data(forKey: "composer:" + thread),
              let settings = try? JSONDecoder().decode(ComposerSettings.self, from: data) else { return .init() }
        return settings
    }
    func saveSettings(_ settings: ComposerSettings, thread: String) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "composer:" + thread) }
    }
    func image(_ image: ImageReference, thread: String) async throws -> UIImage {
        let cacheKey = (thread + image.id) as NSString
        if let data = imageCache.object(forKey: cacheKey), let uiImage = UIImage(data: data as Data) { return uiImage }
        let data: Data
        if image.source.hasPrefix("bundle:") {
            guard let url = Bundle.main.url(forResource: String(image.source.dropFirst(7)), withExtension: "png") else {
                throw PocketError("演示图片缺失")
            }
            data = try Data(contentsOf: url)
        } else if image.local {
            let result = try await request(["op": "image", "thread": thread, "asset": image.source], as: ImageResult.self)
            guard let decoded = Data(base64Encoded: result.base64) else { throw PocketError("图片数据损坏") }
            data = decoded
        } else if image.source.hasPrefix("data:image/"), let comma = image.source.firstIndex(of: ",") {
            guard let decoded = Data(base64Encoded: String(image.source[image.source.index(after: comma)...])) else {
                throw PocketError("图片编码无效")
            }
            data = decoded
        } else {
            guard let url = URL(string: image.source), url.scheme == "https" else {
                throw PocketError("仅自动加载 HTTPS 图片")
            }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw PocketError("图片服务器返回 \(response.statusCode)")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw PocketError("图片超过 8 MB") }
            data = try Data(contentsOf: temporary)
        }
        guard data.count <= 8_000_000, let uiImage = UIImage(data: data) else { throw PocketError("无法显示此图片格式") }
        imageCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return uiImage
    }
    func upload(_ data: Data) async throws -> String {
        let prepared = try await request(["op": "upload_prepare"], as: UploadResult.self)
        for offset in stride(from: 0, to: data.count, by: 36000) {
            try Task.checkCancellation()
            let chunk = data.subdata(in: offset..<min(offset + 36000, data.count))
            _ = try await request(["op": "upload_chunk", "token": prepared.token,
                                   "offset": String(offset), "data": chunk.base64EncodedString()], as: NoteResult.self)
        }
        return prepared.token
    }
}

@main
struct CodexPocketApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if model.connected { HomeView() } else { ConnectionView() }
            }
            .environmentObject(model).tint(.mint)
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}
