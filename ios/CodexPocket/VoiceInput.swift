import SwiftUI
import UIKit
import Foundation
import Speech
import AVFoundation

// Speech stays separate from transport: recognizing or accepting text never sends a turn.
enum VoiceDraft {
    static func append(_ dictated: String, to existing: String) -> String {
        let text = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return existing }
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return existing + (existing.last?.isWhitespace == true ? "" : "\n") + text
    }
}

enum DictationError: LocalizedError {
    case microphoneDenied, speechDenied, unavailable, noInput, interrupted, sessionCancelled
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "未获得麦克风权限。可到系统设置中允许 Codex Pocket 使用麦克风。"
        case .speechDenied: return "未获得语音识别权限。可到系统设置中允许语音识别。"
        case .unavailable: return "当前语言的语音识别暂不可用。请检查网络、设备上的语言支持，或换一种语言重试。"
        case .noInput: return "没有可用的麦克风。请检查音频设备后重试。"
        case .interrupted: return "录音已被系统或音频设备变化中断，已识别的文字会保留。"
        case .sessionCancelled: return "录音已取消。"
        }
    }
    var needsSettings: Bool {
        switch self { case .microphoneDenied, .speechDenied: return true; default: return false }
    }
}

@MainActor
protocol DictationEngine: AnyObject {
    func start(locale: Locale, update: @escaping (String) -> Void,
               meter: @escaping (Float) -> Void, completion: @escaping (Error?) -> Void) async throws -> Bool
    func finish()
    func cancel()
}

@MainActor
final class AppleDictationEngine: DictationEngine {
    private let audio = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var sessionActive = false
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var onCompletion: ((Error?) -> Void)?

    func start(locale: Locale, update: @escaping (String) -> Void,
               meter: @escaping (Float) -> Void, completion: @escaping (Error?) -> Void) async throws -> Bool {
        cancel()
        let token = generation
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { throw CancellationError() }
        guard speechStatus == .authorized else { throw DictationError.speechDenied }
        let microphone = await withCheckedContinuation { continuation in
            // Deployment target includes iOS 17. The completion API also works on this baseline.
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == token else { throw CancellationError() }
        guard microphone else { throw DictationError.microphoneDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw DictationError.unavailable }
        let onDevice = recognizer.supportsOnDeviceRecognition
        guard recognizer.isAvailable || onDevice else { throw DictationError.unavailable }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice
        self.request = request
        self.onCompletion = completion
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            sessionActive = true
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                var sum: Float = 0
                if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                    let level = min(1, sqrt(sum / Float(buffer.frameLength)) * 12)
                    Task { @MainActor [weak self] in
                        guard self?.generation == token else { return }
                        meter(level)
                    }
                }
            }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Take a value snapshot before leaving the recognition callback queue.
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    if let text { update(text) }
                    if final { completion(nil) }
                    else if let error { completion(error) }
                }
            }
            observeInterruptions(token: token)
            audio.prepare()
            try audio.start()
            return onDevice
        } catch {
            cancel()
            throw error
        }
    }
    private func observeInterruptions(token: UUID) {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                 object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onCompletion?(DictationError.interrupted)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onCompletion?(DictationError.interrupted)
            }
        })
    }
    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
    func finish() {
        stopAudio()
        request?.endAudio()
    }
    func cancel() {
        generation = UUID()
        stopAudio()
        task?.cancel(); task = nil
        request = nil; recognizer = nil; onCompletion = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

@MainActor
final class VoiceInputModel: ObservableObject {
    enum Phase: Equatable { case idle, authorizing, recording, finishing, review, failed }
    @Published private(set) var phase: Phase = .idle
    @Published var transcript = ""
    @Published private(set) var error: String?
    @Published private(set) var needsSettings = false
    @Published private(set) var onDevice = false
    @Published private(set) var seconds: TimeInterval = 0
    @Published private(set) var levels = Array(repeating: Float(0), count: 32)
    @Published var language = UserDefaults.standard.string(forKey: "dictation-language") ?? "zh-CN"
    private let engine: DictationEngine
    private var generation = UUID()
    private var tick: Task<Void, Never>?
    private var finishTimeout: Task<Void, Never>?
    var busy: Bool { phase == .authorizing || phase == .recording || phase == .finishing }
    var canUseText: Bool { !busy && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var status: String {
        switch phase {
        case .idle: return "准备好后开始说话"
        case .authorizing: return "正在准备语音输入…"
        case .recording: return "正在听…"
        case .finishing: return "正在完成转写…"
        case .review: return "检查文字后加入输入框"
        case .failed: return "语音输入暂不可用"
        }
    }
    static var languages: [(id: String, name: String)] {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })
        let preferred = ["zh-CN", "en-US", "zh-TW", "zh-HK", "yue-CN", "yue-HK"]
        let candidates = preferred.filter { supported.contains($0) }
        let ids = candidates.isEmpty ? supported.sorted() : candidates
        return ids.map { ($0, Locale(identifier: "zh-CN").localizedString(forIdentifier: $0) ?? $0) }
    }
    init(engine: DictationEngine? = nil) { self.engine = engine ?? AppleDictationEngine() }
    func start() async {
        guard !busy else { return }
        error = nil; needsSettings = false; seconds = 0
        levels = Array(repeating: 0, count: 32)
        let prefix = transcript
        let token = UUID()
        generation = token
        phase = .authorizing
        UserDefaults.standard.set(language, forKey: "dictation-language")
        do {
            let local = try await engine.start(locale: Locale(identifier: language), update: { [weak self] partial in
                guard let self, self.generation == token else { return }
                // Each partial replaces this segment, rather than appending it repeatedly.
                self.transcript = VoiceDraft.append(partial, to: prefix)
            }, meter: { [weak self] level in
                guard let self, self.generation == token else { return }
                self.levels.removeFirst(); self.levels.append(level)
            }, completion: { [weak self] failure in
                guard let self, self.generation == token else { return }
                self.complete(message: failure?.localizedDescription)
            })
            guard generation == token else { return }
            onDevice = local
            phase = .recording
            let started = Date()
            tick = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    guard let self, self.generation == token, self.phase == .recording else { break }
                    self.seconds = Date().timeIntervalSince(started)
                    if self.seconds >= 55 { self.stop(); break }
                }
            }
        } catch {
            guard generation == token else { return }
            engine.cancel()
            phase = .failed
            self.error = error.localizedDescription
            needsSettings = (error as? DictationError)?.needsSettings == true
        }
    }
    func stop() {
        guard phase == .recording else { return }
        phase = .finishing
        tick?.cancel(); tick = nil
        let token = generation
        engine.finish()
        guard generation == token, phase == .finishing else { return }
        finishTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, self.generation == token else { return }
            self.complete(message: "识别未及时完成，已保留当前转写文字。")
        }
    }
    private func complete(message: String?) {
        generation = UUID()
        tick?.cancel(); tick = nil
        finishTimeout?.cancel(); finishTimeout = nil
        engine.cancel()
        error = message
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .failed
            if error == nil { error = "没有识别到文字。请靠近麦克风，或换一种语言重试。" }
        } else { phase = .review }
    }
    func pauseForBackground() {
        guard busy else { return }
        complete(message: "离开前台后已停止录音，转写文字已保留。")
    }
    func cancel() {
        generation = UUID()
        tick?.cancel(); tick = nil
        finishTimeout?.cancel(); finishTimeout = nil
        engine.cancel()
        phase = .idle
    }
}

