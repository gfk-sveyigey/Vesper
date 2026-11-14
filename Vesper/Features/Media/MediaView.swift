import SwiftUI

struct MediaView: View {
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var isImporting = false

    var body: some View {
        if library.selectedSource == nil {
            VesperEmptyPage(title: "媒体", message: "未选择媒体来源", symbol: "film")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VesperLargeTitle("媒体")
                    if let source = library.selectedSource {
                        HStack {
                            Text(LocalizedStringKey(source.kind.titleKey)).font(.headline)
                            Spacer()
                            if source.kind == .local {
                                Button("导入视频", systemImage: "square.and.arrow.down") { isImporting = true }
                                    .disabled(library.isImporting)
                            }
                        }.padding(.horizontal, 20)
                    }
                    switch library.content {
                    case .unselected: EmptyView()
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .loaded(let items):
                        if items.isEmpty {
                            ContentUnavailableView("来源中暂无媒体", systemImage: "film")
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
                                ForEach(items) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: "film")
                                            .font(.largeTitle)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 150)
                                            .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 12))
                                        Text(verbatim: item.title).font(.headline)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    case .failed(let error):
                        ContentUnavailableView {
                            Label(LocalizedStringKey(error.messageKey), systemImage: "exclamationmark.triangle")
                        } actions: {
                            Button("重试") { library.reload() }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .refreshable { library.reload() }
            .vesperImmersiveTitle("媒体")
            .videoImporter(isPresented: $isImporting)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { library.reload() }
            }
        }
    }
}

struct VesperEmptyPage: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    @State private var titleHeight: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    VesperLargeTitle(title)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
                    VStack(spacing: 16) {
                        Image(systemName: symbol)
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color("VesperPrimaryText"))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, geometry.size.height))
                    .offset(y: -titleHeight)
                    .padding(.bottom, -titleHeight)
                }
            }
            .vesperImmersiveTitle(title)
        }
    }
}
