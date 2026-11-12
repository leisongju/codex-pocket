import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let thread: ThreadSummary
    @StateObject private var chat = ConversationModel()
    @State private var settingsSheet = false
    @State private var voiceSheet = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var interrupt = false
    @FocusState private var composing: Bool
    var selectedModel: ModelOption? { app.models.first { $0.model == chat.settings.model } }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if chat.nextCursor != nil {
                            Button { chat.followLatest = false; Task { await chat.refresh(app: app, thread: thread.id, older: true) } } label: {
                                HStack { if chat.loadingOlder { ProgressView() }; Text("加载更早的记录") }
                                    .frame(maxWidth: .infinity)
                            }.disabled(chat.loadingOlder)
                        }
                        if chat.loading { ProgressView("正在读取对话…").frame(maxWidth: .infinity) }
                        if !chat.loading && chat.items.isEmpty {
                            ContentUnavailableView("开始对话", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("在下方输入消息，也可以添加图片。"))
                        }
                        ForEach(TimelineRow.build(chat.items, showAll: chat.showAll)) { row in
                            if row.isGroup && !chat.showAll {
                                ActivityGroup(row: row, thread: thread.id, compose: { chat.draft = $0; composing = true })
                            } else if let item = row.items.first {
                                TranscriptRow(item: item, thread: thread.id, compose: { chat.draft = $0; composing = true })
                            }
                        }
                        ForEach(chat.approvals) { request in
                            ApprovalCard(request: request)
                        }
                        if let notice = chat.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if chat.activeTurn != nil {
                            HStack { ProgressView(); Text("Codex 正在处理…").font(.caption).foregroundStyle(.secondary) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 820).padding(.horizontal, geometry.size.width < 400 ? 14 : 24)
                    .padding(.vertical, 20).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in chat.followLatest = false })
                .overlay(alignment: .bottomTrailing) {
                    if !chat.followLatest {
                        Button {
                            chat.followLatest = true
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()) }
                        .padding(16).accessibilityLabel("回到最新消息")
                    }
                }
                .onChange(of: chat.updateMarker) { _, _ in
                    if chat.followLatest { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: composing) { _, focused in
                    if focused && chat.followLatest { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(String(thread.title.prefix(32))).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("显示全部活动", isOn: $chat.showAll)
                    Button("模型与强度", systemImage: "slider.horizontal.3") { settingsSheet = true }
                    Button("刷新对话", systemImage: "arrow.clockwise") { Task { await chat.refresh(app: app, thread: thread.id) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $settingsSheet) {
            NavigationStack {
                Form {
                    ModelSettingsFields(settings: $chat.settings)
                        .disabled(chat.activeTurn != nil || !chat.controllable)
                    Section {
                        Text(chat.controllable ? "选项应用到下一次发送，不改写历史消息。" : "此会话当前仅支持文字入队；模型与图片需要共享服务连接或手机新建会话。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("对话设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") {
                    app.saveSettings(chat.settings, thread: thread.id); settingsSheet = false
                } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $voiceSheet) {
            VoiceInputSheet { text in
                chat.draft = VoiceDraft.append(text, to: chat.draft)
                composing = true
            }
        }
        .confirmationDialog("停止当前轮次？", isPresented: $interrupt) {
            Button("停止", role: .destructive) {
                Task {
                    do { _ = try await app.request(["op": "interrupt", "thread": thread.id, "requestID": UUID().uuidString], as: NoteResult.self) }
                    catch { chat.error = error.localizedDescription }
                }
            }
        }
        .onChange(of: selectedPhotos) { _, selections in
            guard !selections.isEmpty else { return }
            importing = true
            Task {
                defer { selectedPhotos = []; importing = false }
                do {
                    for selection in selections {
                        if let data = try await selection.loadTransferable(type: Data.self) { try chat.addPhoto(data) }
                    }
                } catch { chat.error = error.localizedDescription }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            chat.settings = app.settings(thread: thread.id)
            while !Task.isCancelled {
                await chat.refresh(app: app, thread: thread.id)
                do { try await Task.sleep(for: .milliseconds(chat.activeTurn == nil ? 2500 : 800)) } catch { break }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let error = chat.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(4)
                    Spacer()
                    Button("关闭", systemImage: "xmark.circle") { chat.error = nil }.labelStyle(.iconOnly)
                }
            }
            if !chat.photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.photos) { photo in
                            if let image = UIImage(data: photo.jpeg) {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .topTrailing) {
                                        Button { chat.photos.removeAll { $0.id == photo.id } } label: {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black)
                                        }.accessibilityLabel("移除图片")
                                    }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: max(1, 6 - chat.photos.count), matching: .images) {
                    Image(systemName: "plus.circle").font(.title2).padding(.vertical, 9)
                }.disabled(importing || chat.sending || !chat.controllable || chat.photos.count >= 6 || selectedModel?.supportsImages == false)
                    .accessibilityLabel("添加图片")
                TextField("给 Codex 发消息", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...8).focused($composing).padding(.vertical, 10)
                    .accessibilityLabel("消息输入框")
                Button {
                    composing = false
                    voiceSheet = true
                } label: {
                    Image(systemName: "mic").font(.title2).padding(.vertical, 9)
                }
                .disabled(chat.sending || importing)
                .accessibilityLabel("语音输入")
                if chat.activeTurn != nil {
                    Button { interrupt = true } label: { Image(systemName: "stop.circle.fill").font(.system(size: 30)) }
                        .disabled(!chat.controllable).padding(.vertical, 4).accessibilityLabel("停止生成")
                }
                Button { Task { await chat.send(app: app, thread: thread.id) } } label: {
                    if chat.sending || importing { ProgressView().frame(width: 34, height: 34) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
                }
                .padding(.vertical, 3)
                .disabled(chat.sending || importing || (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.photos.isEmpty))
                .accessibilityLabel("发送消息")
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
            HStack {
                Button { settingsSheet = true } label: {
                    HStack(spacing: 5) {
                        Text(selectedModel?.displayName ?? "沿用会话")
                        if !chat.settings.effort.isEmpty { Text("· \(chat.settings.effort)") }
                        if let fast = selectedModel?.fastTier, chat.settings.tier == fast.id {
                            Image(systemName: "bolt.fill"); Text("Fast")
                        }
                        Image(systemName: "chevron.down")
                    }.font(.caption).lineLimit(1)
                }
                Spacer()
                Text(app.demo ? "演示数据" : "SSH 加密连接").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: 860)
        .frame(maxWidth: .infinity).background(.bar)
    }
}
