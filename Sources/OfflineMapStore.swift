import Foundation
import MapLibre
import CoreLocation
import CryptoKit

/// 林道沿いの背景地図を、オフライン用に端末へ保存する（手順4・方式A）。
/// 地理院タイルの大量取得は利用条件上の制約があるため、林道の両側約1kmの帯だけを保存し、
/// 最大ズームは15にする（それより拡大したときは15の地図を引き伸ばして表示）。
@MainActor
final class OfflineMapStore: NSObject, ObservableObject {
    @Published private(set) var status = "背景地図：未保存"
    @Published private(set) var isDownloading = false
    @Published private(set) var isComplete = false
    /// 保存した後に林道が追加・変更され、保存し直しが必要なとき true
    @Published private(set) var needsUpdate = false

    static let minZoom = 10.0
    static let maxZoom = 15.0
    /// 林道の両側に取る幅（メートル）と、帯を作るときの区切りの長さ
    static let bufferMeters = 1000.0
    static let chunkMeters = 500.0
    /// 保存した地図の目印。「corridor-v2:」のあとに、林道の線から作った指紋を付ける
    static let contextPrefix = "corridor-v2:"
    /// 以前の方式で保存したもの。新しく保存し終えたら消す
    static let legacyContextKeys = ["joubu-chichibu", "corridor-v1"]

