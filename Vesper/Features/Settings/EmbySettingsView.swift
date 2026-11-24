import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct EmbySettingsView: View {
    @ObservedObject private var trakt = TraktAccountStore.shared
    @State private var showsTraktAccount = false
    @State private var showsProgressPriority = false
    @AppStorage(EmbySkipSettings.introKey) private var skipIntro = false
    @AppStorage(EmbySkipSettings.outroKey) private var skipOutro = false
    @AppStorage(EmbySkipSettings.bodyPreloadKey) private var bodyPreload = false
    @State private var showsSkipDatabases = false
    @AppStorage(EmbyPreloadCacheSettings.nextPercentKey) private var preloadNextPercent = 90
    @AppStorage(EmbyPreloadCacheSettings.nextWiFiKey) private var preloadNextWiFi = true
    @AppStorage(EmbyPreloadCacheSettings.nextCellularKey) private var preloadNextCellular = false
    @AppStorage(EmbyPreloadCacheSettings.wifiKey) private var wifiCacheMB = 500
    @AppStorage(EmbyPreloadCacheSettings.cellularKey) private var cellularCacheMB = 500
    @AppStorage(EmbyBrowsingSettings.fullRenderingKey) private var waitsForArtwork = false
    @AppStorage(EmbyTrackPreferences.audioLanguageKey) private var audioLanguage = ""
    @AppStorage(EmbyTrackPreferences.subtitleLanguageKey) private var subtitleLanguage = ""
    @AppStorage(EmbyTrackPreferences.disableMissingSubtitleKey) private var disableMissingSubtitle = false

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "Emby 设置", symbol: "server.rack", description: "连接 Trakt，设置续播进度优先级、片头片尾跳过、下一集预加载与音频字幕偏好。")
            SettingsSection("观看记录") {
                Button {
                    if trakt.isConnected { showsTraktAccount = true } else { trakt.connect() }
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: "Trakt").font(.body)
                            .foregroundStyle(Color(uiColor: .label))
                        Spacer()
                        if trakt.isConnecting { ProgressView() }
                        else if trakt.isConnected { Text("已连接").foregroundStyle(.secondary) }
                        else { Text("未连接").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(trakt.isConnecting)
                Button {
                    showsProgressPriority = true
                } label: {
                    HStack {
                        Text("播放进度优先级")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
            SettingsSection("音频与字幕") {
                SettingsPicker("默认音轨语言", selection: $audioLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(LocalizedStringKey(EmbyTrackPreferences.languages[index].1))
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                SettingsPicker("默认字幕语言", selection: $subtitleLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(LocalizedStringKey(EmbyTrackPreferences.languages[index].1))
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                Toggle("无对应语言时关闭字幕", isOn: $disableMissingSubtitle)
            }
            SettingsSection("跳过片头片尾") {
                Toggle("自动跳过片头", isOn: $skipIntro)
                Toggle("自动跳过片尾", isOn: $skipOutro)
                Button { showsSkipDatabases = true } label: {
                    HStack {
                        Text("片头片尾数据库")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                Text("按数据库顺序查询，首个有效结果命中后停止。不支持手动标记；外部媒体 ID、季集编号和视频时长会发送给已启用的数据库。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsSection("预加载下一集") {
                Toggle("Wi-Fi 下预加载", isOn: $preloadNextWiFi)
                Toggle("蜂窝网络下预加载", isOn: $preloadNextCellular)
                Toggle("按正片时长预加载", isOn: $bodyPreload)
                Stepper(value: $preloadNextPercent, in: 1...99) {
                    LabeledContent("预加载触发进度", value: "\(preloadNextPercent)%")
                }
                Text("Aether 播放分集达到设定百分比时，按当前版本的封装、编码、动态范围及分辨率选择下一集版本，预读开头约 8 MB，必要时读取尾部索引。预读缓存不设定时过期；播放下一集时复用，停止、切换视频或网络策略不允许时清理。VLC 和原生远程 HLS 暂不支持。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("视频预加载缓存") {
                SettingsPicker("Wi-Fi", selection: $wifiCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                SettingsPicker("蜂窝网络", selection: $cellularCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                Text("每次打开 Emby 视频时按当前网络应用。此设置限制 Aether 支持的临时媒体缓存容量。Aether 原生远程 HLS 暂不支持此设置。SwiftVLC 的网络缓冲固定为 5 秒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("浏览显示") {
                NavigationLink("图标库") { EmbyIconLibrarySettingsView() }
                Toggle("完整加载后渲染", isOn: $waitsForArtwork)
            }
        }
        .alert("连接失败", isPresented: Binding(get: { trakt.errorMessage != nil }, set: { if !$0 { trakt.errorMessage = nil } })) {
            Button("好", role: .cancel) { trakt.errorMessage = nil }
        } message: {
            Text(trakt.errorMessage ?? "")
        }
        .sheet(isPresented: $showsTraktAccount) { TraktAccountSheet() }
        .sheet(isPresented: $showsProgressPriority) { EmbyProgressPrioritySheet() }
        .sheet(isPresented: $showsSkipDatabases) { EmbySkipDatabasesView() }
        .task {
            if ["zho", "chi", "zh"].contains(audioLanguage) { audioLanguage = "zh-Hans" }
            if ["zho", "chi", "zh"].contains(subtitleLanguage) { subtitleLanguage = "zh-Hans" }
        }
    }
}
