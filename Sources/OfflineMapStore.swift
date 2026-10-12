import Foundation
import MapLibre
import CoreLocation
import CryptoKit

/// 林道ごとに、その林道沿いの背景地図をオフライン用に端末へ保存する（方式A）。
/// 地理院タイルの大量取得は利用条件上の制約があるため、林道の両側約1kmの帯だけを保存し、
/// 最大ズームは15にする（高精細画面では実質16相当まで保存される）。
@MainActor
final class OfflineMapStore: NSObject, ObservableObject {

    enum Kind: Equatable {
        case none           // 未保存
        case downloading    // 保存中
        case paused         // 途中まで保存
        case complete       // 保存済み
        case outdated       // 保存後に林道の線が変わった（保存し直しが必要）
    }

    struct RoadState: Equatable {
        var kind: Kind = .none
        var percent = 0
        var bytes: UInt64 = 0
    }

    /// 林道名ごとの保存状態
    @Published private(set) var roads: [String: RoadState] = [:]
    /// 画面下に出す、保存状態のまとめ
    @Published private(set) var summary = "林道をタップすると、その林道沿いの地図を保存できます"

    static let minZoom = 10.0
    static let maxZoom = 15.0
    /// 林道の両側に取る幅（メートル）と、帯を作るときの区切りの長さ
    static let bufferMeters = 1000.0
    static let chunkMeters = 500.0
    /// 林道ごとの保存の目印：「road-v1:<指紋>:<林道名>」
    static let roadPrefix = "road-v1:"
    /// 以前の「全林道まとめて保存」の目印。林道ごとの保存が1本でも終わったら消す
    static let legacyPrefixes = ["corridor-v2:", "corridor-v1", "joubu-chichibu"]

    /// いまの区間データから作った、林道名 → その林道の線の指紋
    private var fingerprints: [String: String] = [:]
    /// いまの区間データから作った、林道名 → その林道の線（座標）
    private var lines: [String: [[[Double]]]] = [:]

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

    // MARK: - 状態の確認

    func state(of road: String) -> RoadState { roads[road] ?? RoadState() }

    /// 区間データが読み込まれたり変わったりしたときに呼ぶ
    func sync(segments: Data?) {
        lines = segments.map(Self.linesByRoad(from:)) ?? [:]
        fingerprints = lines.mapValues(Self.fingerprint(of:))
        refresh()
    }

