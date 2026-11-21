import SwiftUI
import UIKit
import ImageIO

@MainActor
final class EmbyIconLibraries: ObservableObject {
    static let shared = EmbyIconLibraries()
    @Published var links: [EmbyIconLibraryLink] {
        didSet {
            if let data = try? JSONEncoder().encode(links) {
                UserDefaults.standard.set(data, forKey: "emby.iconLibraries.v1")
            }
        }
    }
    private init() {
        links = UserDefaults.standard.data(forKey: "emby.iconLibraries.v1")
            .flatMap { try? JSONDecoder().decode([EmbyIconLibraryLink].self, from: $0) } ?? []
    }
}

struct EmbyIconLibrarySettingsView: View {
    @ObservedObject private var store = EmbyIconLibraries.shared
    @State private var editing: EmbyIconLibraryLink?
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "图标库", symbol: "square.grid.2x2",
                              description: "添加在线图标库，为 Emby 来源选择图标。")
            SettingsSection {
                if store.links.isEmpty {
                    Text("尚未添加图标库").foregroundStyle(.secondary)
                }
                ForEach(store.links) { link in
                    Button { editing = link } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: link.name).foregroundStyle(.primary)
                            Text(verbatim: URL(string: link.address)?.host ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { store.links.removeAll { $0.id == link.id } }
                        Button("编辑") { editing = link }.tint(.accentColor)
                    }
                }
                Button("添加图标库", systemImage: "plus") {
                    editing = .init(name: "", address: "")
                }
            } footer: {
                Text("支持包含 name、description 和 icons 的 JSON 图标库，图标条目使用 name 与 url。下载不会附带 Emby 登录信息。移除图标库不会影响已保存的来源图标。")
            }
        }
        .navigationTitle("图标库").toolbarTitleDisplayMode(.inline)
        .sheet(item: $editing) { link in
            EmbyIconLibraryEditor(link: link) { updated in
                if let index = store.links.firstIndex(where: { $0.id == updated.id }) { store.links[index] = updated }
                else { store.links.append(updated) }
            }
        }
    }
}

