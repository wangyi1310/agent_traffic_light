# Codex Traffic Light

一个监控 Codex Desktop 和 Claude Code 的原生 macOS 状态红绿灯。它同时提供菜单栏图标和可拖动、始终置顶的悬浮交通灯。

## 状态

| AI 状态 | 灯光表现 |
| --- | --- |
| 思考中 | 红、黄、绿依次循环，形成跑马灯 |
| 执行工具 | 黄灯闪烁 |
| 已完成 | 绿灯常亮，直到下一个任务开始 |
| 任务出错 | 红灯闪烁，直到下一个任务开始或点击红灯确认 |
| 空闲或主动取消 | 三灯熄灭 |

Codex Desktop 和 Claude Code 的多个任务并发时，统一按 `出错 > 执行 > 思考 > 完成 > 空闲` 汇总。

Claude Code 处于思考状态且连续 10 分钟没有新的状态日志时，会自动回到空闲；正在执行的工具调用不受此超时影响。

## 构建与运行

要求 macOS 13 或更高版本，并安装 Apple Command Line Tools。

```bash
swift run CodexTrafficLightCoreTests
./scripts/package_app.sh
open "build/Codex Traffic Light.app"
```

本机 Command Line Tools 不包含 `XCTest` 或 Swift `Testing` 模块，因此自动化测试使用零依赖的 Swift 可执行测试程序；任一断言失败都会以非零状态退出。

生成的应用位于 `build/Codex Traffic Light.app`。它是本地未签名构建，不包含签名、公证或 Mac App Store 分发配置。

## 使用

- 应用启动后默认显示悬浮交通灯，并在菜单栏常驻。
- 悬浮窗左侧显示 Codex 状态，右侧显示 Claude 状态；菜单栏显示两者汇总状态。
- 拖动灯罩可移动悬浮窗，位置会自动保存。
- 菜单栏菜单可显示或隐藏悬浮窗，也可退出应用。
- 红灯闪烁时点击对应灯组的红灯，可单独确认该来源的错误并熄灭。

## 数据与兼容性

应用以只读方式增量监听 `~/.codex/sessions` 和 `~/.claude/projects`。Codex 只接受 `session_meta.payload.originator == "Codex Desktop"` 的会话；Claude 只读取昨天零点以来有更新的主会话 JSONL，并排除 `subagents` 子代理记录。解析器只提取时间戳、会话/任务/调用标识和状态字段，不展示或持久化提示词、回复、推理、工具输入或工具输出。

应用不修改、不注入也不自动控制 Codex 或 Claude Code，也不会修改 Claude Code hooks。任一客户端如果在未来更改本地 JSONL 结构或停止写入会话文件，应用需要相应更新。

开发验收时可用进程环境变量 `CODEX_TRAFFIC_LIGHT_SESSION_ROOT` 和 `CLAUDE_CODE_SESSION_ROOT` 分别指向匿名临时会话目录；它们不是界面设置。
