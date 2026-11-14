# 开发环境与导航原型

## 构建基线

仅 iPhone，当前最低 iOS 26、Swift 6、Xcode 26。`Vesper.xcodeproj` 包含共享 Vesper scheme，无第三方依赖。Bundle Identifier 为 `com.aholic.vesper`，真机签名及分发需配置团队。

```bash
xcodebuild -project Vesper.xcodeproj -scheme Vesper \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

CI 保留现有 `.github/workflows/build-dev.yml`，dev 推送后在 macOS/Xcode 26 编译并打包无签名 IPA，不修改 workflow、不发布 Release。

## 导航及验收状态

阶段一的交互、设备适配和辅助功能验收已由用户确认完成（2026-11-14）。当前 AppNavigationView 内 SystemTabLayer 与 ContentHost 是兄弟层：系统 SwiftUI TabView/TabSection 承载标签及原生搜索；实际页面由 UIKit PageContainerController 和 SectionHosts 中四个持久 UIHostingController、独立 NavigationStack 承载。TabSection.hidden 控制标签组，不销毁实际页面。多功能按钮使用系统 Search Tab 入口与 App 手势桥接，没有独立自绘标签栏。迷你播放器实验代码已移除。

## 阶段二来源切片

SectionHosts 持有唯一 SourceLibrary，通过 environmentObject 注入四个页面 Host；不重建导航栈。来源列表和当前选择以单个 JSON 快照持久化于 UserDefaults。当前支持系统相册视频和文件导入的视频；SourceAdapter 隔离照片库与本地文件读取，Emby 入口暂未接入。

来源选择不会改变主导航标签。媒体页观察共享状态，仅显示选中的一个来源；切换、删除或重试取消旧请求，并以代次标识拒绝迟到结果。相册来源遵循系统权限，本地视频复制到 App 文档目录以保持访问。

## 日志

已有日志记录点依用户要求全部移除。保留历史日志查看、时间保留规则、分页、复制、清空及完整文件系统分享能力。日志文件位于 Application Support/Logs/Vesper.log；分享通过当前 UIKit 控制器直接 present UIActivityViewController。

## 本地化与外观

默认跟随系统，支持简体中文、繁体中文、英语、德语、日语、韩语、西班牙语及法语。语言选项固定使用各语言自称。主题支持跟随系统、深色及浅色，系统 ColorPicker 调色；重置主题色在默认状态禁用。图标来自根目录 icon.jpg，外观页四列展示，当前仅默认图标。标签可选择系统符号，原生标签样式由系统决定。
