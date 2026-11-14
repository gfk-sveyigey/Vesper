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

当前顶部与底部采用 iOS 26 原生导航。SwiftUI TabView 直接承载媒体、来源、记录、设置四个 NavigationStack 和独立 Search Tab，各标签的 NavigationPath 独立保存在根视图。移除 SystemTabLayer、ContentHost、PageContainerController、UIKit 手势桥接和手工安全区计算，不再通过隐藏标签组切换布局。

一级页面使用 `.toolbarTitleDisplayMode(.inlineLarge)`，二级页面使用系统 inline 标题和返回按钮。底部启用 `.tabBarMinimizeBehavior(.onScrollDown)`；MiniPlayer 放在 `.tabViewBottomAccessory`，系统负责玻璃背景及收缩位置，使用 matchedTransitionSource 和 zoom 转场展开。当前没有播放引擎，播放器显示“未在播放”，播放和下一项禁用。标签顺序与图标设置保留，多功能按钮、手势映射与标签显隐入口移除。

## 阶段二来源切片

AppNavigationView 持有唯一 SourceLibrary，通过 environmentObject 注入原生 TabView 的页面。来源列表和当前选择以单个 JSON 快照持久化于 UserDefaults，仅包含演示配置。SourceAdapter 隔离数据读取；当前 DemoSourceAdapter 提供内容、空、失败和离线状态，演示媒体没有真实资源和播放能力。

来源选择不会改变主导航标签。媒体页观察共享状态，仅显示选中的一个来源；切换、删除或重试取消旧请求，并以代次标识拒绝迟到结果。来源配置和页面状态验证见 [阶段二验证](phase-two-validation.md)。

## 日志

已有日志记录点依用户要求全部移除。保留历史日志查看、时间保留规则、分页、复制、清空及完整文件系统分享能力。日志文件位于 Application Support/Logs/Vesper.log；分享通过当前 UIKit 控制器直接 present UIActivityViewController。

## 本地化与外观

默认跟随系统，支持简体中文、繁体中文、英语、德语、日语、韩语、西班牙语及法语。语言选项固定使用各语言自称。主题支持跟随系统、深色及浅色，系统 ColorPicker 调色；重置主题色在默认状态禁用。图标来自根目录 icon.jpg，外观页四列展示，当前仅默认图标。标签可选择系统符号，原生标签样式由系统决定。
