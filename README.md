# Codex Traffic Light

一个监控 Codex Desktop、Claude Code 和 Cursor Agent 运行状态的原生 macOS 桌面应用。它提供菜单栏图标，以及可拖动、始终置顶的三组交通灯悬浮窗。

项目使用 Swift、Swift Package Manager 和 AppKit 实现，不包含第三方依赖、网络请求、遥测或自动更新服务。

## 功能

- 分别显示 Codex Desktop、Claude Code 和 Cursor Agent 的状态。
- 菜单栏显示三者的汇总状态。
- 悬浮窗可移动、隐藏，并自动记住位置。
- 支持思考、工具执行、命令审批、完成、错误和空闲状态。
- 只读监控本机已有会话文件，不修改或控制 Codex、Claude Code。

## 状态

| AI 状态 | 灯光表现 |
| --- | --- |
| 思考中 | 红、黄、绿依次循环，形成跑马灯 |
| 执行工具或等待命令审批 | 黄灯闪烁 |
| 已完成 | 绿灯常亮，直到下一个任务开始 |
| 任务出错 | 红灯闪烁，直到下一个任务开始或点击红灯确认 |
| 空闲或主动取消 | 三灯熄灭 |

多个来源或任务并发时，菜单栏按 `出错 > 执行 > 思考 > 完成 > 空闲` 汇总。

Claude Code 处于思考状态且连续 10 分钟没有新的状态日志时，会自动回到空闲；正在执行的工具调用不受此超时影响。

## 系统要求

- macOS 13 或更高版本。
- 从源码构建需要 Apple Command Line Tools。
- 生成的 App 架构与构建机器一致。在 Apple Silicon Mac 上构建的当前产物仅支持 `arm64`。

## 从源码安装

```bash
git clone https://github.com/northya/agent_traffic_light.git
cd codex-traffic-light
swift run CodexTrafficLightCoreTests
./scripts/package_app.sh
open "build/Codex Traffic Light.app"
```

生成的应用位于 `build/Codex Traffic Light.app`。可以把整个 `.app` 移动到 `/Applications`，不能只复制 `Contents/MacOS` 中的可执行文件。

当前打包脚本生成的是未使用 Developer ID 签名、未经 Apple 公证的本地构建。其他 Mac 首次启动时可能需要在 Finder 中右键应用并选择“打开”。面向公开下载发布时，维护者应另外完成签名、公证，并分别提供 Apple Silicon、Intel 或 Universal 构建。

## 使用

- 应用启动后默认显示悬浮交通灯，并在菜单栏常驻。
- 悬浮窗从左到右显示 Codex、Claude 和 Cursor。
- 拖动灯罩可移动悬浮窗，位置会自动保存。
- 菜单栏菜单可显示或隐藏悬浮窗，也可退出应用。
- 红灯闪烁时点击对应灯组的红灯，可单独确认该来源的错误并熄灭。

## 隐私与安全

应用在本机处理状态，不会把会话数据发送到任何网络服务。

### 读取的数据

应用以只读方式访问以下本地目录：

| 来源 | 默认目录 | 用途 |
| --- | --- | --- |
| Codex Desktop | `~/.codex/sessions` | 读取最近有更新的 Codex Desktop 会话状态事件 |
| Claude Code | `~/.claude/projects` | 读取最近有更新的主会话状态，排除 `subagents` |
| Claude Code runtime | `~/.claude/sessions` | 判断进程是否忙碌或正在等待命令审批 |
| Cursor Agent | `~/Library/Application Support/Cursor/logs` | 读取 Cursor Agent 的结构化生命周期和命令执行事件 |
| Cursor state | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | 判断 Cursor Agent 是否正在等待问题回答 |

Codex 只接受 `session_meta.payload.originator == "Codex Desktop"` 的会话。Codex、Claude 和 Cursor 日志都只处理从昨天零点以来有修改的文件，避免扫描无关的历史会话。

会话日志记录可能包含提示词、回复、推理、工具输入或工具输出。Foundation 会在进程内短暂反序列化当前记录，但这些内容字段不会进入状态模型，也不会被应用显示、打印、写入磁盘或发送到网络。状态模型只保留时间戳、会话/任务/调用标识和状态字段。

### 本地持久化

应用只通过 `UserDefaults` 保存悬浮窗位置。它不会持久化会话内容、会话标识、任务标识、工具调用或错误文本。

### 权限边界

当前构建未启用 App Sandbox，因此进程继承启动用户的文件访问权限。源码实现只访问上述会话目录，并以只读方式打开会话文件；不申请辅助功能、录屏、麦克风、摄像头、通讯录或剪贴板权限。

应用不注入 Codex 或 Claude Code，不安装或修改 hooks，也不执行会话中的工具命令。Claude runtime 文件中的 PID 仅用于本机进程存活检查。

## 兼容性与限制

- 状态来源是 Codex Desktop 和 Claude Code 的本地、非公开日志格式，不是稳定 API。客户端升级后如果字段或目录结构变化，监控逻辑可能需要同步更新。
- 状态是依据日志事件推导的近似结果。如果客户端异常退出且没有写入终止事件，灯光可能暂时保留在活动状态。
- App 只监控与它运行在同一 macOS 用户下的本机会话。
- 当前版本没有自动更新、崩溃上报或网络诊断功能。

## 开发与验证

```bash
swift run CodexTrafficLightCoreTests
swift build --product CodexTrafficLightApp
./scripts/package_app.sh
plutil -lint "build/Codex Traffic Light.app/Contents/Info.plist"
```

自动化测试使用零依赖的 Swift 可执行测试程序，任一断言失败都会以非零状态退出。

开发验收时可用以下进程环境变量指向匿名临时会话目录：

- `CODEX_TRAFFIC_LIGHT_SESSION_ROOT`
- `CLAUDE_CODE_SESSION_ROOT`
- `CLAUDE_CODE_RUNTIME_SESSION_ROOT`
- `CURSOR_TRAFFIC_LIGHT_LOG_ROOT`
- `CURSOR_TRAFFIC_LIGHT_STATE_DATABASE`

这些变量不是界面设置。公开问题或日志时，请勿上传真实会话文件；测试用例应使用匿名、合成数据。

## 开源发布检查

公开仓库或 GitHub Release 前，维护者应检查：

- Git 历史中没有密钥、真实会话内容、本机路径或不希望公开的作者邮箱。
- 仓库根目录包含明确的开源许可证文件。
- Release App 已按目标架构构建，并完成适当的签名和公证。
- 发布包中只包含 `.app` 和必要文档，不包含 `.build`、本机会话日志或测试临时文件。
