import SwiftUI
import UIKit

struct ActivityGroup: View {
    let row: TimelineRow
    let thread: String
    var compose: ((String) -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(row.items) { item in TranscriptRow(item: item, thread: thread, expandedByDefault: true, compose: compose) }
            }.padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label("\(row.items.count) 项活动", systemImage: "checklist")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !expanded {
                    Text(row.items.prefix(3).map(\.title).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let thread: String
    var expandedByDefault = false
    var compose: ((String) -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.role == "user" { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 12) {
                if item.role == "assistant" {
                    Label("Codex", systemImage: "sparkle").font(.caption.bold()).foregroundStyle(.mint)
                    MarkdownBody(text: item.text)
                } else if item.role == "user" {
                    Text(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if !item.text.isEmpty { MarkdownBody(text: item.text) }
                        }.padding(.top, 8)
                    } label: {
                        Label(item.title, systemImage: item.importance == "attention" ? "exclamationmark.triangle" : "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(item.importance == "attention" ? Color.orange : Color.secondary)
                    }
                    .onAppear { expanded = expandedByDefault || item.importance == "attention" || item.kind == "plan" }
                }
                ForEach(item.images) { image in RemoteImageView(reference: image, thread: thread) }
                if let questions = item.questions {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(question.title).font(.subheadline.bold())
                            ForEach(question.options ?? [], id: \.self) { option in
                                Button(option) { compose?(question.title + "\n" + option) }.buttonStyle(.bordered)
                            }
                            Button("输入回答") { compose?(question.title + "\n") }.font(.caption)
                        }.padding(12).background(Color.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(item.role == "user" ? 15 : 0)
            .background(item.role == "user" ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 20))
            if item.role == "assistant" { Spacer(minLength: 6) }
        }
        .contextMenu {
            if !item.text.isEmpty {
                Button("复制文本", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
            }
        }
    }
}

struct MarkdownBody: View {
    let text: String
    var body: some View {
        let blocks = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index % 2 == 1 {
                    let parts = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let language = String(parts.first ?? "")
                    let code = parts.count > 1 ? String(parts[1]) : block
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "代码" : language).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = code }.font(.caption)
                        }.padding(10)
                        Divider()
                        ScrollView(.horizontal) {
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
                        }
                    }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                } else if !block.isEmpty {
                    Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct RemoteImageView: View {
    @EnvironmentObject var app: AppModel
    let reference: ImageReference
    let thread: String
    @State private var image: UIImage?
    @State private var error: String?
    @State private var preview = false
    @State private var retry = 0
    var body: some View {
        Group {
            if let image {
                Button { preview = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel("查看图片，支持缩放")
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Label("图片暂不可用", systemImage: "photo.badge.exclamationmark")
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }.padding(12)
            } else { ProgressView("加载图片…").frame(minHeight: 90) }
        }
        .task(id: retry) {
            do { image = try await app.image(reference, thread: thread); error = nil }
            catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $preview) {
            if let image { ImagePreview(image: image) }
        }
    }
}

struct ImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    var body: some View {
        NavigationStack {
            ZoomableImage(image: image).background(.black).ignoresSafeArea(edges: .bottom)
                .navigationTitle("图片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 6
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = view.bounds
        view.addSubview(imageView)
        context.coordinator.imageView = imageView
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        if view.zoomScale == 1 { context.coordinator.imageView?.frame = view.bounds }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

struct ApprovalCard: View {
    @EnvironmentObject var app: AppModel
    let request: ApprovalRequest
    @State private var answers: [String: String] = [:]
    @State private var submitting = false
    @State private var error: String?
    private func submit(decision: String? = nil) async {
        submitting = true
        defer { submitting = false }
        do {
            var args = ["op": "answer", "thread": request.threadID, "approval": request.id, "requestID": UUID().uuidString]
            if let decision { args["decision"] = decision }
            else {
                let response = answers.mapValues { ["answers": [$0]] }
                args["answers"] = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            }
            _ = try await app.request(args, as: NoteResult.self)
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.isQuestion ? "需要你的回答" : "需要你的确认", systemImage: "hand.raised")
                .font(.headline).foregroundStyle(.orange)
            if request.isQuestion {
                ForEach(request.questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.question)
                        ForEach(question.options) { option in
                            Button { answers[question.id] = option.label } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: answers[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(option.label).multilineTextAlignment(.leading)
                                        if !option.description.isEmpty { Text(option.description).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        if question.isSecret {
                            SecureField("输入你的回答", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField("输入你的回答", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Button("提交回答") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || request.questions.isEmpty || request.questions.contains { answers[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false })
            } else {
                Text(request.summary).textSelection(.enabled)
                if let command = request.command, command != request.summary {
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if request.supported {
                    HStack {
                        Button("允许这次") { Task { await submit(decision: "accept") } }.buttonStyle(.borderedProminent)
                        Button("拒绝", role: .destructive) { Task { await submit(decision: "decline") } }.buttonStyle(.bordered)
                    }.disabled(submitting)
                } else {
                    Text("该类型需在原 Codex 客户端处理。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if submitting { ProgressView() }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.25)))
    }
}
