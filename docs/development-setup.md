# 开发环境与导航原型

## 临时构建基线

当前原型暂按 iOS（iPhone）、最低 iOS 26、Swift 6 建立；这是基于已讨论的 iOS 26 原生材质体验采用的可调整基线，尚未替代待决事项中的正式平台确认。需要包含 iOS 26 SDK 的 Xcode 26 或更新版本。

`Vesper.xcodeproj` 是提交到仓库的原生工程，包含共享 `Vesper` scheme。当前没有第三方代码依赖，因此没有待锁定的 Package 版本；未来引入 KSPlayer 时须固定版本/commit 并提交解析结果。Bundle Identifier 为 `com.aholic.vesper`；真机签名和分发前需要配置团队。

## 在 macOS 上构建

```bash
python3 scripts/validate_project.py
xcodebuild -project Vesper.xcodeproj -scheme Vesper \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
open Vesper.xcodeproj
```

CI 沿用 `.github/workflows/build-dev.yml`，推送 dev 后在 macOS 26/Xcode 26 上构建无签名 iOS IPA 并上传工件，不发布 Release。所有开发提交仅推送到 dev；不推送工作区临时分支。首次远端运行前不能视为构建已通过。

## 当前原型范围

- 媒体、来源、记录、设置四个区域及各自的导航路径。
- 右下方多功能入口使用 `square.grid.2x2`，点击后向左展开标签，选择后收起。采用原生 Button 与 glass 样式组合，不是系统 Tab Bar。
- 导航栏背景隐藏；底部导航容器无背景，按钮采用原生材质。安全区保留可操作空间；后续真实媒体网格需要再次验证栏下内容延伸。
- 媒体、来源和记录暂为明确的空状态。设置提供可访问的外观说明；没有伪造来源、播放历史、账号连接或无效开关。
- 原型没有接入 KSPlayer、PiP、真实媒体来源或服务账号。来源选择与幕墙属于后续阶段。

## 验证状态与手动检查

当前开发环境是 Linux，无 Swift/Xcode；已运行 Python 资源/引用/文档链接校验，尚未运行 Apple 编译和模拟器/真机测试。阶段一尚未达到退出条件。

在 macOS 上至少检查：

- iPhone 窄屏、横屏、不同 iPhone 屏幕宽度下，四个标签均可触达且不溢出。
- Light/Dark、较大动态字体、VoiceOver 和 Reduce Motion 下，入口名称、当前标签、展开与收起状态可理解。
- 选择标签后选择器收起；设置详情返回正常；跨区域切换时各区域导航路径保留。
- 外接键盘的 Tab/激活和 `Command-Shift-M` 展开行为；必要时根据平台实测补充焦点控制。
- 设置页滚动、透明栏对比度、安全区、点击目标尺寸。来源与媒体真实内容接入后重新检查滚动边缘效果。

原生材质和标签展开动画是待验证的实现，不视为已经达到设备验收要求。

## 日志

使用 Apple Unified Logging（`OSLog.Logger`），通过 `AppLog` 统一分类。开发时在 Xcode Console 或 macOS Console 按 subsystem `com.aholic.vesper` 和 category 过滤。默认记录启动与关键状态变化；Debug 补充导航诊断。日志采用简短事件名，不重复打印时间戳和长堆栈。系统负责日志保留，不额外创建无界日志文件。当前没有日志导出界面。
