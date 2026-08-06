# Codex Traffic Light

一个只监控 Codex Desktop 的原生 macOS 状态红绿灯。它同时提供菜单栏图标和可拖动、始终置顶的悬浮交通灯。

## 状态

| Codex 状态 | 灯光表现 |
| --- | --- |
| 思考中 | 红、黄、绿依次循环，形成跑马灯 |
| 执行工具 | 黄灯闪烁 |
| 已完成 | 绿灯常亮，直到下一个任务开始 |
| 任务出错 | 红灯闪烁，直到下一个任务开始或点击红灯确认 |
| 空闲或主动取消 | 三灯熄灭 |

多个桌面任务并发时按 `出错 > 执行 > 思考 > 完成 > 空闲` 汇总。

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
- 拖动灯罩可移动悬浮窗，位置会自动保存。
- 菜单栏菜单可显示或隐藏悬浮窗，也可退出应用。
- 红灯闪烁时点击红灯可确认错误并熄灭。

## 数据与兼容性

应用以只读方式增量监听 `~/.codex/sessions`，并且只接受 `session_meta.payload.originator == "Codex Desktop"` 的会话。解析器只提取时间戳、会话/任务/调用标识和状态字段，不展示或持久化提示词、回复、推理、工具输入或工具输出。

应用不修改、不注入也不自动控制 Codex。Codex Desktop 如果在未来更改本地 JSONL 事件名称或停止写入会话文件，应用需要相应更新。

开发验收时可用进程环境变量 `CODEX_TRAFFIC_LIGHT_SESSION_ROOT` 指向匿名临时会话目录；它不是界面设置。
