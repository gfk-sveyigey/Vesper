import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct PlaybackLicensesView: View {
    @State private var selectedDependency: OpenSourceDependency?

    private let dependencies = [
        OpenSourceDependency(name: "AetherEngine", version: "7.72.0", license: "LGPL-3.0 + App Store / DRM Exception", resource: "AetherEngine-LICENSE", url: URL(string: "https://github.com/superuser404notfound/AetherEngine/tree/7.72.0")!),
        OpenSourceDependency(name: "FFmpeg", version: "FFmpegBuild 3.17.0", license: "LGPL-2.1-or-later", resource: "FFmpeg-LICENSE", url: URL(string: "https://ffmpeg.org/legal.html")!),
        OpenSourceDependency(name: "dav1d", version: "FFmpegBuild 3.17.0", license: "BSD-2-Clause", resource: "dav1d-LICENSE", url: URL(string: "https://code.videolan.org/videolan/dav1d/-/blob/master/COPYING")!),
        OpenSourceDependency(name: "zimg", version: "FFmpegBuild 3.17.0", license: "WTFPL-2.0", resource: "zimg-LICENSE", url: URL(string: "https://github.com/sekrit-twc/zimg/blob/master/COPYING")!),
        OpenSourceDependency(name: "zvbi", version: "FFmpegBuild 3.17.0", license: "GPL-2.0-or-later", resource: "zvbi-LICENSE", url: URL(string: "https://github.com/zapping-vbi/zvbi/blob/master/COPYING")!),
        OpenSourceDependency(name: "LibDovi", version: "2.2.0", license: "MIT / Apache-2.0", resource: "LibDovi-LICENSE", url: URL(string: "https://github.com/superuser404notfound/LibDovi/tree/2.2.0")!),
        OpenSourceDependency(name: "SwiftVLC", version: "1.0.0", license: "MIT", resource: "SwiftVLC-LICENSE", url: URL(string: "https://github.com/harflabs/SwiftVLC/tree/v1.0.0")!),
        OpenSourceDependency(name: "libVLC", version: "4", license: "LGPL-2.1-or-later", resource: "FFmpeg-LICENSE", url: URL(string: "https://www.videolan.org/legal.html")!)
    ]

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "开源许可", symbol: "doc.plaintext", description: "查看应用使用的开源项目、版本、许可证和项目主页。")
            SettingsSection {
                ForEach(dependencies.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { dependency in
                    HStack(spacing: 12) {
                        Button {
                            if dependency.resource != nil { selectedDependency = dependency }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: dependency.name).foregroundStyle(Color(uiColor: .label)).font(.body.weight(.medium))
                                Text(verbatim: "\(dependency.version) · \(dependency.license)")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(dependency.resource == nil)
                        Link(destination: dependency.url) {
                            Image(systemName: "arrow.up.right.square").font(.body).foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("打开项目主页")
                    }
                }
            } footer: {
                Text("点击有本地协议文本的项目查看完整协议；右侧按钮打开项目或官方许可页面。")
            }
        }
        .sheet(item: $selectedDependency) { dependency in
            LicenseDocumentSheet(dependency: dependency)
        }
    }
}

private struct OpenSourceDependency: Identifiable, Hashable {
    let name: String
    let version: String
    let license: String
    let resource: String?
    let url: URL
    var id: String { name }
    init(name: String, version: String, license: String, resource: String? = nil, url: URL) {
        self.name = name; self.version = version; self.license = license; self.resource = resource; self.url = url
    }
    var contents: String {
        guard let resource, let url = Bundle.main.url(forResource: resource, withExtension: "txt") else { return "许可内容暂不可用。" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "许可内容暂不可用。"
    }
}

private struct LicenseDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let dependency: OpenSourceDependency

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: dependency.contents)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(dependency.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension MediaLayoutSettings.Metric {
    var label: LocalizedStringKey {
        switch self {
        case .thumbnailHeight: "缩略图高度"
        case .groupSpacing: "媒体库分组上下间距"
        case .titlePadding: "媒体库分组标题上下间距"
        case .scrollPadding: "媒体库分组滚动区域上下间距"
        case .itemWidth: "媒体库分组项目宽度"
        case .itemHeight: "媒体库分组项目高度"
        case .itemVerticalPadding: "媒体库分组项目上下间距"
        case .itemSpacing: "媒体库分组项目左右间距"
        case .endPadding: "媒体库滚动区域左右内缩"
        case .episodeCardWidth: "剧集卡片宽度"
        case .episodeCardHeight: "剧集卡片高度"
        case .browserListTop: "媒体库列表上边距"
        case .browserListLeading: "媒体库列表左边距"
        case .browserListBottom: "媒体库列表下边距"
        case .browserListTrailing: "媒体库列表右边距"
        case .browserListRowHeight: "媒体库列表布局行高"
        case .browserListImageTop: "列表布局图片上间距"
        case .browserListImageLeading: "列表布局图片左间距"
        case .browserListImageBottom: "列表布局图片下间距"
        case .browserListImageTrailing: "列表布局图片右间距"
        case .sourceListRowHeight: "来源列表行高"
        case .sourceListIconTop: "来源图标上间距"
        case .sourceListIconLeading: "来源图标左间距"
        case .sourceListIconBottom: "来源图标下间距"
        case .sourceListIconTrailing: "来源图标右间距"
        case .mediaToolbarIconSize: "媒体页工具栏图标字号"
        case .mediaHeaderHeight: "Header 固定内容高度"
        case .mediaGlassStrength: "Header 下层毛玻璃强度"
        case .mediaGlassTint: "Header 毛玻璃颜色叠加强度"
        case .mediaGlassBorderWidth: "毛玻璃底边框宽度"
        case .mediaGlassBorderBlur: "毛玻璃底边框模糊强度"
        case .mediaGlassBorderOpacity: "毛玻璃底边框不透明度"
        case .mediaContentBlur: "Header 自身最大模糊"
        case .mediaContentBlurCurve: "Header 自身模糊曲线"
        case .mediaContentOpacityCurve: "Header 自身透明度曲线"
        case .mediaSnapThreshold: "Header 展开吸附阈值"
        case .mediaSnapCollapsedThreshold: "Header 收起吸附阈值"
        case .mediaSnapConflict: "Header 吸附冲突处理"
        case .mediaSnapDuration: "Header 吸附动画时长"
        case .mediaSnapCurve: "Header 吸附动画曲线"
        case .mediaEdgeTopStrength: "顶部边缘模糊顶端强度最小值"
        case .mediaEdgeTopMaxStrength: "顶部边缘模糊顶端强度最大值"
        case .mediaEdgeHeightCurve: "顶部边缘模糊高度曲线"
        case .mediaEdgeBottomStrength: "顶部边缘模糊底端强度"
        case .mediaEdgeTint: "顶部边缘模糊颜色叠加强度"
        case .mediaEdgeCurve: "顶部边缘模糊曲线"
        case .carouselBlurHeight: "底部模糊主体高度"
        case .carouselBlurFadeHeight: "上沿渐隐高度"
        case .carouselBlurStrength: "毛玻璃效果强度"
        case .carouselBlurTint: "轮播图底部颜色叠加强度"
        }
    }
}
