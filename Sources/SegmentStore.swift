import Foundation
import Supabase

/// 区間データ（GeoJSON）を Supabase から取り、端末に保存する。
/// 通信できないときは、前回保存したデータを使う。
@MainActor
final class SegmentStore: ObservableObject {
    /// 地図に渡す GeoJSON（地図表示用に属性を整えたもの）
    @Published private(set) var geojson: Data?
    /// 画面下に出す状態の説明
    @Published private(set) var status = "読み込み中…"

    /// 試作で表示する範囲（上武秩父線の周辺）
    static let bbox = BBox(min_lon: 138.93, min_lat: 36.08, max_lon: 139.08, max_lat: 36.13)

    struct BBox: Encodable, Sendable {
        let min_lon: Double, min_lat: Double, max_lon: Double, max_lat: Double
    }

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("segments.geojson")
    }()

    func load() async {
        guard let url = URL(string: Secrets.supabaseURL), !Secrets.supabaseAnonKey.isEmpty else {
            useCache(reason: "接続情報が未設定")
            return
        }
        let client = SupabaseClient(supabaseURL: url, supabaseKey: Secrets.supabaseAnonKey)
        let started = Date()
        do {
            let raw = try await client.rpc("segments_in_bbox", params: Self.bbox).execute().data
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let prepared = try Self.prepareForMap(raw)
            try prepared.write(to: cacheURL, options: .atomic)
            geojson = prepared
            status = "オンライン：\(Self.featureCount(prepared))区間を取得（\(ms)ミリ秒）"
            print("[RindoApp] segments_in_bbox: \(ms) ms")
        } catch {
            print("[RindoApp] fetch failed: \(error)")
            useCache(reason: "通信できません")
        }
    }

    private func useCache(reason: String) {
        if let data = try? Data(contentsOf: cacheURL) {
            geojson = data
            status = "オフライン（\(reason)）：保存済みの\(Self.featureCount(data))区間を表示"
        } else {
            status = "\(reason)：保存済みのデータもありません"
        }
    }

    /// 関数の結果を地図で扱いやすい形にする。
    /// 規制は入れ子の配列なので、地図の色分け用に「規制あり」と規制名の文字列を足す。
    static func prepareForMap(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        root["features"] = features.map { feature -> [String: Any] in
            var f = feature
            var props = f["properties"] as? [String: Any] ?? [:]
            let restrictions = props["restrictions"] as? [[String: Any]] ?? []
            let kinds = restrictions.compactMap { $0["kind"] as? String }
            props["restricted"] = !kinds.isEmpty
            props["restriction_text"] = kinds.joined(separator: "、")
            props.removeValue(forKey: "restrictions")
            f["properties"] = props
            return f
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func featureCount(_ data: Data) -> Int {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["features"] as? [Any])?.count ?? 0
    }
}
