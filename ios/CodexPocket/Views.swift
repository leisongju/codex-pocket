import SwiftUI
import UIKit

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var publicKey = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.largeTitle).foregroundStyle(.mint)
                        Text("服务器上的 Codex，\n口袋里的对话。")
                            .font(.title2.bold())
                        Text("通过 SSH 直连你的服务器，继续已有对话。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section("服务器") {
                    TextField("公网 IP 或域名", text: $model.profile.host)
                        .keyboardType(.URL)
                    TextField("SSH 端口", text: $model.profile.port).keyboardType(.numberPad)
                    TextField("登录用户名", text: $model.profile.username)
                }
                Section("登录方式") {
                    Picker("认证", selection: $model.profile.auth) {
                        Text("本机密钥").tag("key")
                        Text("密码").tag("password")
                    }.pickerStyle(.segmented)
                    if model.profile.auth == "password" {
                        SecureField("SSH 密码（保存到钥匙串）", text: $model.password)
                        Text("仅支持服务器启用的密码认证；暂不支持交互式 MFA。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("将下方公钥添加到服务器用户的 ~/.ssh/authorized_keys。私钥保存在此 iPhone 的钥匙串。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("复制本机公钥", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = publicKey
                        }.disabled(publicKey.isEmpty)
                    }
                }
                Section {
                    TextField("ssh-ed25519 AAAA…", text: $model.profile.hostPublicKey, axis: .vertical)
                        .font(.system(.caption, design: .monospaced))
                } header: { Text("服务器主机公钥") } footer: {
                    Text("在已信任的服务器连接中执行 cat /etc/ssh/ssh_host_ed25519_key.pub，粘贴完整一行。用于核验服务器身份。")
                }
                DisclosureGroup("高级设置") {
                    TextField("桥接脚本路径", text: $model.profile.bridgePath)
                        .font(.system(.caption, design: .monospaced))
                }
                Section {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.connecting { ProgressView() }
                            Text(model.connecting ? "正在连接…" : "连接服务器").bold()
                            Spacer()
                        }
                    }.disabled(model.connecting)
                }
                Section {
                    Button("先预览聊天界面", systemImage: "play.rectangle") { model.preview() }
                    Text("演示数据与真实服务器分开，预览不发送任何消息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("Codex Pocket")
            .task {
                do { publicKey = try Secrets.publicKey() }
                catch { model.error = error.localizedDescription }
            }
        }
    }
}

struct PanesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section {
                ForEach(model.panes) { pane in
                    NavigationLink { PaneView(pane: pane) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(pane.session) · \(pane.id)")
                            Text("\(pane.command) · \(pane.managed ? "已启用输入" : "仅查看")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("仅显示同一 SSH 用户的 tmux 窗格。使用服务器上的 codex-pocket 启动 Codex 后可在此操作。")
            }
        }
        .navigationTitle("终端辅助")
        .refreshable { await model.refreshPanes() }
        .task { await model.refreshPanes() }
    }
}

struct PaneView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let pane: Pane
    @State private var screen = ""
    @State private var busy = false
    @State private var interrupt = false
    @State private var draft = ""
    private func refresh() async {
        do { screen = try await model.request(["op": "screen", "pane": pane.id], as: ScreenResult.self).text }
        catch { screen = error.localizedDescription }
    }
    private func operate(key: String? = nil) async {
        busy = true
        defer { busy = false }
        do {
            var args = ["op": key == nil ? "send" : "key", "pane": pane.id, "requestID": UUID().uuidString]
            if let key { args["key"] = key } else { args["text"] = draft }
            _ = try await model.request(args, as: NoteResult.self)
            if key == nil { draft = "" }
            await refresh()
        } catch { model.error = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 8) {
            ScrollView([.vertical, .horizontal]) {
                Text(screen).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            if pane.managed {
                HStack {
                    ForEach(["Up", "Down", "Tab", "Escape", "Enter"], id: \.self) { key in
                        Button(key) { Task { await operate(key: key) } }.font(.caption)
                    }
                    Button("中断", role: .destructive) { interrupt = true }.font(.caption)
                }.disabled(busy)
                HStack {
                    TextField("发送到终端", text: $draft, axis: .vertical).lineLimit(1...4)
                    Button("发送") { Task { await operate() } }.disabled(busy || draft.isEmpty)
                }.padding().background(.bar)
            }
        }
        .navigationTitle(pane.session)
        .confirmationDialog("向此 Codex 终端发送 Ctrl-C？", isPresented: $interrupt) {
            Button("发送 Ctrl-C", role: .destructive) { Task { await operate(key: "C-c") } }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}
