# 开发环境与导航原型

## 临时构建基线

当前原型暂按 iOS（iPhone）、最低 iOS 26、Swift 6 建立；首发仅考虑 iOS（iPhone），不包含 iPadOS/macOS/tvOS；iOS 26 是当前构建基线。需要包含 iOS 26 SDK 的 Xcode 26 或更新版本。

`Vesper.xcodeproj` 是提交到仓库的原生工程，包含共享 `Vesper` scheme。当前没有第三方代码依赖，因此没有待锁定的 Package 版本；未来引入 KSPlayer 时须固定版本/commit 并提交解析结果。Bundle Identifier 为 `com.aholic.vesper`；真机签名和分发前需要配置团队。

## 在 macOS 上构建

```bash
xcodebuild -project Vesper.xcodeproj -scheme Vesper \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
open Vesper.xcodeproj
```

CI 沿用 `.github/workflows/build-dev.yml`，推送 dev 后在 macOS 26/Xcode 26 上构建无签名 iOS IPA 并上传工件，不发布 Release。所有开发提交仅推送到 dev；不推送工作区临时分支。已通过 dev 的 Actions 编译、无签名 IPA 打包及产物 smoke check。

## 当前原型范围

- 媒体、来源、记录、设置四个区域及各自的导航路径。
- 主区域使用原生 `TabView` / `Tab`，同时展示媒体、来源、记录、设置，由系统管理标签选择与布局。标签栏默认隐藏，点击右下角常驻多功能按钮显示；再次点击按钮或点击内容区域收起，内容点击正常执行原有操作，同时收起。
- 导航栏和系统标签栏使用公开 API 隐藏背景；安全区和标签布局交由系统处理。真实媒体接入后仍需验证栏下内容和对比度。
- 媒体、来源和记录暂为明确的空状态。设置提供可访问的外观说明；没有伪造来源、播放历史、账号连接或无效开关。
- 原型没有接入 KSPlayer、PiP、真实媒体来源或服务账号。来源选择与幕墙属于后续阶段。

## 验证状态与手动检查

本地环境是 Linux，无 Swift/Xcode；本地资源/引用/文档链接校验通过；校验脚本只保留在本地，不进入 Git。提交 `2b9dd4b` 已通过 [GitHub Actions](https://github.com/gfk-sveyigey/Vesper/actions/runs/42965416845) 的 Xcode 26 编译、无签名 IPA 打包、产物检查与上传。尚未执行模拟器/真机交互和无障碍验收，阶段一尚未达到全部退出条件。

在 macOS 上至少检查：

- iPhone 窄屏、横屏、不同 iPhone 屏幕宽度下，四个标签均可触达且不溢出。
- Light/Dark、较大动态字体、VoiceOver 和 Reduce Motion 下，标签名称、当前标签和可操作状态可理解。
- 设置详情返回正常；跨标签切换时各区域导航路径保留。
- 外接键盘的焦点移动和标签激活行为遵循系统；`Command-Shift-M` 切换标签栏。
- 标签栏默认隐藏；显示后点击内容同时收起标签组并正常触发原有操作；多功能按钮再次点击可隐藏。切换标签后仍可收起，且导航路径不丢失。
- 设置页滚动、透明栏对比度、安全区、点击目标尺寸。来源与媒体真实内容接入后重新检查滚动边缘效果。

原生标签栏布局与无障碍效果仍需设备验收。

## 日志

使用 Apple Unified Logging（`OSLog.Logger`），通过 `AppLog` 统一分类。导航诊断 trace 保存在 App 内“设置 > 运行日志”，不会输出到 Xcode Console；最多保留 90 天且数量上限可配置，默认 7 天/500 条，超出任一条件的旧日志会清理。日志以 UTF-8 文本存于 Application Support/Logs/Vesper.log，串行后台写入；运行日志页可整体导出 .log 文件或复制单条日志，不读取旧版偏好数据中的日志。其他类别仍使用系统日志，避免把敏感 URL、路径或凭据写入 App 内日志。

多功能按钮始终可见，挂载在应用根级安全区，不属于可隐藏的系统标签栏，也不被内容区域的收起遮罩覆盖。隐藏标签栏只影响四个系统标签，不隐藏该按钮。

## 原生标签栏实现更新

当前使用 UIViewRepresentable 包装 UIKit 原生 UITabBar，媒体/来源/记录/设置四个原生 UITabBarItem 条件加入 items，多功能 UITabBarItem 始终保留。已移除独立悬浮按钮及整条标签栏的隐藏逻辑。应用负责页面导航，系统负责标签项渲染；布局与点击行为仍需设备验收。此前 TabView/右下角独立按钮说明已被本节替代。

运行日志页首次呈现最近 100 条，可按每批 100 条加载更早记录；整体导出不受页面加载数量限制。当前导航诊断仅记录 Search Tab 触摸与手势、TabView selection Binding 写回、App selection 变化和 UIKit 布局采样的实际选中变化。旧的搜索关闭定时采样已移除。