struct VoiceInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = VoiceInputModel()
    let commit: (String) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Image(systemName: voice.phase == .recording ? "mic.fill" : "waveform")
                            .font(.title).foregroundStyle(voice.phase == .recording ? Color.red : Color.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(voice.status).font(.headline)
                            Text(String(format: "%02d:%02d", Int(voice.seconds) / 60, Int(voice.seconds) % 60))
                                .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voice.phase == .authorizing || voice.phase == .finishing { ProgressView() }
                    }
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(Array(voice.levels.enumerated()), id: \.offset) { _, level in
                            Capsule().fill(voice.phase == .recording ? Color.mint : Color.secondary.opacity(0.3))
                                .frame(maxWidth: .infinity).frame(height: max(4, CGFloat(level) * 70))
                        }
                    }.frame(height: 80).accessibilityHidden(true)
                    Group {
                        if voice.busy {
                            Text(voice.transcript.isEmpty ? "说话后，文字会显示在这里…" : voice.transcript)
                                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        } else {
                            TextEditor(text: $voice.transcript).frame(minHeight: 150)
                                .scrollContentBackground(.hidden).accessibilityLabel("语音转写文字")
                        }
                    }.padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    if let error = voice.error {
                        Text(error).font(.callout).foregroundStyle(.orange)
                        if voice.needsSettings {
                            Button("打开系统设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    }
                    Picker("识别语言", selection: $voice.language) {
                        ForEach(VoiceInputModel.languages, id: \.id) { language in Text(language.name).tag(language.id) }
                    }.disabled(voice.busy)
                    if voice.phase == .recording {
                        Button { voice.stop() } label: {
                            Label("结束录音", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityLabel("结束语音录音")
                    } else if !voice.busy {
                        Button { Task { await voice.start() } } label: {
                            Label(voice.transcript.isEmpty ? "开始录音" : "继续录音", systemImage: "mic.fill")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large)
                    }
                    Text("每段最多 55 秒，可继续录音追加。转写不会自动发送，确认后会加入当前输入框。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(voice.busy && voice.phase != .authorizing ? (voice.onDevice ? "正在使用设备端语音识别。" : "正在使用 Apple 联网语音识别。") : "使用 iOS 语音识别，设备支持时优先本地处理；否则可能需要 Apple 的网络服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .navigationTitle("语音输入").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { voice.cancel(); dismiss() }.accessibilityLabel("取消语音输入")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用文字") {
                        let text = voice.transcript
                        voice.cancel(); commit(text); dismiss()
                    }.disabled(!voice.canUseText).accessibilityLabel("将语音文字加入输入框")
                }
            }
        }
        .interactiveDismissDisabled(voice.busy)
        .task {
            if !VoiceInputModel.languages.contains(where: { $0.id == voice.language }), let first = VoiceInputModel.languages.first {
                voice.language = first.id
            }
            await voice.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && voice.phase == .recording) { voice.pauseForBackground() }
        }
        .onDisappear { voice.cancel() }
    }
}
