# Trakt 接入准备

首版建议从设置标签页现有的 Trakt 入口连接账号，授权后将 Emby 电影和单集的播放事件单向上报到 Trakt。设置页提供账号状态和断开连接。历史导入、双向同步、评分和待看清单留待后续设计。

## 应用注册与授权

- 在 Trakt 开发者后台创建 Development 应用，取得测试 Client ID，并给测试账号配置访问权限。
- iOS 使用系统网页认证会话和 OAuth Authorization Code + PKCE（S256）。验证回调的 state，用 code verifier 交换令牌。App 只配置 Client ID，访问令牌和刷新令牌存入 Keychain。
- 正式发布需申请 Trakt Production 权限，准备隐私政策、应用介绍和 Trakt 要求的署名说明，并配置自有域名的 HTTPS 回调与 iOS Universal Links。正式环境使用独立 Client ID。
- 参考 [应用注册](https://github.com/trakt/api-help/blob/HEAD/projects/developer/src/lib/guides/create-an-app.md) 和 [PKCE 指南](https://github.com/trakt/api-help/blob/HEAD/projects/developer/src/lib/guides/pkce.md)。

## Vesper 接入位置

- 在 `EmbyIntegration` 解析 Trakt 支持的媒体标识。电影使用 IMDb 或 TMDb ID，单集优先使用单集 ID，也可使用剧集 ID 加季号和集号作为查询条件。复用片头片尾查询已有的剧集标识来源，分别处理电影、剧集和单集的 ID。缺少可用标识时跳过上报。
- 在 `PlaybackSession` 按实际播放状态向 Trakt 发送开始、暂停和结束事件。进度取播放位置除以总时长，校验后转换成 0–100 的百分比。换集先结束上一集。切换引擎或软硬解码时沿用同一次播放会话，避免重复上报。
- 使用独立服务串行管理令牌刷新和状态上报。退出账号时清除本机凭据并取消待发请求。收到 HTTP 429 按 `Retry-After` 延后，无该响应头时采用有上限的退避。服务异常时继续本地播放。
- 参考 [播放上报](https://github.com/trakt/api-help/blob/HEAD/projects/developer/src/lib/guides/about-scrobble.md) 和 [限速规则](https://github.com/trakt/api-help/blob/HEAD/projects/developer/src/lib/guides/rate-limiting.md)。

## 联调验收

用 Development 应用和测试账号验证授权成功、取消授权、令牌过期与断开连接。分别验证电影、单集、缺少标识、自动换集和切换引擎，检查 Trakt 记录是否对应正确的媒体，以及限速和鉴权错误是否影响播放。

## 当前进度

已配置 Development Client ID 和测试回调 `vesper://trakt/callback`。设置页 Trakt 入口支持发起系统网页 PKCE 授权、验证回调 state、交换令牌并保存到 Keychain，以及清除本机连接凭据。开发者后台必须登记同一回调地址。

已接入令牌自动刷新和播放事件同步。访问令牌过期前会串行刷新，Trakt 的单次刷新令牌会以新令牌原子替换；401 会刷新后重试一次，429 使用 Retry-After 延迟。播放开始、暂停、结束事件通过单队列发送，内核切换不会重复开始，失败不阻塞本地播放。  
当前“已连接”表示本机保存了授权凭据；历史导入、双向历史同步、评分和待看清单仍未接入。授权和真实播放上报仍需 iOS 构建及测试账号实机联调，尚未验证该 Client ID 的后台配置。

## 续播进度优先级

Emby 设置的“播放进度优先级”使用与标签顺序一致的拖动排序 sheet，即时保存顺序。默认 Trakt、服务器、本地；Trakt 未连接时仍显示，但不执行进度请求。开始播放时按顺序采用第一份有效记录，读取失败或缺失则回退；显式指定的播放位置（例如切换内核、跳转和重播）优先于该设置。“按进度续播”关闭时从头开始。接近片尾或已完成的位置按从头播放处理。

Trakt 使用 /sync/playback/movies 或 /sync/playback/episodes 的暂停进度，而非观看完成标志。通过电影/单集 ID 匹配；只有剧集 ID 时，需同时匹配季号与集号。百分比根据本次播放版本时长换算。不带分页参数读取暂停进度集合，再匹配本次播放条目。服务器明确返回的 0 也是有效记录；没有服务器记录时才尝试本地。

共享设置简介卡片在模态呈现中隐藏，普通推入的二级设置页保留简介。
