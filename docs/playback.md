# 播放架构

## 引擎与职责

播放界面、手势、播放队列和现有播放设置由 App 保持所有权；引擎只提供媒体读取、解码、渲染和播放状态。

- **PlaybackCore** 是唯一播放调度者，负责选择、切换、错误回退、进度恢复和轨道语义匹配。任何时刻只允许一个播放 driver 持有活动媒体。
- **AetherEngine 7.70.0** 是主引擎，使用 AetherEngine 上游提供的原生播放和 FFmpeg 能力。
- **SwiftVLC 1.0.0 / libVLC 4** 是备用引擎。当前解码设置只表达硬件优先/软件优先，不代表所有 codec 都能强制使用指定解码器。
- **PlaybackContracts** 是无上游类型的值类型/协议边界。App 与两套适配器只通过该边界交换 URL、状态、轨道和播放偏好。
- **Emby 转码** 目前只有 PlaybackCore provider 接口；当前 `MediaSource` 尚无 Emby 来源、账号/凭据或转码客户端，因此不是可用的播放回退路径。

## 二进制隔离

`Playback/AetherBridge` 和 `Playback/VLCBridge` 分别构建为独立动态 Framework；每个 Framework 仅依赖自己的上游模块。VLC 的 iOS `libvlc.a` XCFramework 切片是静态 archive，必须只在 `VesperVLCBridge.framework` 内链接，绝不直接链接到 App 或 Aether bridge。

Aether 的 FFmpegBuild 依赖使用独立命名的 `AetherLibav*` 动态 Framework。三个自有 Framework 使用 `MH_DYLIB`、two-level namespace、独立 install name 和限定的导出符号表。`BuildSupport/embed_playback_dependencies.py` 将每个 bridge 的动态依赖闭包嵌入 App；`BuildSupport/audit_playback_isolation.py` 在 macOS/Xcode 构建后检查 Mach-O 架构、依赖路径、旧引擎残留和 codec 符号泄漏。SwiftPM module 名称本身不构成二进制隔离，最终归档检查是必要条件。

版本、revision、二进制 checksum 见 [`Playback/Dependencies.json`](../Playback/Dependencies.json)。升级任何引擎或底层二进制后，必须重新审查链接图、导出符号、许可和设备回归。

## 加载与回退

用户偏好的引擎先尝试打开资源；仅在打开失败或播放中报告 engine error 时切换到另一引擎。切换前等待旧 driver 完整关闭，再创建新 driver，并恢复时间、播放/暂停状态和可按语言/编码/名称匹配的音轨及字幕。引擎内部轨道 ID 不跨引擎复用。

资源访问句柄一直保留到 native decoder teardown 完成。预览/元数据探测不是播放会话，不得接管活动播放 driver。Emby 转码接入时必须由已授权的 Emby source 提供 transcode URL、原片时间偏移和时长；不可将本地/相册资源静默上传。

## 能力边界

AetherEngine 上游的 TrueHD object audio、DTS:X object audio 和双层 Dolby Vision traits 默认未启用。不能据此承诺蓝光 Profile 7 FEL、Atmos、DTS:X、AirPlay、PiP 或每种视频的硬解表现。最终行为取决于上游版本、编译配置、设备和 iOS 版本，应以设备实测和媒体样本验证为准。应用不得把“硬件优先”显示成当前实际 decoder，除非所选引擎提供可靠的活动 decoder 信息。

SwiftVLC wrapper 使用 MIT；其静态 libVLC 二进制及 contrib libraries 有各自的 LGPL/第三方许可和再链接义务。AetherEngine 与其 FFmpeg 依赖的许可文本和例外条件需按实际分发方式核查。App 中的 notices 不是法律合规结论。

## 工作流

工作流需使用支持 Swift 6.3 的 Xcode；当前 Xcode 27 runner 满足工具链要求。首次依赖解析后，应提交新的 `Package.resolved` 并以锁定解析构建。Debug 与 Release 都要构建 arm64 iOS 产物，运行 Mach-O 隔离审计并保存报告。设备回归还应覆盖：两引擎播放/seek/轨道切换、播放中 engine failover、PiP、后台音频、快速切换资源、受保护 URL 生命周期及暂停后前后台恢复。
