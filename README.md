# Vesper

iOS 应用标识符：`com.aholic.vesper`。

最低支持 **iOS 26.0**，使用 Xcode 26 / iOS 26 SDK 构建，以使用 Liquid Glass（液态玻璃）界面及 API。

## GitHub Actions

流程参考 [Nox](https://github.com/gfk-sveyigey/Nox) 的 workflow：

- `build-dev.yml`：推送到 `dev` 时构建 Debug 无签名 IPA，保留工件 14 天；仅修改 `VERSION` 时跳过，也支持手动触发。
- `build-and-release.yml`：PR 合并到 `main` 后构建 Release 无签名 IPA，以 `VERSION` 创建 GitHub Release，附带 IPA 和 SHA256。已存在相同版本标签时跳过发布，PR 描述用作发布说明。

构建环境为 macOS 26 / Xcode 26，版本从根目录 `VERSION` 读取，构建号使用 GitHub Actions run number。两个流程均显式设置并验证应用标识符 `com.aholic.vesper` 和最低系统版本 `26.0`。

当前仓库尚未包含 iOS 工程。运行构建前需添加：

- 根目录 `Vesper.xcodeproj`，包含可由 CI 使用的共享 `Vesper` scheme，产物名称为 `Vesper.app`。
- 根目录 `Info.plist`，并在工程中正确引用；`CFBundleIdentifier` 应使用 `$(PRODUCT_BUNDLE_IDENTIFIER)`。
- 应用源码及所需资源，工程的 Bundle Identifier 同样设为 `com.aholic.vesper`，所有应用及扩展 target 的 iOS Deployment Target 设为 `26.0`。

`VERSION` 当前版本为 `0.1.1`，发布前更新为所需的语义化版本。IPA 未签名，安装前需要自行签名。
