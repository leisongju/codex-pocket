import XCTest
@testable import CodexPocket

final class TranscriptTests: XCTestCase {
    func item(_ id: String, importance: String, image: Bool = false) -> TranscriptItem {
        TranscriptItem(id: id, kind: "commandExecution", turnID: "t", role: "activity", title: id,
                       text: "", detail: "", images: image ? [ImageReference(id: "i", source: "image", local: true)] : [],
                       importance: importance, status: "completed")
    }
    func testCompactionNeverHidesFailureOrImage() {
        let input = [item("normal1", importance: "collapsed"), item("normal2", importance: "collapsed"),
                     item("failure", importance: "attention"), item("image", importance: "collapsed", image: true)]
        let rows = TimelineRow.build(input, showAll: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].items.map(\.id), ["normal1", "normal2"])
        XCTAssertEqual(rows[1].items.first?.id, "failure")
        XCTAssertEqual(rows[2].items.first?.id, "image")
        XCTAssertFalse(rows[2].isGroup)
    }
    func testExpandedHistoryRetainsEveryItem() {
        let input = [item("one", importance: "collapsed"), item("two", importance: "visible")]
        XCTAssertEqual(TimelineRow.build(input, showAll: true).flatMap(\.items).map(\.id), ["one", "two"])
    }
    func testSelectingFastUsesCatalogID() throws {
        let data = Data("""
        {"id":"m","model":"model-id","displayName":"Name","description":"test","defaultReasoningEffort":"high", "supportedReasoningEfforts":[],"serviceTiers":[{"id":"priority","name":"Fast","description":"faster"}]}
        """.utf8)
        let model = try JSONDecoder().decode(ModelOption.self, from: data)
        XCTAssertEqual(model.fastTier?.id, "priority")
        XCTAssertEqual(ComposerSettings(model: model.model, effort: "high", tier: model.fastTier!.id).requestFields["tier"], "priority")
    }
}