    /// いま表示している林道の線の指紋（線が変わったら保存し直しが必要）
    private var currentFingerprint: String?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(progressChanged(_:)),
                           name: NSNotification.Name.MLNOfflinePackProgressChanged, object: nil)
        center.addObserver(self, selector: #selector(packFailed(_:)),
                           name: NSNotification.Name.MLNOfflinePackError, object: nil)
        // 保存済みの一覧は起動直後には読み込まれていないことがあるので、少し待って確認する
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.refresh()
        }
    }

    private static func key(of pack: MLNOfflinePack) -> String? {
        String(data: pack.context, encoding: .utf8)
    }

    private var currentPack: MLNOfflinePack? {
        guard let fp = currentFingerprint else { return nil }
        return MLNOfflineStorage.shared.packs?.first { Self.key(of: $0) == Self.contextPrefix + fp }
    }

    private var olderPacks: [MLNOfflinePack] {
        let currentKey = currentFingerprint.map { Self.contextPrefix + $0 }
        return (MLNOfflineStorage.shared.packs ?? []).filter { pack in
            guard let key = Self.key(of: pack), key != currentKey else { return false }
            return key.hasPrefix(Self.contextPrefix) || Self.legacyContextKeys.contains(key)
        }
    }

    func refresh() {
        if let pack = currentPack {
            needsUpdate = false
            pack.requestProgress()
            update(from: pack)
        } else if !olderPacks.isEmpty {
            isComplete = false
            needsUpdate = true
            status = "背景地図：林道が追加・変更されました。保存し直してください（今は以前の範囲を表示）"
        }
    }

    /// 区間データが読み込まれたり変わったりしたときに呼ぶ
    func sync(segments: Data?) {
        currentFingerprint = segments.flatMap(Self.fingerprint(of:))
        refresh()
    }

    /// 区間データ（GeoJSON）の線に沿った帯の範囲を保存する
    func download(segments: Data?) {
        currentFingerprint = segments.flatMap(Self.fingerprint(of:))
        if let pack = currentPack {
            isDownloading = true
            pack.resume()
            return
        }
        guard let segments, let fp = currentFingerprint, let corridor = Self.corridor(from: segments) else {
            status = "背景地図：林道のデータがまだないため保存できません"
            return
        }
        let region = MLNShapeOfflineRegion(
            styleURL: MapView.styleURL(), shape: corridor,
            fromZoomLevel: Self.minZoom, toZoomLevel: Self.maxZoom)
        guard let context = (Self.contextPrefix + fp).data(using: .utf8) else { return }
        isDownloading = true
        needsUpdate = false
        status = "背景地図：保存を開始…"
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isDownloading = false
                    self.status = "背景地図：保存に失敗（\(error.localizedDescription)）"
                    return
                }
                pack?.resume()
            }
        }
    }

    /// 林道の線（座標）だけから指紋を作る。規制や名前が変わっても、線が同じなら保存し直さない
    static func fingerprint(of geojson: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: geojson) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return nil }
        let lines = features.compactMap { ($0["geometry"] as? [String: Any])?["coordinates"] as? [[Double]] }
        guard !lines.isEmpty else { return nil }
        let text = lines.map { line in line.map { "\($0[0]),\($0[1])" }.joined(separator: ";") }
            .sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 新しい範囲を保存し終えたら、以前の地図を消して容量を空ける
    private func removeOlderPacks() {
        for pack in olderPacks {
            MLNOfflineStorage.shared.removePack(pack, withCompletionHandler: nil)
        }
    }

    /// 線を約500mごとに区切り、それぞれの範囲を両側1km広げた四角を並べて、帯状の範囲を作る
    static func corridor(from geojson: Data) -> MLNShape? {
        guard let root = try? JSONSerialization.jsonObject(with: geojson) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return nil }
        var polygons: [MLNPolygon] = []
        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  geometry["type"] as? String == "LineString",
                  let coords = geometry["coordinates"] as? [[Double]] else { continue }
            var chunk: [CLLocationCoordinate2D] = []
            var length = 0.0
            for c in coords where c.count >= 2 {
                let point = CLLocationCoordinate2D(latitude: c[1], longitude: c[0])
                if let last = chunk.last { length += distance(last, point) }
                chunk.append(point)
                if length >= chunkMeters {
                    polygons.append(box(around: chunk))
                    chunk = [point]
                    length = 0
                }
            }
            if !chunk.isEmpty { polygons.append(box(around: chunk)) }
        }
        return polygons.isEmpty ? nil : MLNMultiPolygon(polygons: polygons)
    }

    private static func box(around points: [CLLocationCoordinate2D]) -> MLNPolygon {
        let lat = points.map(\.latitude), lon = points.map(\.longitude)
        let midLat = (lat.min()! + lat.max()!) / 2
        let dLat = bufferMeters / 110_540
        let dLon = bufferMeters / (111_320 * cos(midLat * .pi / 180))
        var corners = [
            CLLocationCoordinate2D(latitude: lat.min()! - dLat, longitude: lon.min()! - dLon),
            CLLocationCoordinate2D(latitude: lat.min()! - dLat, longitude: lon.max()! + dLon),
            CLLocationCoordinate2D(latitude: lat.max()! + dLat, longitude: lon.max()! + dLon),
            CLLocationCoordinate2D(latitude: lat.max()! + dLat, longitude: lon.min()! - dLon),
            CLLocationCoordinate2D(latitude: lat.min()! - dLat, longitude: lon.min()! - dLon),
        ]
        return MLNPolygon(coordinates: &corners, count: UInt(corners.count))
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let dy = (b.latitude - a.latitude) * 110_540
        return (dx * dx + dy * dy).squareRoot()
    }

    @objc private func progressChanged(_ note: Notification) {
        guard let pack = note.object as? MLNOfflinePack,
              let key = Self.key(of: pack), let fp = currentFingerprint,
              key == Self.contextPrefix + fp else { return }
        update(from: pack)
    }

    @objc private func packFailed(_ note: Notification) {
        let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        isDownloading = false
        status = "背景地図：保存エラー（\(error?.localizedDescription ?? "不明")）"
    }

    private func update(from pack: MLNOfflinePack) {
        let p = pack.progress
        let done = p.countOfResourcesCompleted
        let total = max(p.countOfResourcesExpected, 1)
        let mb = Double(p.countOfBytesCompleted) / 1_048_576
        if pack.state == .complete {
            isDownloading = false
            isComplete = true
            needsUpdate = false
            removeOlderPacks()
            status = String(format: "背景地図：保存済み（%llu件・%.1fMB）機内モードで確認できます", done, mb)
        } else if pack.state == .active {
            isDownloading = true
            let percent = Int(Double(done) / Double(total) * 100)
            status = String(format: "背景地図：保存中 %d%%（%llu／%llu件・%.1fMB）", percent, done, total, mb)
        } else {
            isDownloading = false
            status = String(format: "背景地図：途中まで保存（%llu／%llu件）。もう一度押すと再開", done, total)
        }
    }
}
