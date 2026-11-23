import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct AppPermissionsView: View {
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRequestingPhotos = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "应用权限", symbol: "hand.raised", description: "查看照片访问权限，了解本地网络访问方式，并前往系统设置管理授权。")
            SettingsSection {
                LabeledContent("照片图库", value: photoStatusText)
                if photoStatus == .notDetermined {
                    Button("请求照片访问权限", systemImage: "photo") {
                        requestPhotos()
                    }
                    .disabled(isRequestingPhotos)
                } else if photoStatus == .denied || photoStatus == .restricted {
                    Button("前往系统设置", systemImage: "arrow.up.forward.app") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            }
            SettingsSection {
                LabeledContent("本地网络", value: VesperLocalization.string("使用时由系统请求"))
                Text("连接局域网 Emby 服务器时，iOS 会显示本地网络访问提示。系统不向 App 提供权限状态查询 API。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("前往系统设置", systemImage: "arrow.up.forward.app") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
        .navigationTitle("应用权限")
        .task { photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
    }

    private var photoStatusText: String {
        switch photoStatus {
        case .authorized: VesperLocalization.string("已允许")
        case .limited: VesperLocalization.string("受限访问")
        case .denied: VesperLocalization.string("未允许")
        case .restricted: VesperLocalization.string("受系统限制")
        case .notDetermined: VesperLocalization.string("尚未请求")
        @unknown default: VesperLocalization.string("未知")
        }
    }

    private func requestPhotos() {
        isRequestingPhotos = true
        Task {
            photoStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            isRequestingPhotos = false
        }
    }
}
