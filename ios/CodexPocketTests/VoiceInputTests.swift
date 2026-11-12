import XCTest
@testable import CodexPocket

@MainActor
final class FakeDictationEngine: DictationEngine {
    var update: ((String) -> Void)?
    var completion: ((Error?) -> Void)?
    var startFailure: Error?
    var finished = false
    var cancelled = false
    var completeImmediatelyOnFinish = false
    var delayedStart: CheckedContinuation<Bool, Error>?
    var delayStart = false
    func start(locale: Locale, update: @escaping (String) -> Void,
               meter: @escaping (Float) -> Void, completion: @escaping (Error?) -> Void) async throws -> Bool {
        self.update = update; self.completion = completion
        if let startFailure { throw startFailure }
        if delayStart { return try await withCheckedThrowingContinuation { delayedStart = $0 } }
        return true
    }
    func finish() {
        finished = true
        if completeImmediatelyOnFinish { completion?(nil) }
    }
    func cancel() { cancelled = true }
}

@MainActor
final class VoiceInputTests: XCTestCase {
    func testPartialTranscriptsReplaceRatherThanDuplicate() async {
        let engine = FakeDictationEngine()
        let voice = VoiceInputModel(engine: engine)
        await voice.start()
        engine.update?("你好")
        engine.update?("你好世界")
        XCTAssertEqual(voice.transcript, "你好世界")
        XCTAssertEqual(voice.phase, .recording)
        XCTAssertFalse(voice.canUseText)
        voice.stop()
        XCTAssertTrue(engine.finished)
        XCTAssertEqual(voice.phase, .finishing)
        engine.completion?(nil)
        XCTAssertEqual(voice.phase, .review)
        XCTAssertTrue(voice.canUseText)
        voice.cancel()
    }
    func testCancelIgnoresLateRecognitionCallback() async {
        let engine = FakeDictationEngine()
        let voice = VoiceInputModel(engine: engine)
        await voice.start()
        engine.update?("保留的草稿")
        let lateUpdate = engine.update
        let lateCompletion = engine.completion
        voice.cancel()
        lateUpdate?("不能写回的过期识别")
        lateCompletion?(DictationError.interrupted)
        XCTAssertEqual(voice.transcript, "保留的草稿")
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertTrue(engine.cancelled)
    }
    func testAdditionalSegmentPreservesEditedText() async {
        let engine = FakeDictationEngine()
        let voice = VoiceInputModel(engine: engine)
        voice.transcript = "我编辑过的第一段。"
        await voice.start()
        engine.update?("第二段")
        engine.update?("第二段说完了。")
        XCTAssertEqual(voice.transcript, "我编辑过的第一段。\n第二段说完了。")
        voice.cancel()
    }
    func testPermissionDenialHasSettingsRecovery() async {
        let engine = FakeDictationEngine()
        engine.startFailure = DictationError.microphoneDenied
        let voice = VoiceInputModel(engine: engine)
        await voice.start()
        XCTAssertEqual(voice.phase, .failed)
        XCTAssertTrue(voice.needsSettings)
        XCTAssertNotNil(voice.error)
        XCTAssertTrue(engine.cancelled)
    }
    func testBackgroundPreservesTranscriptAndStopsEngine() async {
        let engine = FakeDictationEngine()
        let voice = VoiceInputModel(engine: engine)
        await voice.start()
        engine.update?("暂时说到这里")
        voice.pauseForBackground()
        XCTAssertEqual(voice.transcript, "暂时说到这里")
        XCTAssertEqual(voice.phase, .review)
        XCTAssertTrue(engine.cancelled)
        XCTAssertTrue(voice.canUseText)
    }
    func testCancellationWhileAwaitingPermissionCannotRestartRecording() async {
        let engine = FakeDictationEngine()
        engine.delayStart = true
        let voice = VoiceInputModel(engine: engine)
        let operation = Task { await voice.start() }
        while engine.delayedStart == nil { await Task.yield() }
        voice.cancel()
        engine.delayedStart?.resume(returning: true)
        await operation.value
        XCTAssertEqual(voice.phase, .idle)
        XCTAssertFalse(voice.busy)
    }
    func testImmediateFinalResultWhileStoppingStaysInReview() async {
        let engine = FakeDictationEngine()
        engine.completeImmediatelyOnFinish = true
        let voice = VoiceInputModel(engine: engine)
        await voice.start()
        engine.update?("完成")
        voice.stop()
        XCTAssertEqual(voice.phase, .review)
        XCTAssertNil(voice.error)
    }
    func testAcceptingDictationPreservesExistingDraft() {
        XCTAssertEqual(VoiceDraft.append("  新的话  ", to: "原有文字"), "原有文字\n新的话")
        XCTAssertEqual(VoiceDraft.append("新话", to: "原有文字\n"), "原有文字\n新话")
        XCTAssertEqual(VoiceDraft.append("  ", to: "原有文字"), "原有文字")
        XCTAssertEqual(VoiceDraft.append("你好", to: ""), "你好")
    }
}
