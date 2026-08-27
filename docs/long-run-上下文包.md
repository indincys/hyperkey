# Hyper 30 项产品级优化：执行上下文包

## 项目基线

- 仓库：`/Users/indincys/hyper`，Swift Package，macOS 13+ 菜单栏应用，无第三方运行时依赖。
- 当前版本：`1.2.0`，`main` 与 `origin/main` 一致，开始分诊时工作区干净。
- 核心规模：约 15,048 行 Swift；剪贴板及关联代码约 8,000 行。
- 基线验证：`swift test` 为 142 tests / 0 failures；`swift build -c release --arch arm64` 通过。
- 基线缺口：总行覆盖约 13.38%；ClipboardManager、Monitor、Paster、Panel、HID/HyperTap 等关键链路缺少端到端覆盖。
- 发布现状：本机有 `Hyper Self-Signed` 身份且 `gh` 已登录；现有产物仅 arm64、自签名，Gatekeeper `spctl` 不接受；仓库中错误跟踪了 `hyper-signing-backup.p12`。

## 目录地图

- `Sources/Hyper/Clipboard/`：采集、存储、搜索、粘贴、队列、面板、HUD、拖放和编辑。
- `Sources/Hyper/SettingsView.swift` / `SettingsModel.swift` / `Config.swift`：设置 UI、状态和持久化配置。
- `Sources/Hyper/AppDelegate.swift` / `HyperTap.swift` / `HIDRemapper.swift`：生命周期、热键与 HID。
- `Sources/Hyper/Updater.swift`：GitHub Release 更新检查、校验与替换。
- `Tests/HyperTests/`：当前纯逻辑单测。
- `build.sh` / `release.sh` / `doctor.sh`：构建、发布、诊断。

## 基础命令与证据规则

- 受影响范围测试：`swift test --filter <SuiteOrTest>`。
- 全量闸：`swift test`，再运行 `./build.sh`；发布候选还需签名、更新、secret scan 与 UI smoke 验证。
- UI 改动必须提供真实应用截图；散文描述不能替代视觉证据。
- 通过日志只保留最新版本到 `docs/long-run-evidence/`；失败日志按工作单保留。
- 同一文件范围同一时刻只能有一个写入者。执行者只跑受影响测试；批次全量闸由主代理运行。
- 执行者不能验收自己的高风险改动；高风险单由新上下文审查代理对照清单验收。

## 已确认的关键事实

- 索引损坏后以空 records 启动，随后真实启动路径会执行孤儿清理，存在删除可恢复 payload 的风险。
- 捕获在主线程完整读取所有类型后才判断超限；超限数据仍可能被哈希、解码和缩略。
- 队列粘贴在发送事件前出队；粘贴 API 没有成功结果；固定 0.5 秒还原会覆盖用户的新复制。
- 暂停 Hyper 不会暂停剪贴板记录；忽略应用依据延迟检测时的前台 app，存在来源误判。
- payload 异步新增与同步编辑可覆盖；正常退出没有等待 pending writes。
- 历史数据、搜索 sidecar 和缩略图明文落盘，目录/文件权限实测为 0755/0644。
- 当前预览是第二个等高独立 Panel；窄屏会直接取消预览，超宽图片空间利用率很低。
- 当前已有编辑、撤销删除、固定、队列排序、批量选择、格式转换、拖放和较完整的键盘/VoiceOver 基础，不得把已有能力重新列为“新优化”。

## 产品口径与默认假设

- 默认本地优先，不在本战役加入云同步或 AI 语义搜索；在本地可靠性、加密和隐私未稳前扩大数据边界不合格。
- “粘贴成功”定义为：payload 准备成功、目标激活成功、事件成功构造并投递；macOS 没有目标应用消费回执，UI 必须对这一边界诚实。
- 批量操作默认全有或全无；只有用户显式确认才允许跳过不可用项继续。
- 收藏不因普通保留策略静默删除，但必须受磁盘安全硬上限保护并提前告警。
- Developer ID/公证需要外部 Apple 凭据；代码与流水线应准备到可验状态，凭据缺失不得伪称公证通过。

## 明确淘汰的低价值项

- 单纯调整圆角、阴影、颜色或动画时长。
- 把 1.5 秒轮询简单改快。
- 再增加少量大小写、去空格转换。
- 单纯提高历史条数或单条 MB 上限。
- 只加图标、HUD 文案或零散快捷键。
- 在存储、加密与隐私基础未达标前加入云同步或 AI。
