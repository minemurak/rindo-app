import SwiftUI
import CoreLocation

/// 林道を地図に重ねて表示する画面。
/// 線をタップすると区間の情報が出て、その林道沿いの地図をオフライン用に保存できる。
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
                    SegmentCard(info: s, offline: offline.state(of: s.road),
                                onSave: { offline.download(road: s.road) },
                                onRemove: { offline.remove(road: s.road) },
                                onClose: { selected = nil })
                }
                Legend()
                Text(offline.summary)
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
                Text("地図・一部の線：国土地理院　線：© OpenStreetMap contributors")
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
        .onChange(of: store.geojson) { _, newValue in
            offline.sync(segments: newValue)
        }
    }
}

private struct SegmentCard: View {
    let info: MapView.SegmentInfo
    let offline: OfflineMapStore.RoadState
    let onSave: () -> Void
    let onRemove: () -> Void
    let onClose: () -> Void

    /// 検索する言葉：名前に「林道」が入っていなければ付ける（例：上武秩父線 → 林道 上武秩父線）
    private var searchURL: URL? {
        let query = info.road.contains("林道") ? info.road : "林道 \(info.road)"
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // 林道名をタップすると、ブラウザで林道名を検索する（通行止め情報や走行記録を探す用）
                if let url = searchURL {
                    Link(destination: url) {
                        Label(info.road, systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                    }
                    .accessibilityHint("ブラウザで林道名を検索します")
                } else {
                    Text(info.road).font(.headline)
                }
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
            HStack(spacing: 8) {
                if !info.ends.isEmpty { NaviMenu(info: info) }
            }
            .padding(.top, 4)
            offlineRow
            Text("通行の可否は、必ず現地の標識と管理者の最新情報で確認してください")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// この林道沿いの地図の保存状態と操作
    @ViewBuilder private var offlineRow: some View {
        let mb = String(format: "%.1fMB", Double(offline.bytes) / 1_048_576)
        HStack(spacing: 8) {
            switch offline.kind {
            case .none:
                Button(action: onSave) { Label("この林道の地図を保存", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                ProgressView(value: Double(offline.percent), total: 100)
                    .frame(maxWidth: 140)
                Text("保存中 \(offline.percent)%").font(.caption)
            case .paused:
                Button(action: onSave) { Label("保存を再開（\(offline.percent)%）", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            case .complete:
                Label("保存済み（\(mb)）", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Spacer()
                Button(role: .destructive, action: onRemove) { Text("削除") }
                    .buttonStyle(.bordered)
            case .outdated:
                Button(action: onSave) { Label("線が更新されたため保存し直す", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.subheadline)
    }
}

/// 外部のナビアプリで、林道の端までの道案内を始める。
/// 目的地は林道の端（入口）。林道の中は案内させず、走れるかどうかは現地で判断してもらう。
private struct NaviMenu: View {
    let info: MapView.SegmentInfo

    var body: some View {
        Menu {
            if info.access == "不可" || !info.restriction.isEmpty {
                Text("この区間には通行止め・走行禁止などがあります。現地の標識と管理者の情報を確認してください")
            }
            ForEach(Array(info.ends.enumerated()), id: \.offset) { index, end in
                Section(title(of: end, nearest: index == 0)) {
                    if let url = appleMapsURL(end) {
                        Link(destination: url) { Label("Apple マップ", systemImage: "map") }
                    }
                    if let url = googleMapsURL(end) {
                        Link(destination: url) { Label("Google マップ", systemImage: "car") }
                    }
                }
            }
        } label: {
            Label("ナビで行く", systemImage: "arrow.triangle.turn.up.right.diamond")
        }
        .buttonStyle(.bordered)
        .font(.subheadline)
    }

    private func title(of end: MapView.RoadEnd, nearest: Bool) -> String {
        guard let km = end.distanceKm else { return end.label }
        return String(format: "%@（直線 約%.0fkm%@）", end.label, km, nearest ? "・近い方" : "")
    }

    private func appleMapsURL(_ end: MapView.RoadEnd) -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "daddr", value: "\(end.latitude),\(end.longitude)"),
                         URLQueryItem(name: "dirflg", value: "d")]
        return c?.url
    }

    private func googleMapsURL(_ end: MapView.RoadEnd) -> URL? {
        var c = URLComponents(string: "https://www.google.com/maps/dir/")
        c?.queryItems = [URLQueryItem(name: "api", value: "1"),
                         URLQueryItem(name: "destination", value: "\(end.latitude),\(end.longitude)"),
                         URLQueryItem(name: "travelmode", value: "driving")]
        return c?.url
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
