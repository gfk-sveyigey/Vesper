# 阶段二验证

当前实现是来源领域模型、共享状态、持久化和媒体页数据状态的首个真实来源切片，支持相册视频与本地视频导入；Emby 尚未接入。首次安装不自动添加来源，不伪造用户媒体库。

## 自动状态验证

`Tests/SourceLibraryChecks.swift` 覆盖清理旧演示快照、本地视频导入、重复来源限制、重启恢复、删除来源、导入回滚，以及忽略取消的旧请求不能覆盖新结果。

在 macOS 的仓库根目录运行（不改现有 workflow）：

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Vesper/Infrastructure/Sources/SourceLibrary.swift \
  Tests/SourceLibraryChecks.swift -o /tmp/vesper-source-checks
/tmp/vesper-source-checks
```

当前 Linux 工作环境没有 Apple Swift/Combine，不能执行这些状态检查；本地只执行 Swift 语法解析、资源、本地化和文档引用检查。现有 Actions 验证 iOS 编译及 IPA 产物，不自动运行本文件的状态检查，不能将构建通过视为交互验收通过。

## 设备复测

1. 来源页添加相册视频，验证系统授权、来源唯一性和媒体列表。
2. 通过菜单添加本地视频，选择一个或多个视频，验证导入后显示为单独来源。
3. 取消或提交无效文件时，确认来源和已导入文件不被破坏。
4. 重启后来源列表、导入文件和当前来源恢复；删除来源不删除原始视频。
5. 切换相册视频与本地视频，最终内容必须属于最后选择的来源。
6. 标签组显隐、搜索、返回历史、主题和语言切换保持原有行为。

Emby、网络协议、凭据、IMDb/Trakt 及 KSPlayer 接入仍按后续阶段实施。当前媒体卡片仅浏览，不启动播放。
