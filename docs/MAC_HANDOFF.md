# Mac 开发交接

当前代码版本为 0.3。iPhone 原生 SwiftUI 客户端通过 SSH 与 Ubuntu 上的 Codex CLI 通信，目标 Codex 版本由用户报告为 0.167.1。主界面采用聊天方式，终端只是备用入口。

## 接手后的第一步

```bash
git clone https://github.com/leisongju/codex-pocket.git
cd codex-pocket
open ios/CodexPocket.xcodeproj
```

先等待 Swift Package 依赖解析，然后选择 iPhone 模拟器运行，点击“先预览聊天界面”。当前没有提供已签名 IPA；Xcode 构建、模拟器测试和真机验证都尚未执行。

在装好 Xcode 与 iPhone 模拟器运行时的 Mac 上：

```bash
bash scripts/check-mac.sh
```

该脚本会运行 Python 测试，然后编译并执行 iOS 单元测试和 UI 测试。若失败，先修复构建或测试问题。结果包位于 `/tmp/CodexPocket-时间.xcresult`。

## 已有内容

| 目录 | 用途 |
| --- | --- |
| `ios/CodexPocket` | 客户端界面、SSH、项目和会话、记录渲染、模型设置、图片、语音输入 |
| `ios/CodexPocketTests` | 展示规则与语音状态机单元测试，尚未执行 |
| `ios/CodexPocketUITests` | 演示模式输入、旋转和图片预览测试，尚未执行 |
| `server` | Python 桥接、持续 app-server 连接、图片、审批与问答、可选 tmux 辅助 |
| `tests` | 33 项已经执行通过的服务端测试 |
| `designs` | 3 张概念设计，包含部分待开发交互 |
| `docs` | 展示规则、语音行为及验证边界 |

`ios/CodexPocket.xcodeproj` 可以直接打开。修改源文件清单后运行 `python3 scripts/generate_project.py`；另有可选的 XcodeGen 配置 `ios/project.yml`。

## 建议验收顺序

1. Xcode 依赖解析、编译及模拟器演示界面。
2. iPhone 横竖屏、键盘和安全区、旧记录滚动、图片附件及预览。
3. 麦克风授权、语音转文字、取消及中断、确认文字后追加草稿。语音依赖 iOS 真实服务，模拟器结果不能替代真机验证。
4. 配置真机签名，完成实际设备测试。“iPhone duo”的正式型号仍未核实，不能声称已完成特定机型验收。
5. 最后连接实际 Ubuntu，核对 0.167.1 的协议兼容性、模型/强度/Fast、同一运行会话、审批与问答。先新建独立测试会话，避免给日常工作会话发送测试提示。

## 关键边界

- 当前仅做了 Linux 能执行的 Python 测试、语法与项目引用检查；没有把这些当成 iOS 构建成功。
- 共享 daemon 连接优先使用 `codex app-server proxy`。如果只能建立独立 app-server，不应恢复一个由外部进程运行的会话形成第二个实例；此时既有会话的部分能力会禁用。
- Fast、模型和推理强度读取真实服务器目录，不硬编码某账号一定能使用的能力。
- 语音确认只追加输入框，用户手动发送；不保存录音文件、不向 Ubuntu 上传音频。设备端不支持时可能使用 Apple 网络语音服务。
- 设计稿中的完整草稿持久化、自动重连、文件差异面板和系统通知等仍是后续建议，不能仅凭设计图声称已实现。
- 仓库不包含服务器密码、SSH 私钥或真实服务器配置。真机账号、SSH 凭据和签名文件应留在本地或系统钥匙串。

## 后续需求

用户希望接近 Mac Codex 的主要手机交互：项目和会话选择、可展开的精简历史、重要错误保留、文字与图片、多行输入、上下滑动、语音输入、模型/强度/Fast，以及横竖屏布局。展示策略参考公开的 CLI/TUI 与协议，未声称 macOS App 整个界面开源或已经完全复刻。
