# 阶段二验证

当前实现是来源领域模型、共享状态、持久化和媒体页数据状态的首个切片，所有可添加来源明确标为“演示来源”，没有真实文件、凭据或播放能力。首次安装不自动添加演示来源，不伪造用户媒体库。

## 自动状态验证

`Tests/SourceLibraryChecks.swift` 覆盖空配置、名称清理、默认选择、两个来源切换、内容标识、空状态、失败/离线隔离、重启恢复、删除当前来源，以及忽略取消的旧请求不能覆盖新结果。

在 macOS 的仓库根目录运行（不改现有 workflow）：

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Vesper/Infrastructure/Sources/SourceLibrary.swift \
  Tests/SourceLibraryChecks.swift -o /tmp/vesper-source-checks
/tmp/vesper-source-checks
```

当前 Linux 工作环境没有 Apple Swift/Combine，不能执行这些状态检查；本地只执行 Swift 语法解析、资源、本地化和文档引用检查。现有 Actions 验证 iOS 编译及 IPA 产物，不自动运行本文件的状态检查，不能将构建通过视为交互验收通过。

## 设备复测

1. 来源页添加 A（示例内容）和 B（空来源），两个均标明演示，选择 A/B 分别查看媒体内容和空状态。
2. 在来源页改变选择后仍停留在来源页；主动打开媒体页才查看对应内容。
3. 将 B 改为连接失败或离线；媒体页显示对应状态和重试，重新选择 A 不受影响。
4. 快速切换 A/B，最终内容必须属于最后选择的来源；失败或取消不能覆盖新结果。
5. 重启后来源列表、状态和当前来源恢复；删除当前来源后媒体页恢复未选择，删除非当前来源不改变选择。
6. 标签组显隐、搜索、返回历史、主题和语言切换保持原有行为。

真实本地来源、网络协议、凭据、IMDb/Trakt 及 KSPlayer 接入仍按后续阶段实施，演示卡片没有播放按钮。
