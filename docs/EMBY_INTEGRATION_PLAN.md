# Emby 接入计划

调研日期：2026-11-18。范围：iOS 26+、SwiftUI、现有 PlaybackCore + AetherEngine / SwiftVLC 双引擎。
本文件为实施计划；不代表已完成服务端或真机验证，不修改现有播放器控制层布局及播放设置语义。

## 1. 目标和接入边界

- 使用 Emby Server REST API；第一版直接填写服务器地址并使用用户名、密码登录。
- 支持多个服务器、同一服务器的多个用户。一个“服务器 + 用户”对应一个来源；媒体库是来源内分类。
- 首个可交付版本完成登录、电影/电视剧浏览、详情、原文件在线播放、音轨/字幕选择、续播与会话上报。
- 第二个里程碑补齐有界双引擎回退、服务器协商重封装/转码、转码全时间轴 seek、后台/PiP/AirPlay 验证。
- Emby Connect、自动发现、Live TV、离线下载、远程控制接收放在后续阶段，不混入首次接入。

## 2. 已核对的项目现状

- MediaSource.Kind 仅有 demo / photos / local；SourceLibrary 的适配器一次返回扁平数组，尚无分页和远程目录模型。
- PlaybackResourceResolver 仅解析本地文件与相册资源，ResolvedPlaybackResource 只携带 URL 和文件访问生命周期。
- PlaybackContracts / PlaybackDriver 接受 URL，未传递 RequiredHttpHeaders 或服务端媒体会话。
- PlaybackCore 已有 PlaybackTranscodingProvider，但没有 Emby 实现；provider 为 weak，需要在播放会话中明确强持有。
- 转码时间轴已有 timelineOffset / originalDuration，但 seek 到裁剪流起点之前直接失败，没有重新打开流的实现。
- 当前进度、历史、缩略图和本地文件菜单需按来源能力区分；不能把 Emby 项目误当本地文件操作。

## 3. 模块职责

| 模块 | 职责 |
| --- | --- |
| EmbyAPIClient（actor） | URLSession、URL/基础路径处理、请求认证、取消、超时、错误分类；不直接驱动 UI |
| EmbyAccountStore | Keychain token、稳定安装 DeviceId、服务器和用户关联；普通来源配置不保存密码/token |
| EmbyRepository | 用户媒体库、目录、电视剧层级、分页、详情、图片与服务端 UserData |
| EmbyPlaybackCoordinator | PlaybackInfo、媒体版本、DeviceProfile、播放路线与轨道映射 |
| EmbyPlaybackSession | PlaySessionId、开始/进度/停止上报、转码/直播资源生命周期和清理 |
| EmbyTranscodingProvider | 仅对 Emby 项目提供服务器回退，返回播放资源和原片时间轴映射 |
| PlaybackCore / 引擎桥接 | 串行切换引擎、播放状态和恢复位置；引擎不认识账户管理和媒体库 |

Emby 层使用 Swift + Foundation，不引入新的 FFmpeg/VLC 链接。Aether/VLC 仍各自在独立动态 Framework 内。

## 4. 连接与认证

1. 输入完整 URL、用户名、密码；兼容域名/IP、自定义端口、反向代理子路径，避免重复拼接 /emby。
2. 请求 System/Info/Public 获取服务器身份和版本；用服务端实际 API 校准能力，不依赖单一版本号猜测。
3. POST Users/AuthenticateByName，保留官方要求的客户端身份头，随后使用 X-Emby-Token。
4. token 按 ServerId + UserId 存入 Keychain；不持久化密码，日志脱敏。
5. 401 提示重新登录，403 显示权限问题，网络失败保留来源与已有缓存。
6. 主动退出调用 Sessions/Logout；关闭 App 不自动注销。地址改变可重新关联同一 ServerId，避免历史丢失。
7. 同步处理 iOS 本地网络说明和 HTTP/ATS 策略；不绕过证书校验。不把 HTTP 明文连接失败当密码错误。

## 5. 浏览与图片