private struct EmbyIconLibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var link: EmbyIconLibraryLink
    let save: (EmbyIconLibraryLink) -> Void
    private var isNew: Bool { link.name.isEmpty && link.address.isEmpty }
    @State private var saving = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsIntroCard(title: isNew ? "添加图标库" : "编辑图标库", symbol: "square.grid.2x2",
                                  description: "添加在线图标库，为 Emby 来源选择图标。")
                SettingsSection {
                    TextField("名称", text: $link.name)
                    TextField("图标库链接", text: $link.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("保存时验证链接。名称留空时使用图标库名称。")
                }
                .disabled(saving)
                if saving { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .navigationTitle(isNew ? "添加图标库" : "编辑图标库").toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { validateAndSave() } label: { Image(systemName: "checkmark") }
                        .disabled(saving || link.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("保存")
                }
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private func validateAndSave() {
        saving = true; error = nil
        let candidate = link
        operation = Task {
            defer { saving = false }
            do {
                let catalog = try await EmbyIconLibraryClient.catalog(at: candidate.address)
                try Task.checkCancellation()
                var updated = candidate
                updated.address = try EmbyIconLibraryClient.url(candidate.address).absoluteString
                updated.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if updated.name.isEmpty { updated.name = catalog.name }
                save(updated); dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct EmbyLibraryIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = EmbyIconLibraries.shared
    let selected: (Data) -> Void
    @State private var libraryID: UUID?
    @State private var catalog: EmbyIconCatalog?
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var revision = 0
    @State private var pendingIcon: EmbyLibraryIcon?
    @State private var showingLibrarySettings = false
    private var link: EmbyIconLibraryLink? { store.links.first { $0.id == libraryID } }
    private var requestKey: String { "\(link?.address ?? "")|\(revision)" }
    private var icons: [EmbyLibraryIcon] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog?.icons.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.links.isEmpty {
                        ContentUnavailableView("尚未添加图标库", systemImage: "square.grid.2x2")
                    } else {
                        if loading { ProgressView().frame(maxWidth: .infinity) }
                        if let error {
                            Text(verbatim: error).foregroundStyle(.red)
                            Button("重试") { revision += 1 }
                        }
                        if let catalog {
                            Text(verbatim: catalog.name).font(.headline)
                            if !catalog.description.isEmpty {
                                Text(verbatim: catalog.description).font(.footnote).foregroundStyle(.secondary)
                            }
                            if icons.isEmpty {
                                ContentUnavailableView.search(text: search)
                            }
                            if pendingIcon != nil { ProgressView().frame(maxWidth: .infinity) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 16)], spacing: 16) {
                                ForEach(icons) { icon in
                                    EmbyLibraryIconTile(icon: icon) { pendingIcon = icon }
                                }
                            }
                            .disabled(pendingIcon != nil)
                        }
                    }
                }.padding()
            }
            .navigationTitle("从图标库选择").toolbarTitleDisplayMode(.inline)
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.links) { library in
                            Button {
                                libraryID = library.id
                            } label: {
                                HStack {
                                    Text(verbatim: library.name)
                                    if library.id == libraryID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .accessibilityLabel("选择图标库")

                    Button { showingLibrarySettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("管理图标库")

                    Button { revision += 1 } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(link == nil || loading)
                    .accessibilityLabel("刷新")
                }
            }
            .sheet(isPresented: $showingLibrarySettings) {
                NavigationStack { EmbyIconLibrarySettingsView() }
            }
            .onAppear { repairSelection() }
            .onChange(of: store.links) { _, _ in repairSelection() }
            .onChange(of: libraryID) { _, _ in pendingIcon = nil }
            .task(id: requestKey) { await load() }
            .task(id: pendingIcon?.id) { await saveIcon() }
        }
    }

    private func repairSelection() {
        if link == nil { libraryID = store.links.first?.id }
    }

    private func saveIcon() async {
        guard let icon = pendingIcon else { return }
        error = nil
        do {
            let bytes = try await EmbyIconLibraryClient.data(from: icon.url, limit: 8 * 1024 * 1024)
            try Task.checkCancellation()
            guard let image = EmbyLibraryImageCache.decode(bytes, maxPixel: 512),
                  let data = image.pngData() else { throw EmbyIconLibraryError.invalidImage }
            selected(data); dismiss()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription; pendingIcon = nil }
        }
    }

    private func load() async {
        catalog = nil; error = nil; pendingIcon = nil
        guard let address = link?.address else { loading = false; return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await EmbyIconLibraryClient.catalog(at: address)
            try Task.checkCancellation()
            catalog = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

@MainActor
private enum EmbyLibraryImageCache {
    static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()
}

private struct EmbyLibraryIconTile: View {
    let icon: EmbyLibraryIcon
    let selected: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var revision = 0
    var body: some View {
        VStack(spacing: 6) {
            Button {
                if image != nil { selected() }
                else if failed { revision += 1 }
            } label: {
                Group {
                    if let image {
                        Image(uiImage: image).renderingMode(.original).resizable().scaledToFit()
                    } else if failed {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    } else { ProgressView() }
                }
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(image == nil && !failed)
            .accessibilityLabel(Text(verbatim: icon.name))
            Text(verbatim: icon.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }
        .task(id: "\(icon.id)|\(revision)") {
            image = nil; failed = false
            if let cached = EmbyLibraryImageCache.images.object(forKey: icon.url as NSURL) { image = cached; return }
            do {
                let data = try await EmbyIconLibraryClient.data(from: icon.url, limit: 8 * 1024 * 1024)
                try Task.checkCancellation()
                guard let loaded = EmbyLibraryImageCache.decode(data, maxPixel: 128),
                      let cgImage = loaded.cgImage else { throw EmbyIconLibraryError.invalidImage }
                EmbyLibraryImageCache.images.setObject(loaded, forKey: icon.url as NSURL,
                                                       cost: cgImage.bytesPerRow * cgImage.height)
                image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
