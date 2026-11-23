import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct TabSettingsView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.defaultTab") private var defaultTab = "media"
    @AppStorage("navigation.tabBarCanMinimize") private var tabBarCanMinimize = true
    @State private var isShowingResetConfirmation = false
    @State private var isShowingOrderSettings = false

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "标签设置", symbol: "rectangle.3.group", description: "选择显示的标签页，调整排列顺序、默认页面和标签栏收缩方式。")

                SettingsSection {
                    ForEach(sections.filter { $0 != .settings }) { section in
                        Toggle(isOn: Binding(
                            get: { !hidden.split(separator: ",").contains(Substring(section.rawValue)) },
                            set: { visible in
                                var values = Set(hidden.split(separator: ",").map(String.init))
                                if visible { values.remove(section.rawValue) } else { values.insert(section.rawValue) }
                                hidden = values.sorted().joined(separator: ",")
                                if !visible && defaultTab == section.rawValue { defaultTab = "settings" }
                            }
                        )) { SettingsLabel(LocalizedStringKey(section.title), symbol: section.symbol) }
                    }
                } footer: {
                    Text("关闭后，该页面将从标签栏移除，可能没有其他访问入口。需要使用时，请在此重新开启。设置标签始终保留。")
                }
                SettingsSection {
                    Toggle(isOn: $tabBarCanMinimize) {
                        SettingsLabel("允许标签栏收缩", symbol: "arrow.down.right.and.arrow.up.left")
                    }
                } footer: {
                    Text("关闭后，向下滚动页面时标签栏保持展开。")
                }
                SettingsSection {
                    Button { isShowingOrderSettings = true } label: {
                        Text("标签顺序")
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    SettingsPicker("默认标签页", selection: $defaultTab) {
                        ForEach(sections.filter { $0 == .settings || !hidden.split(separator: ",").contains(Substring($0.rawValue)) }) { section in
                            Text(section.title).tag(section.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("打开 App 时优先显示所选标签页；已关闭的标签不可设为默认。")
                }

            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    isShowingResetConfirmation = true
                }
                .labelStyle(.iconOnly)
                .tint(nil)
            }
        }
        .alert("恢复默认标签设置？", isPresented: $isShowingResetConfirmation) {
            Button("恢复默认", role: .destructive) {
                order = "media,sources,history,settings"
                hidden = ""
                defaultTab = "media"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将恢复标签的排列顺序、显示状态和默认标签页。")
        }
        .sheet(isPresented: $isShowingOrderSettings) {
            NavigationStack {
                TabOrderSettingsView()
                    .navigationTitle("标签顺序")
                    .vesperNavigationStyle(.inline)
                    .toolbarRole(.automatic)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("标签顺序").font(.headline)
                        }
                    }
            }
            .presentationDetents([.custom(TabOrderDetent.self)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(false)
            .presentationBackground(VesperTheme.background)
        }

    }

}