- 用户顶层媒体库：GET Users/{UserId}/Views。
- 通用列表：GET Users/{UserId}/Items，使用 ParentId、StartIndex、Limit、SortBy、SortOrder、Fields。
- 单项详情：GET Users/{UserId}/Items/{Id}。
- 第一版支持 Movie / Series / Season / Episode / Video；未知类型保留通用文件夹浏览，不当可播放视频。
- 剧集路径为媒体库 → 剧集 → 季 → 单集；海报网格沿用现有三列、2:3 视觉方案。
- 加载电影海报、名称、时长、年份、简介、评分和播放进度；按当前页面请求数据，不一次拉取整个服务器。
- 图片走 Items/{Id}/Images/{Type}，带尺寸限制与 ImageTag；缓存键包含服务器、用户和项目，避免串源。
- 多媒体版本用 MediaSourceId 区分，播放时保留选中版本。
- 来源切换取消旧请求；分页去重，图片请求合并和缓存，错误后可重试。
- 本地重命名/移动/删除不适用于 Emby；首版不提供服务端文件删除。

## 6. 播放协商与引擎调度

播放前 POST Items/{Id}/PlaybackInfo，提交用户、媒体版本、起播位置、轨道和实际 DeviceProfile。
保存 MediaSources、PlaySessionId、RequiredHttpHeaders、DirectStreamUrl、TranscodingUrl 及字幕 DeliveryUrl。

路线：

1. 优先从 Emby 获取原文件 HTTP 流，使用用户选择的默认引擎播放。
2. 第一引擎确有媒体兼容失败时，串行退役后用另一引擎尝试原流。
3. 原流仍不兼容时，重新协商服务器输出；若视频可复制，优先重封装/仅转音频，最后才转视频。
4. 认证失败、服务端权限拒绝等问题先处理对应错误，不反复更换引擎或启用转码。
5. 每个资源/引擎/服务器输出组合有界尝试；取消、切换媒体、超时后不遗留旧任务。

扩展播放资源为“URL + 请求头 + 服务端上下文 + 原片时间轴”，请求头通过值类型跨桥接传递。
Aether LoadOptions.httpHeaders 已有公开 API；SwiftVLC 任意请求头、HLS 子请求和 PiP/AirPlay 的鉴权传递需先做技术验证。
允许按服务器实际返回使用带 token 的播放 URL，但只短期使用、脱敏日志、不长期存储，不向其他来源泄漏 token。
不能把服务器磁盘 Path 视为 iPhone 上可访问的文件；不能仅根据扩展名或引擎名声称全格式直放。

DeviceProfile 按实际引擎、轨道、输出路线制定，先采用已验证的保守能力；不能照搬其他 Emby 客户端配置。
服务器转码不保证保留 Dolby Vision FEL、TrueHD Atmos、DTS:X；可能改变 HDR/音频输出，需显示实际播放方式。

## 7. Seek、音轨和字幕

- 原文件静态流：让播放器 seek，通过 Range 读取；不能仅给 static=true 流附加 StartTimeTicks。
- 转码流：先区分播放列表是否支持目标 seek；不支持时按目标 StartTimeTicks 重新协商和打开。
- 全片时间与流内时间分别维护；重开后恢复播放/暂停、音轨、字幕、倍速和原片时长。
- 同一媒体有多个版本时，使用选定 MediaSource 的时长，不无条件使用外层 Item 时长。
- 保留 Emby 轨道索引与引擎本地 ID 的映射，不把两者直接等同。
- 内封字幕优先由引擎处理；外部文本字幕依据 DeliveryUrl 或字幕 API 获取。
- 首先验证 SRT / WebVTT；ASS、PGS 等按引擎实际能力处理，不支持时再由服务器转换或烧录。
- 选音轨/烧录字幕可能改变服务器输出，需要重新协商和恢复位置。

## 8. 会话、续播和清理

