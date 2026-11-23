import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct PlaybackLicensesView: View {
    @State private var selectedDocument: LicenseDocument?

    private let documents = [
        LicenseDocument(title: VesperLocalization.string("播放框架与依赖声明"), resource: "PlaybackNotices"),
        LicenseDocument(title: "AetherEngine", resource: "AetherEngine-LICENSE"),
        LicenseDocument(title: "SwiftVLC", resource: "SwiftVLC-LICENSE")
    ]

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "开源许可", symbol: "doc.plaintext", description: "了解应用使用的开源组件，查看各项目的许可与声明。")
            SettingsSection {
                ForEach(documents) { document in
                    Button {
                        selectedDocument = document
                    } label: {
                        HStack(spacing: 12) {
                            Text(document.title)
                                .foregroundStyle(Color(uiColor: .label))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $selectedDocument) { document in
            LicenseDocumentSheet(document: document)
        }
    }
}

private struct LicenseDocument: Identifiable {
    let title: String
    let resource: String
    var id: String { resource }
    var contents: String {
        Bundle.main.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? VesperLocalization.string("许可内容暂不可用。")
    }
}

private struct LicenseDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: LicenseDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: document.contents)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(document.title)
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

private extension MediaLayoutSettings.Metric {
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
