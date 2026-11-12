import SwiftUI
import UIKit

@MainActor
final class ConversationModel: ObservableObject {
    @Published var items: [TranscriptItem] = []
    @Published var approvals: [ApprovalRequest] = []
    @Published var nextCursor: String?
    @Published var activeTurn: String?
    @Published var controllable = false
    @Published var loading = true
    @Published var loadingOlder = false
    @Published var sending = false
    @Published var draft = ""
    @Published var photos: [PendingPhoto] = []
    @Published var settings = ComposerSettings()
    @Published var error: String?
    @Published var notice: String?
    @Published var followLatest = true
    @Published var showAll = false
    private var refreshing = false
    private var initializedCursor = false
    var updateMarker: String { (items.last?.id ?? "") + (items.last?.text ?? "") + approvals.map(\.id).joined() + (activeTurn ?? "") }

    func refresh(app: AppModel, thread: String, older: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; loading = false; loadingOlder = false }
        if older { loadingOlder = true }
        do {
            var args = ["op": "history_v2", "thread": thread]
            if older, let nextCursor { args["cursor"] = nextCursor }
            let page = try await app.request(args, as: HistoryPage.self)
            if older {
                let existing = Set(items.map(\.id))
                items = page.items.filter { !existing.contains($0.id) } + items
                nextCursor = page.nextCursor
            } else {
                let newIDs = Set(page.items.map(\.id))
                items = items.filter { !newIDs.contains($0.id) } + page.items
                if !initializedCursor { nextCursor = page.nextCursor; initializedCursor = true }
                approvals = page.approvals
                activeTurn = page.activeTurn
                controllable = page.controllable
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func send(app: AppModel, thread: String) async {
        guard !sending, (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) else { return }
        sending = true
        defer { sending = false }
        let sentText = draft
        let sentPhotos = photos
        do {
            var tokens: [String] = []
            for photo in sentPhotos { tokens.append(try await app.upload(photo.jpeg)) }
            var args = ["op": "turn", "thread": thread, "text": sentText, "requestID": UUID().uuidString,
                        "photos": String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)]
            args.merge(settings.requestFields) { _, new in new }
            let result = try await app.request(args, as: NoteResult.self)
            if draft == sentText { draft = "" }
            let sentIDs = Set(sentPhotos.map(\.id))
            photos.removeAll { sentIDs.contains($0.id) }
            notice = result.note
            followLatest = true
            app.saveSettings(settings, thread: thread)
            await refresh(app: app, thread: thread)
        } catch {
            self.error = error.localizedDescription + "\n若发送时断线，请先刷新会话确认结果，再决定是否重发。"
        }
    }
    func addPhoto(_ data: Data) throws {
        guard photos.count < 6, let image = UIImage(data: data) else { throw PocketError("最多添加 6 张可解码的图片") }
        let maxSide: CGFloat = 2048
        let ratio = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8), jpeg.count <= 8_000_000 else {
            throw PocketError("图片压缩后仍超过 8 MB")
        }
        photos.append(PendingPhoto(jpeg: jpeg))
    }
}
