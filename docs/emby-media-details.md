# Emby 媒体详情

电影与单集统一使用 `EmbyMediaDetailView`。沿用剧集详情的介绍、类似作品、演职人员和链接区域；只有 Series 展示分集列表。单集使用视频缩略图，并显示所属剧集、季和集数。

## 官方 API 字段

依据 [Emby 用户条目详情 API](https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsById.html) 的 `BaseItemDto`、`MediaSourceInfo` 和 `MediaStream` 定义：

- `MediaSources` 是媒体版本列表，每个版本有独立的 `Id` 和 `MediaStreams`。播放请求使用所选版本的 `MediaSourceId`。
- 文件信息显示文件名、容器、大小、总码率、时长、协议、MIME 类型、远程属性和直接播放／串流／转码能力；服务器未返回的字段不显示。
- 视频流显示编码、Profile、分辨率、宽高比、帧率、位深、动态范围及色彩信息。
- 音轨显示标题、语言、编码、声道布局、采样率、位深、码率和默认标记。
- 字幕显示标题、语言、编码、默认／强制／外置标记、传送方式及外置文件名。`IsHearingImpaired` 只表明听障辅助，显示 `SDH/CC`，不推断具体类型。
- `DefaultAudioStreamIndex`、`DefaultSubtitleStreamIndex` 用于初始化选择，字幕索引 `-1` 表示关闭。切换版本后重置为该版本的默认轨道。

详情页可在播放前选择音轨、字幕或关闭字幕，播放中仍可从播放器菜单切换。Emby 流索引不是引擎轨道 ID：传递轨道类型内顺序与名称、语言、编码偏好，由播放核心匹配实际引擎轨道；引擎切换继续沿用原有语义匹配。

## 真机验证

需要在 Apple 工具链及可用 Emby 服务器上验证：电影和单集布局、多版本播放资源、同语言多音轨、内嵌／外置字幕、关闭字幕、默认索引为 -1，以及切换引擎后的轨道保留。服务器转码或引擎未暴露所选轨道时，无法保证该轨道可选。