- 真正开始播放后上报 Sessions/Playing。
- 按官方建议每 10 秒上报 Sessions/Playing/Progress；暂停、继续、seek 完成、轨道、速度等关键变化及时上报并合并高频事件。
- Ticks 使用 Int64，1 秒 = 10,000,000 ticks；所有上报使用原片时间轴。
- 结束时发送 Sessions/Playing/Stopped，并按 DeviceId + PlaySessionId 清理 Videos/ActiveEncodings。
- 所有清理绑定具体旧会话；不能让旧引擎的 shutdown 清理新播放任务。
- 如媒体源声明 RequiresOpening / RequiresClosing，再配套打开和关闭资源。
- Emby 续播优先读取服务端 UserData；本地为弱网缓存，同步不能把较旧进度覆盖较新进度。
- 现有“保留播放进度”开关对 Emby 的语义需一致：关闭时仍上报会话以便资源清理，但服务端是否仍记录进度不能假定可独立禁用，实施前用目标服务端验证。
- 清除本地历史、清除服务端续播、标记未看是不同操作。仅在用户明确选择对应远程操作后修改服务端 UserData。
- PiP、锁屏、迷你播放器共享同一会话；切换 UI 不重复创建服务端播放会话。

## 9. 分阶段交付和验收

| 阶段 | 交付 | 验收条件 |
| --- | --- | --- |
| A：连接基础 | Emby 来源、登录、Keychain、多账户、错误提示、旧来源迁移 | 重启仍登录；401 可重新认证；子路径、局域网 HTTP 和 HTTPS 行为正确 |
| B：媒体浏览 | 库/目录/剧集、分页、图片、详情、服务器进度 | 大库不全量下载；切源不串数据；无图/空库/权限正常 |
| C：原流播放闭环 | PlaybackInfo、原流、现有控制层、轨道、续播、报告、原流引擎回退 | 双引擎可播样本；Range seek；Emby 面板位置/暂停/停止正确 |
| D：服务器兜底 | Profile、重封装/转码、转码 seek/轨道切换、精确清理 | 不兼容样本可回退；跨起点 seek 正常；退出后无遗留编码任务 |
| E：稳定性和原生能力 | PiP、后台音频、AirPlay、断网、会话恢复 | 两引擎 × 多后台策略；HLS 子请求鉴权；切片/轨道/媒体切换不串会话 |

每阶段独立提交并执行 CI；继续保留 Mach-O 双引擎隔离审计。首轮不需要更改 workflow 触发规则或增加编解码依赖。

测试需要一台有权限的真实 Emby Server；只读账号可验证浏览，播放/转码需对应权限。
测试集至少包含 MP4 H.264/AAC、MKV HEVC、多个音轨、SRT/ASS/PGS、HDR、需要转码样本、多版本影片。
验收覆盖 401/403、断网、慢速网络、源切换、快速切片、背景/PiP，以及进度接近片尾。

## 10. 资料与结论来源

官方文档为 API 依据；论坛为踩坑说明。部分教程较旧，实施时以目标服务器 API Browser 和实际 JSON 为准。

- REST API：https://dev.emby.media/doc/restapi/index.html
- 用户认证：https://dev.emby.media/doc/restapi/User-Authentication.html
- 浏览媒体库：https://dev.emby.media/doc/restapi/Browsing-the-Library.html
- PlaybackInfo：https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html
- 图片缓存：https://dev.emby.media/doc/restapi/Images.html
- 视频流与 seek：https://dev.emby.media/doc/restapi/Video-Streaming.html
- HLS：https://dev.emby.media/doc/restapi/Http-Live-Streaming.html
- 停止转码当前参数：https://dev.emby.media/reference/RestAPI/HlsSegmentService/deleteVideosActiveencodings.html
- 会话上报：https://dev.emby.media/doc/restapi/Playback-Check-ins.html
- 字幕：https://dev.emby.media/doc/restapi/Subtitles.html
- 论坛（2019）：static=true 不处理 StartTimeTicks，Luke 明确应由播放器进行 seek/Range：https://emby.media/community/topic/80072-stream-api-starttimeticks-does-not-work-with-statictrue/
- 论坛（2019）：VLC 原始流缺少报告导致转码文件清理问题，Luke 指向 playback reports：https://emby.media/community/topic/79593-orphaned-transcoding-files-when-using-stream-api-in-vlc/
- 论坛（2021）：HLS 停止/切换与播放会话上报：https://emby.media/community/topic/95923-how-to-stop-a-http-live-streaming-movie/
- 论坛（2025）：通过 UserData 更新 PlaybackPositionTicks 的讨论：https://emby.media/community/topic/140309-setting-playbackpositionticks-via-api/

