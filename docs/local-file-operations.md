# 本地文件操作验证

选择本地视频来源后，媒体页显示文件夹和文件。顶部文件夹加号创建目录，长按项目可重命名、移动或删除。移动窗口从来源根目录浏览目标位置；重名不覆盖，删除需要确认。子目录视频使用相对于来源根目录的路径播放。

## 文件系统回归检查

在 macOS 仓库根目录运行：

```bash
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  Vesper/Infrastructure/Sources/LocalFileStore.swift \
  Tests/LocalFileStoreChecks.swift -o /tmp/vesper-local-file-checks
/tmp/vesper-local-file-checks
```

检查使用独立临时目录，覆盖创建、重命名、嵌套移动、内容保持、同名冲突、自身子目录、路径越界、符号链接、来源根目录保护和递归删除。本地 Linux 环境没有 Swift，不能执行此检查；现有 CI 验证 iOS 编译和产物，不自动运行这个独立检查。

## 真机验收

1. 本地来源为空时创建文件夹，进入后再创建子文件夹，返回上级。
2. 长按视频重命名，保留扩展名后确认可以播放。
3. 将视频移到子文件夹，进入后播放，再移回根目录。
4. 尝试同名重命名、同名移动、将文件夹移动到自身内部，确认不覆盖原文件。
5. 取消删除、确认删除、删除非空文件夹，确认目录即时刷新。
6. 重命名、移动或删除当前播放的视频及其父文件夹，确认播放器停止；不影响无关视频。
7. 从 Files 导入视频后，确认媒体页自动更新；切换相册来源不出现文件管理操作。
