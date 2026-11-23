import SwiftUI
import UIKit

private extension AppCacheCategory {
    var label: String {
        switch self {
        case .library: VesperLocalization.string("媒体库信息")
        case .images: VesperLocalization.string("图片")
        case .videos: VesperLocalization.string("视频")
        case .subtitles: VesperLocalization.string("字幕")
        case .danmaku: VesperLocalization.string("弹幕")
        case .other: VesperLocalization.string("其他")
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .images: "photo"
        case .videos: "film"
        case .subtitles: "captions.bubble"
        case .danmaku: "text.bubble"
        case .other: "archivebox"
        }
    }
}

struct CacheManagementView: View {
    @State private var sizes: [AppCacheCategory: Int64] = [:]
    @State private var selecting = false
    @State private var selected: Set<AppCacheCategory> = []
    @State private var confirmation: Set<AppCacheCategory> = []
    @State private var showsConfirmation = false
    @State private var clearing = false
    @State private var failed: [String] = []
    @State private var showsFailure = false

    private var categoriesToClear: Set<AppCacheCategory> {
        selecting ? selected : Set(AppCacheCategory.allCases)
    }

    var body: some View {
        CacheCategoryList(sizes: sizes, selecting: $selecting, selected: $selected, clearing: clearing)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .accessibilityAction(named: Text("选择缓存类别")) {
                if !clearing { selecting = true }
            }
            .navigationBarBackButtonHidden(selecting)
            .toolbar {
                if selecting {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            selecting = false
                            selected.removeAll()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel("完成")
                        .tint(nil)
                        Button { selected = Set(AppCacheCategory.allCases) } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel("全选")
                        .tint(nil)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmation = categoriesToClear
                        showsConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清理")
                    .tint(nil)
                    .disabled(clearing || categoriesToClear.isEmpty)
                }
            }
            .alert(selecting ? "清理选中的缓存？" : "清理所有缓存？", isPresented: $showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    let categories = confirmation
                    clearing = true
                    Task {
                        let cache = AppCacheStore.shared
                        let failures = await cache.clear(categories)
                        sizes = await cache.sizes()
                        selected.subtract(categories.subtracting(failures))
                        failed = AppCacheCategory.allCases.filter { failures.contains($0) }.map(\.label)
                        clearing = false
                        showsFailure = !failed.isEmpty
                    }
                }
            }
            .alert("部分缓存无法清理", isPresented: $showsFailure) {
                Button("好", role: .cancel) {}
            } message: {
                Text(verbatim: failed.joined(separator: "、"))
            }
            .task { sizes = await AppCacheStore.shared.sizes() }
    }
}

/// UITableView headers need measuring again once their actual width is known.
private final class IntroCardTableView: UITableView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let header = tableHeaderView, bounds.width > 0 else { return }
        let size = header.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let target = CGSize(width: bounds.width, height: ceil(size.height))
        if header.frame.size != target {
            header.frame.size = target
            tableHeaderView = header
        }
    }
}

private struct CacheCategoryList: UIViewRepresentable {
    let sizes: [AppCacheCategory: Int64]
    @Binding var selecting: Bool
    @Binding var selected: Set<AppCacheCategory>
    let clearing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = IntroCardTableView(frame: .zero, style: .insetGrouped)
        table.allowsSelectionDuringEditing = true
        table.allowsMultipleSelectionDuringEditing = true
        table.estimatedRowHeight = 52
        table.rowHeight = UITableView.automaticDimension
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let header = UIView()
        let card = UIHostingConfiguration {
            SettingsIntroCard(title: "缓存管理", symbol: "internaldrive",
                              description: "查看各类缓存占用，选择类别清理或一次清理全部缓存。")
        }.margins(.all, 0).makeContentView()
        card.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12)
        ])
        table.tableHeaderView = header
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        let changedSizes = coordinator.view.sizes != sizes
        coordinator.view = self
        table.isUserInteractionEnabled = !clearing
        if table.isEditing != selecting { table.setEditing(selecting, animated: true) }
        if changedSizes { table.reloadData() }
        let selectedRows = Set(table.indexPathsForSelectedRows ?? [])
        let desiredRows = Set(AppCacheCategory.allCases.enumerated().compactMap { index, category in
            selecting && selected.contains(category) ? IndexPath(row: index, section: 0) : nil
        })
        for row in selectedRows.subtracting(desiredRows) { table.deselectRow(at: row, animated: false) }
        for row in desiredRows.subtracting(selectedRows) { table.selectRow(at: row, animated: false, scrollPosition: .none) }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var view: CacheCategoryList
        init(_ view: CacheCategoryList) { self.view = view }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            AppCacheCategory.allCases.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let category = AppCacheCategory.allCases[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "CacheCategory")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "CacheCategory")
            var content = UIListContentConfiguration.valueCell()
            content.image = UIImage(systemName: category.symbol)
            content.imageProperties.tintColor = tableView.tintColor
            content.prefersSideBySideTextAndSecondaryText = true
            content.textProperties.numberOfLines = 0
            content.textProperties.lineBreakMode = .byWordWrapping
            content.textProperties.adjustsFontSizeToFitWidth = false
            content.secondaryTextProperties.numberOfLines = 1
            content.text = VesperLocalization.string(category.label)
            content.secondaryText = view.sizes[category].map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—"
            cell.contentConfiguration = content
            return cell
        }

        func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            !view.clearing
        }

        func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            tableView.setEditing(true, animated: true)
            view.selecting = true
        }

        func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
            tableView.isEditing ? indexPath : nil
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            view.selected.insert(AppCacheCategory.allCases[indexPath.row])
        }

        func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
            view.selected.remove(AppCacheCategory.allCases[indexPath.row])
        }

        func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
            .none
        }
    }
}
