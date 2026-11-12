# 消息展示规则

本实现参考公开的 Codex CLI/TUI 与 app-server 协议，没有把 macOS 桌面 App 的整套界面视为开源代码。本次可核实的参考为：

- [messages.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/history_cell/messages.rs)：用户、助手、图片、思考摘要；代码明确说明完成的思考摘要保留在展开记录中，不放进精简滚动记录。
- [activity_preview.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/history_cell/activity_preview.rs)：活动预览行数有界，展开时使用保留的内容。
- [service_tiers.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/service_tiers.rs)：从当前模型 service_tiers 找名称为 Fast 的档位，使用真实档位 ID；不是硬编码请求中的 ID 为 fast。
- [app-server](https://github.com/openai/codex/tree/main/codex-rs/app-server)：消息类型、分页、流式通知、模型列表、turn/start、服务端确认与问答协议。

手机端的具体展示策略在 `server/presentation.py` 与 `TimelineRow.build` 中，属于本项目实现，并不声称逐像素复刻 macOS 客户端。

| 记录 | 默认展示 |
| --- | --- |
| 用户文字、助手回复 | 直接展示，可选择复制 |
| 图片，包括纯图片消息 | 直接展示，可全屏缩放 |
| 标记为 commentary 的已完成进度说明 | 折叠；含图片、问题或代码块时保留重要内容 |
| 普通命令和工具成功输出 | 连续活动合并，可展开 |
| 已公开的思考摘要 | 折叠展示，不恢复任何隐藏推理 |
| 文件变更 | 显示变更数量，展开查看详情 |
| 计划 | 直接展示 |
| 执行失败、工具错误、警告 | 单独醒目展示，不混入成功活动组 |
| 待确认的命令、文件修改 | 独立确认卡，用户明确允许或拒绝 |
| 结构化提问 | 独立问答卡，选项或自由输入 |
| 助手附带的非阻塞问题 | 显示选项，可填入输入框后由用户发送 |
| 上下文压缩 | 折叠说明 |
| 未识别的新类型 | 保留为可展开记录，避免静默丢弃 |

“显示全部活动”可以展开精简视图的内容。所有折叠都只是 UI 状态，不删除、改写服务器历史。工具详情使用有界文本预览，并非无限输出查看器；原始记录仍由 Codex 保存。历史按页向前加载，已加载的旧页不会因最新回复刷新而被替换。

Markdown 支持段内样式、链接、可横向滚动及复制的围栏代码块。复杂 Markdown 表格、交互式网页、音视频不属于当前渲染器的完整能力。
