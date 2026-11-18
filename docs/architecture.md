# 技术架构约定

## 依赖边界

- `PlaybackCore` 是播放调度和播放状态的唯一所有者；UI 不直接依赖具体播放内核。
- `PlaybackContracts` 定义不包含上游类型的稳定边界。AetherEngine 和 SwiftVLC 各自封装在独立动态 Framework bridge 中。
- AetherEngine 负责主流播放，SwiftVLC/libVLC 负责备用兼容；两者不能同时持有活动播放会话。
- 旧引擎实现不得作为备用代码或直接依赖保留。播放设置和控制 UI 仍属于 Vesper。
- 本地/在线来源与播放能力分别建模。服务器转码只能由已授权的服务器来源提供，不能把本地或相册文件静默上传。
- SwiftPM 模块隔离不等于二进制符号隔离；需要审计最终 Mach-O 动态依赖、namespace 和导出符号。

## 建议职责分层

- **Presentation**：页面、视图状态、用户操作和可访问性。
- **Application**：打开媒体、恢复进度、切换引擎及偏好应用。
- **Playback**：PlaybackCore、公开契约及引擎 bridge。
- **Library / Sources**：媒体来源发现、描述和访问。
- **Persistence**：用户设置、播放历史和进度。

职责约定不要求在代码很少时创建大量空模块。target 划分应服从实际依赖边界与构建需求。

## 媒体来源与播放契约

- 媒体身份、显示元数据和播放地址/访问参数分开建模；不要把 URL 字符串当作完整媒体模型。
- 本地资源的权限句柄必须覆盖整个 native reader 生命周期，包括关闭/切换过程。
- 播放状态、进度、错误和可用轨道以当前 driver 状态为准，不从 UI 推测。
- 跨引擎恢复通过位置与轨道语义信息完成，不复用 engine-local track ID。

## 播放呈现与 PiP

- 全屏、紧凑播放器和系统 PiP 共用一个播放会话；呈现切换不得创建第二个 decoder。
- 不实现 App 内可拖动浮窗。PiP 走当前 bridge 所支持的 Apple API，并在设备上验证。
- 系统媒体控制、播放状态和 Now Playing 信息必须映射到同一 PlaybackCore 会话。
- 不同引擎的 PiP 与外接播放能力不同，未实测前不得作为通用能力承诺。

## 并发、错误与资源

- 播放会话创建、切换和销毁由单一所有者串行编排；旧任务不能覆盖新会话状态。
- 切换前等待 native decoder 与 seek 工作完成；受保护资源在 teardown barrier 结束后释放。
- 上游错误映射为稳定的应用错误，同时保留不含凭据的诊断信息。

## 依赖和许可

- AetherEngine 固定为 7.70.0；SwiftVLC 固定为 1.0.0。直接和二进制依赖版本见 `Playback/Dependencies.json`。
- VLC 静态 XCFramework 只能链接到 VLC bridge；Aether 使用独立命名的动态 FFmpeg Framework 闭包。
- 每次升级都要检查 API、平台支持、Mach-O 依赖、符号导出、许可证和真机回归。
- 各上游及二进制依赖许可证需按实际分发方式单独审核；资源目录中的 notices 不构成合规保证。