## 11. 本次实施状态

已接入来源新增/编辑（标题、备注、UA、额外请求头）、Keychain 账户、目录/分页、海报、详情、多版本、PlaybackInfo、原流双引擎、服务器重封装/转码回退、裁剪时间轴前缀重开、外置字幕、服务端续播、开始/进度/停止报告和会话级清理。现有控制层不变，使用既有后台/PiP/AirPlay 路线。

验证：`SWIFTC=/path/to/swiftc python3 BuildSupport/tests/run_emby_checks.py` 使用真实 Swift 客户端/仓库/会话代码与模拟 HTTP 服务测试；覆盖路径、UA、认证、HTTP 错误、媒体版本、字幕、转码返回值、上报节流、关闭进度保存及精确清理。Linux Swift 6 严格并发类型检查、手势回归、10 项隔离脚本测试及资源校验通过。

尚需真实服务器和 iOS/Xcode 验证：两引擎网络播放、HLS 的实际时间轴与跨分片 seek、服务器实际选择重封装/转码、轨道重新协商/烧录字幕、弱网恢复、PiP/AirPlay 鉴权及后台状态。模拟测试不能证明这些项目已验收。SwiftVLC 仅公开 UA/Referer/Cookie 请求选项；遇到其他必要请求头会明确失败并由 Core 尝试 Aether，不能保证 SwiftVLC 支持任意自定义请求头。RequiresOpening/Closing 的特殊动态媒体源及直播暂未实现。

HTTP 仅允许局域网地址，远程服务器要求 HTTPS；未禁用系统证书校验。关闭保留播放进度后不发送 PositionTicks，但服务器是否仍修改播放计数等 UserData 需要实际服务端确认。未修改 workflow、未推送。

### Common user actions

Movie, Series and Episode use their own `MediaItem.id.localID` (never a media-version ID).
Repository entry points in `EmbyIntegration.swift`:

- `setPlayed(_:for:source:)`: POST/DELETE `Users/{user}/PlayedItems/{item}`.
- `setFavorite(_:for:source:)`: POST/DELETE `Users/{user}/FavoriteItems/{item}`.
- `setProgress(_:for:source:)`: seconds, finite and nonnegative; read UserData,
  update only PlaybackPositionTicks, POST UserData. Preserves other fields.
- `clearProgress(for:source:)`: set progress to zero; does not explicitly change played/favorite.

UI entry points on PlaybackSession: `setPlayed`, `setFavorite`, `clearProgress`.
They share the per-item serialized write queue. `clearProgress` clears local resume
state only after the requested server operation succeeds. `setPlayed` retains its
existing optimistic UI behavior and failure callback; `setFavorite` is async/throwing.
The favorites browse scope remains `.favorites`. No favorite toggle UI is added here.

Active playback reporting remains in EmbyPlaybackSession (Sessions/Playing,
Progress, Stopped); it must not be replaced with repeated manual UserData writes.
Series progress is a server field on the series item; these helpers do not invent
an aggregate position or recursively clear child episodes. Played/favorite parent
behavior follows the server's dedicated endpoint semantics.

### Shared artwork, detail and action-failure entry points

- `EmbyRepository.artworkData(for:source:purpose:orientation:)` routes explicit
  poster/thumbnail/avatar/logo purposes. The existing MediaThumbnailLoader owns
  disk caching, request coalescing and the ignore-local-cache switch. Default
  Primary preference and the carousel's explicit RemoteImages policy are unchanged.
- `detailMetadata` and playback `details` share `detailSnapshot`: one transport,
  source validation and contextual failures, without merging their different result
  contracts. No persistent detail cache is added, to avoid stale playback metadata.
- `PlaybackSession` serializes writes and reports `EmbyOperationFailure` with
  operation, source ID and item ID; no credentials are included in this context.
  Existing UI alerts consume its localized description. Watched-state failure rolls
  back optimistic state only for the latest outstanding edit; progress/favorite
  async entry points propagate failures and do not optimistically alter local state.
