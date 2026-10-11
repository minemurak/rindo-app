import SwiftUI
import CoreLocation

/// 手順3の画面：上武秩父線を地図に重ねて表示する。
/// 線をタップすると区間の情報が出る。
struct ContentView: View {
    @StateObject private var store = SegmentStore()
    @StateObject private var offline = OfflineMapStore()
    @State private var selected: MapView.SegmentInfo?
    @State private var location = LocationPermission()

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapView(segments: store.geojson) { selected = $0 }
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                if let s = selected {
                    SegmentCard(info: s) { selected = nil }
                }
                Legend()
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        offline.download()
                    } label: {
                        Label(offline.isComplete ? "保存済み" : "地図をオフライン用に保存",
                              systemImage: offline.isComplete ? "checkmark.circle" : "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(offline.isDownloading || offline.isComplete)
                    if offline.isDownloading { ProgressView() }
                }
                .font(.subheadline)
                Text(offline.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(store.status)
                        .textSelection(.enabled)
                    Spacer()
                    Text("ビルド \(buildNumber)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("地図：国土地理院　線：© OpenStreetMap contributors")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(12)
        }
        .task {
            location.request()
            await store.load()
        }
    }
}

private struct SegmentCard: View {
    let info: MapView.SegmentInfo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(info.road).font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("閉じる")
            }
            Text(info.note).font(.subheadline)
            Text("一般通行：\(info.access)　路面：\(info.surface)").font(.subheadline)
            if !info.restriction.isEmpty {
                Label(info.restriction, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            Text("通行の可否は、必ず現地の標識と管理者の最新情報で確認してください")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            item(.blue, "通行可")
            item(.red, "通行不可")
            item(.gray, "不明")
            item(.orange, "規制あり", dashed: true)
        }
        .font(.caption)
    }

    private func item(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 3, dash: dashed ? [4, 3] : []))
                .frame(width: 18, height: 3)
            Text(label)
        }
    }
}

/// 現在地を地図に出すための許可を求める
final class LocationPermission {
    private let manager = CLLocationManager()
    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
