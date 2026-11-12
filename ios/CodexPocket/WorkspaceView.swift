import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var projectSheet = false
    @State private var newChat = false
    @State private var disconnect = false
    var filtered: [ThreadSummary] {
        model.threads.filter {
            (model.selectedProject.isEmpty || $0.cwd == model.selectedProject) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.cwd.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedThreadID) {
                Section {
                    Button { projectSheet = true } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.selectedProject.isEmpty ? "全部项目" : URL(fileURLWithPath: model.selectedProject).lastPathComponent)
                                    .foregroundStyle(.primary).font(.headline)
                                Text(model.demo ? "演示模式" : model.profile.host)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "folder").foregroundStyle(.mint) }
                    }
                }
                Section("最近对话") {
                    ForEach(filtered) { thread in
                        NavigationLink(value: thread.id) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(thread.title).lineLimit(2)
                                Text(thread.projectName).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                    if filtered.isEmpty { Text("此项目暂无对话").foregroundStyle(.secondary) }
                    if model.nextCursor != nil {
                        Button("加载更多会话") { Task { await model.refreshThreads(more: true) } }
                    }
                }
                Section {
                    NavigationLink { PanesView() } label: { Label("终端辅助", systemImage: "terminal") }
                    Button(role: .destructive) { disconnect = true } label: {
                        Label(model.demo ? "退出演示" : "断开连接", systemImage: "network.slash")
                    }
                }
            }
            .navigationTitle("Codex Pocket")
            .searchable(text: $search, prompt: "搜索项目和对话")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("新对话", systemImage: "square.and.pencil") { newChat = true }
                }
            }
            .refreshable { await model.refreshThreads() }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let thread = model.selectedThread {
                ChatView(thread: thread).id(thread.id)
            } else {
                ContentUnavailableView {
                    Label("继续你的工作", systemImage: "bubble.left.and.bubble.right")
                } description: { Text("选择一个项目和对话，或新建对话。") } actions: {
                    Button("新建对话") { newChat = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $projectSheet) { ProjectPicker() }
        .sheet(isPresented: $newChat) { NewChatSheet() }
        .confirmationDialog("断开手机连接后，服务器任务仍可能继续运行。", isPresented: $disconnect) {
            Button(model.demo ? "退出演示" : "断开 SSH", role: .destructive) { Task { await model.disconnect() } }
        }
        .task {
            await model.refreshThreads()
            await model.refreshModels()
        }
    }
}

struct ProjectPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    var body: some View {
        NavigationStack {
            List {
                Button("全部项目") { model.selectedProject = ""; dismiss() }
                Section("服务器上的项目") {
                    ForEach(model.projectPaths, id: \.self) { project in
                        Button {
                            model.selectedProject = project; dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(URL(fileURLWithPath: project).lastPathComponent)
                                Text(project).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("添加项目路径") {
                    TextField("/home/用户名/项目目录", text: $path)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加并选择") { model.addProject(path); dismiss() }
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("选择项目").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct NewChatSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var settings = ComposerSettings()
    @State private var creating = false
    var body: some View {
        NavigationStack {
            Form {
                Section("项目目录") {
                    TextField("服务器上的项目绝对路径", text: $cwd)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !model.projectPaths.isEmpty {
                        Picker("最近项目", selection: $cwd) {
                            Text("手动填写").tag(cwd)
                            ForEach(model.projectPaths, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                ModelSettingsFields(settings: $settings)
                Section {
                    Button {
                        creating = true
                        Task {
                            do { try await model.newThread(cwd: cwd, settings: settings); dismiss() }
                            catch { model.error = error.localizedDescription }
                            creating = false
                        }
                    } label: {
                        HStack { Text("创建对话"); if creating { Spacer(); ProgressView() } }
                    }.disabled(creating || cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("新建对话").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { cwd = model.selectedProject.isEmpty ? (model.projectPaths.first ?? "") : model.selectedProject }
        }
    }
}

struct ModelSettingsFields: View {
    @EnvironmentObject var model: AppModel
    @Binding var settings: ComposerSettings
    var selected: ModelOption? { model.models.first { $0.model == settings.model } }
    var body: some View {
        Section("模型与推理") {
            Picker("模型", selection: $settings.model) {
                Text("沿用会话设置").tag("")
                ForEach(model.models) { item in Text(item.displayName).tag(item.model) }
            }
            .onChange(of: settings.model) { _, _ in
                settings.effort = selected?.defaultReasoningEffort ?? ""
                settings.tier = ""
            }
            Picker("推理强度", selection: $settings.effort) {
                Text("默认").tag("")
                ForEach(selected?.supportedReasoningEfforts ?? []) { effort in
                    Text(effort.reasoningEffort.capitalized).tag(effort.reasoningEffort)
                }
            }.disabled(selected == nil)
            if let description = selected?.supportedReasoningEfforts.first(where: { $0.reasoningEffort == settings.effort })?.description {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Fast", isOn: Binding(get: {
                guard let tier = selected?.fastTier else { return false }
                return settings.tier == tier.id
            }, set: { enabled in
                settings.tier = enabled ? (selected?.fastTier?.id ?? "") : "default"
            })).disabled(selected?.fastTier == nil)
            if let fast = selected?.fastTier { Text(fast.description).font(.caption).foregroundStyle(.secondary) }
            else { Text("仅在服务器为所选模型提供 Fast 时可用。").font(.caption).foregroundStyle(.secondary) }
        }
        if let error = model.catalogError {
            Section {
                Text("模型列表读取失败：\(error)").font(.caption).foregroundStyle(.orange)
                Button("重新读取模型") { Task { await model.refreshModels() } }
            }
        }
    }
}
