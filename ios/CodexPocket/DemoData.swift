import Foundation

// All values below are explicitly demo data, never used as real model capabilities.
@MainActor
enum DemoData {
    static var threads: [[String: Any]] = [
        ["id": "11111111-1111-4111-8111-111111111111", "title": "完善手机聊天体验", "cwd": "/home/demo/codex-pocket"],
        ["id": "22222222-2222-4222-8222-222222222222", "title": "分析项目进度图", "cwd": "/home/demo/analytics"],
        ["id": "33333333-3333-4333-8333-333333333333", "title": "修复失败的测试", "cwd": "/home/demo/codex-pocket"]
    ]
    static var sent: [String: [[String: Any]]] = [:]
    static var uploads: [String: Data] = [:]
    static var resolved = Set<String>()
    static let firstThread = "11111111-1111-4111-8111-111111111111"
    static func item(_ id: String, kind: String = "agentMessage", role: String = "assistant", title: String = "Codex", text: String,
                     importance: String = "visible", images: [[String: Any]] = []) -> [String: Any] {
        ["id": id, "kind": kind, "turnID": "demo-turn", "role": role, "title": title, "text": text,
         "detail": "", "images": images, "importance": importance, "status": "completed"]
    }
    static func response<T: Decodable>(_ fields: [String: String], as: T.Type) throws -> T {
        let op = fields["op"] ?? ""
        let thread = fields["thread"] ?? firstThread
        let result: [String: Any]
        switch op {
        case "threads": result = ["threads": threads, "nextCursor": NSNull()]
        case "models":
            result = ["mode": "demo", "models": [[
                "id": "demo-model", "model": "demo-model", "displayName": "演示模型", "description": "仅演示选项，真实列表由服务器提供",
                "defaultReasoningEffort": "medium", "inputModalities": ["text", "image"],
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "较快的简单任务处理"],
                    ["reasoningEffort": "medium", "description": "常规任务"],
                    ["reasoningEffort": "high", "description": "复杂任务"]],
                "serviceTiers": [["id": "demo-fast", "name": "Fast", "description": "演示开关，不产生真实费用或推理请求"]]
            ]]]
        case "history_v2":
            let image = [["id": "demo-image", "source": "bundle:demo-chart", "local": false] as [String: Any]]
            var items: [[String: Any]] = []
            if fields["cursor"] != nil {
                items = [item("older-1", role: "user", title: "你", text: "先看一下已有的实现。"),
                         item("older-2", text: "我会先检查项目文件和当前测试结果。")]
            } else {
                items = [
                    item("demo-user", kind: "userMessage", role: "user", title: "你", text: "做成手机上的聊天界面，工具细节可以折叠，重要结果要保留。"),
                    item("demo-think", kind: "reasoning", role: "activity", title: "思考摘要", text: "先核对消息类型，再设计精简展示规则。", importance: "collapsed"),
                    item("demo-exec", kind: "commandExecution", role: "activity", title: "读取项目结构", text: "ios/\nserver/\ntests/", importance: "collapsed"),
                    item("demo-code", text: "已将普通活动收进可展开的记录。**失败、计划和图片**仍然直接显示。\n\n示例代码：\n```swift\nlet message = \"你好，Codex\"\nprint(message)\n```"),
                    item("demo-fail", kind: "commandExecution", role: "activity", title: "测试失败，需要检查", text: "AssertionError: expected image attachment to remain visible", importance: "attention"),
                    item("demo-chart", text: "这是项目进度图。点击图片可以全屏查看并双指缩放。", images: image)
                ]
                if ![firstThread, "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"].contains(thread) { items = [] }
                items += sent[thread] ?? []
            }
            let approvals: [[String: Any]] = thread == firstThread && !resolved.contains("demo-question") ? [[
                "id": "demo-question", "threadID": thread, "method": "item/tool/requestUserInput", "params": ["questions": [[
                    "id": "layout", "header": "显示方式", "question": "工具执行记录默认如何显示？",
                    "options": [["label": "折叠显示", "description": "保留摘要，按需展开"], ["label": "全部展开", "description": "显示完整记录"]]
                ]]]
            ]] : []
            result = ["items": items, "nextCursor": fields["cursor"] == nil ? "demo-older" as Any : NSNull(),
                      "approvals": approvals, "activeTurn": NSNull(), "mode": "demo", "controllable": true]
        case "new_thread":
            let record: [String: Any] = ["id": UUID().uuidString.lowercased(), "title": "新对话（演示）", "cwd": fields["cwd"] ?? "/home/demo"]
            threads.insert(record, at: 0)
            result = ["thread": record]
        case "turn":
            var items = sent[thread] ?? []
            let tokens = (fields["photos"].flatMap { $0.data(using: .utf8) }).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let photos: [[String: Any]] = tokens.compactMap { token in
                guard let data = uploads[token] else { return nil }
                return ["id": token, "source": "data:image/jpeg;base64," + data.base64EncodedString(), "local": false]
            }
            items.append(item(UUID().uuidString, kind: "userMessage", role: "user", title: "你", text: fields["text"] ?? "", images: photos))
            items.append(item(UUID().uuidString, text: "这是一条本地演示回复。正式连接后，这里显示服务器上 Codex 的真实回复。"))
            sent[thread] = items
            result = ["note": "演示消息已显示；没有发送到服务器"]
        case "answer": resolved.insert(fields["approval"] ?? ""); result = ["note": "演示回答已提交"]
        case "upload_prepare":
            let token = UUID().uuidString
            uploads[token] = Data()
            result = ["token": token]
        case "upload_chunk":
            guard let token = fields["token"], let data = fields["data"].flatMap({ Data(base64Encoded: $0) }),
                  let offset = fields["offset"].flatMap(Int.init), uploads[token]?.count == offset else { throw PocketError("演示图片上传失败") }
            uploads[token]?.append(data)
            result = ["note": "演示图片已添加"]
        case "interrupt": result = ["note": "演示操作完成"]
        case "panes": result = ["panes": []]
        default: throw PocketError("演示模式暂不支持此操作")
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
    }
}