    func refresh() {
        var next: [String: RoadState] = [:]
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            guard let (fp, road) = Self.parse(pack) else { continue }
            pack.requestProgress()
            var s = Self.state(from: pack)
            if let current = fingerprints[road], current != fp {
                s.kind = .outdated
            }
            // 同じ林道に古い保存と新しい保存がある場合は、新しい方を優先する
            if let existing = next[road], existing.kind != .outdated, s.kind == .outdated { continue }
            next[road] = s
        }
        roads = next
        updateSummary()
    }

    // MARK: - 保存と削除

    /// 指定した林道沿いの地図を保存する（途中まで保存済みなら再開する）
    func download(road: String) {
        guard let fp = fingerprints[road], let roadLines = lines[road],
              let shape = Self.corridor(of: roadLines) else {
            summary = "地図を保存できません（林道のデータがまだありません）"
            return
        }
        if let pack = pack(for: road, fingerprint: fp) {
            pack.resume()
            roads[road, default: RoadState()].kind = .downloading
            return
        }
        let region = MLNShapeOfflineRegion(
            styleURL: MapView.styleURL(), shape: shape,
            fromZoomLevel: Self.minZoom, toZoomLevel: Self.maxZoom)
        guard let context = (Self.roadPrefix + fp + ":" + road).data(using: .utf8) else { return }
        roads[road] = RoadState(kind: .downloading)
        updateSummary()
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.roads[road] = RoadState()
                    self.summary = "「\(road)」の地図を保存できませんでした（\(error.localizedDescription)）"
                    return
                }
                pack?.resume()
            }
        }
    }

    /// 指定した林道の保存済みの地図を消す
    func remove(road: String) {
        for pack in MLNOfflineStorage.shared.packs ?? [] where Self.parse(pack)?.road == road {
            MLNOfflineStorage.shared.removePack(pack, withCompletionHandler: nil)
        }
        roads[road] = nil
        updateSummary()
    }

    private func pack(for road: String, fingerprint: String) -> MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first {
            Self.key(of: $0) == Self.roadPrefix + fingerprint + ":" + road
        }
    }

    /// 林道の線が変わって古くなった保存と、以前の「まとめて保存」を消す
    private func removeObsoletePacks(for road: String) {
        for pack in MLNOfflineStorage.shared.packs ?? [] {
            guard let key = Self.key(of: pack) else { continue }
            let isLegacy = Self.legacyPrefixes.contains { key.hasPrefix($0) }
            let isOldVersion = Self.parse(pack).map { $0.road == road && $0.fingerprint != fingerprints[road] } ?? false
            if isLegacy || isOldVersion {
                MLNOfflineStorage.shared.removePack(pack, withCompletionHandler: nil)
            }
        }
    }

    // MARK: - 進み具合

    @objc private func progressChanged(_ note: Notification) {
        guard let pack = note.object as? MLNOfflinePack, let (fp, road) = Self.parse(pack) else { return }
        var s = Self.state(from: pack)
        if let current = fingerprints[road], current != fp {
            // 古い保存の進み具合は、新しい保存がなければ「保存し直し」として表示する
            guard roads[road] == nil || roads[road]?.kind == .outdated else { return }
            s.kind = .outdated
        } else if s.kind == .complete {
            removeObsoletePacks(for: road)
        }
        roads[road] = s
        updateSummary()
    }

    @objc private func packFailed(_ note: Notification) {
        let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        if let pack = note.object as? MLNOfflinePack, let (_, road) = Self.parse(pack) {
            roads[road]?.kind = .paused
            summary = "「\(road)」の地図の保存でエラー（\(error?.localizedDescription ?? "不明")）。もう一度押すと再開します"
        }
    }

    private static func state(from pack: MLNOfflinePack) -> RoadState {
        let p = pack.progress
        let total = max(p.countOfResourcesExpected, 1)
        let percent = Int(Double(p.countOfResourcesCompleted) / Double(total) * 100)
        let kind: Kind
        switch pack.state {
        case .complete: kind = .complete
        case .active: kind = .downloading
        default: kind = p.countOfResourcesCompleted > 0 ? .paused : .none
        }
        return RoadState(kind: kind, percent: min(percent, 100), bytes: p.countOfBytesCompleted)
    }

    private func updateSummary() {
        let saved = roads.filter { $0.value.kind == .complete }
        let mb = Double(saved.values.reduce(0) { $0 + $1.bytes }) / 1_048_576
        let downloading = roads.filter { $0.value.kind == .downloading }.count
        let outdated = roads.filter { $0.value.kind == .outdated }.count
        var parts: [String] = []
        parts.append(saved.isEmpty ? "保存済みの林道はありません" : String(format: "保存済み：%d本（%.1fMB）", saved.count, mb))
        if downloading > 0 { parts.append("保存中：\(downloading)本") }
        if outdated > 0 { parts.append("保存し直しが必要：\(outdated)本") }
        summary = parts.joined(separator: "　")
    }

    // MARK: - 目印・指紋・範囲の計算

    private static func key(of pack: MLNOfflinePack) -> String? {
        String(data: pack.context, encoding: .utf8)
    }

    /// 「road-v1:<指紋>:<林道名>」を分解する
    private static func parse(_ pack: MLNOfflinePack) -> (fingerprint: String, road: String)? {
        guard let key = key(of: pack), key.hasPrefix(roadPrefix) else { return nil }
        let rest = key.dropFirst(roadPrefix.count)
        guard let sep = rest.firstIndex(of: ":") else { return nil }
        return (String(rest[..<sep]), String(rest[rest.index(after: sep)...]))
    }

    /// 区間データを、林道名ごとの線の一覧にまとめる
    static func linesByRoad(from geojson: Data) -> [String: [[[Double]]]] {
        guard let root = try? JSONSerialization.jsonObject(with: geojson) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [:] }
        var result: [String: [[[Double]]]] = [:]
        for feature in features {
            guard let road = (feature["properties"] as? [String: Any])?["road"] as? String,
                  let geometry = feature["geometry"] as? [String: Any],
                  geometry["type"] as? String == "LineString",
                  let coords = geometry["coordinates"] as? [[Double]] else { continue }
            result[road, default: []].append(coords)
        }
        return result
    }

    /// 林道の線（座標）だけから指紋を作る。規制や名前が変わっても、線が同じなら保存し直さない
    static func fingerprint(of lines: [[[Double]]]) -> String {
        let text = lines.map { line in line.map { "\($0[0]),\($0[1])" }.joined(separator: ";") }
            .sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 線を約500mごとに区切り、それぞれの範囲を両側1km広げた四角を並べて、帯状の範囲を作る
    static func corridor(of lines: [[[Double]]]) -> MLNShape? {
        var polygons: [MLNPolygon] = []
        for coords in lines {
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
}
