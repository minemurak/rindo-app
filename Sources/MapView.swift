import SwiftUI
import MapLibre
import CoreLocation

/// 林道の区間を、一般通行区分で色分けして表示する地図。
/// 可＝青、不可＝赤、不明＝灰。規制のある区間は橙の破線を重ねる。
struct MapView: UIViewRepresentable {
    let segments: Data?
    let onSelect: (SegmentInfo?) -> Void

    struct SegmentInfo: Equatable {
        let road: String
        let note: String
        let access: String
        let surface: String
        let restriction: String
        /// 林道の両端（外部ナビの目的地）。現在地に近い方が先
        let ends: [RoadEnd]
    }

    /// 林道の端：外部ナビの目的地にする
    struct RoadEnd: Equatable {
        let label: String          // 「西側の端」など
        let latitude: Double
        let longitude: Double
        let distanceKm: Double?    // 現在地からの直線距離（現在地が分からないときは nil）
    }

    static let sourceID = "segments"
    static let accessColors: [(String, UIColor)] = [
        ("可", .systemBlue), ("不可", .systemRed), ("不明", .systemGray)
    ]
    static var layerIDs: Set<String> {
        Set(accessColors.map { "segments-\($0.0)" } + ["segments-restricted"])
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: Self.styleURL())
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.setCenter(CLLocationCoordinate2D(latitude: 36.05, longitude: 138.95),
                      zoomLevel: 9.3, animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        // 地図自体のタップ操作（ズームなど）を邪魔しない
        for recognizer in map.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
            tap.require(toFail: recognizer)
        }
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.segments = segments
        if let style = map.style {
            context.coordinator.apply(to: style)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var segments: Data?
        var onSelect: (SegmentInfo?) -> Void
        private var appliedData: Data?

        init(onSelect: @escaping (SegmentInfo?) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            appliedData = nil
            apply(to: style)
        }

        /// GeoJSON を地図に反映する（初回はレイヤーも作る）
        func apply(to style: MLNStyle) {
            guard let data = segments, data != appliedData,
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue) else { return }
            appliedData = data

            if let source = style.source(withIdentifier: MapView.sourceID) as? MLNShapeSource {
                source.shape = shape
                return
            }
            let source = MLNShapeSource(identifier: MapView.sourceID, shape: shape, options: nil)
            style.addSource(source)

            for (access, color) in MapView.accessColors {
                let layer = MLNLineStyleLayer(identifier: "segments-\(access)", source: source)
                layer.predicate = NSPredicate(format: "access == %@", access)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: 5)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(layer)
            }

            let restricted = MLNLineStyleLayer(identifier: "segments-restricted", source: source)
            restricted.predicate = NSPredicate(format: "restricted == YES")
            restricted.lineColor = NSExpression(forConstantValue: UIColor.systemOrange)
            restricted.lineWidth = NSExpression(forConstantValue: 3)
            restricted.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
            style.addLayer(restricted)
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: map)
            // 指で押しやすいよう、少し広い範囲で探す
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let feature = map.visibleFeatures(in: rect, styleLayerIdentifiers: MapView.layerIDs).first
            guard let attrs = feature?.attributes else { onSelect(nil); return }
            let road = attrs["road"] as? String ?? ""
            onSelect(SegmentInfo(
                road: road,
                note: attrs["note"] as? String ?? "",
                access: attrs["access"] as? String ?? "不明",
                surface: attrs["surface"] as? String ?? "不明",
                restriction: attrs["restriction_text"] as? String ?? "",
                ends: roadEnds(of: road, from: map.userLocation?.location)
            ))
        }

        /// 林道の両端を求める。地図に描いた線は表示用に切り詰められていることがあるため、元の GeoJSON から取る。
        /// 区間の端点のうち、いちばん離れた2点を林道の両端とみなす。
        func roadEnds(of road: String, from user: CLLocation?) -> [RoadEnd] {
            guard let data = segments,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = root["features"] as? [[String: Any]] else { return [] }
            var points: [CLLocation] = []
            for f in features where (f["properties"] as? [String: Any])?["road"] as? String == road {
                guard let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [[Double]],
                      let first = coords.first, let last = coords.last,
                      first.count >= 2, last.count >= 2 else { continue }
                points.append(CLLocation(latitude: first[1], longitude: first[0]))
                points.append(CLLocation(latitude: last[1], longitude: last[0]))
            }
            guard points.count >= 2 else { return [] }
            var best = (points[0], points[1], -1.0)
            for i in points.indices {
                for j in points.indices where j > i {
                    let d = points[i].distance(from: points[j])
                    if d > best.2 { best = (points[i], points[j], d) }
                }
            }
            let (a, b, _) = best
            // 東西・南北のうち離れている向きで呼び分ける
            let dLon = abs(a.coordinate.longitude - b.coordinate.longitude) * cos(a.coordinate.latitude * .pi / 180)
            let dLat = abs(a.coordinate.latitude - b.coordinate.latitude)
            func label(_ p: CLLocation, _ q: CLLocation) -> String {
                if dLon >= dLat { return p.coordinate.longitude < q.coordinate.longitude ? "西側の端" : "東側の端" }
                return p.coordinate.latitude > q.coordinate.latitude ? "北側の端" : "南側の端"
            }
            var ends = [
                RoadEnd(label: label(a, b), latitude: a.coordinate.latitude, longitude: a.coordinate.longitude,
                        distanceKm: user.map { $0.distance(from: a) / 1000 }),
                RoadEnd(label: label(b, a), latitude: b.coordinate.latitude, longitude: b.coordinate.longitude,
                        distanceKm: user.map { $0.distance(from: b) / 1000 }),
            ]
            if let d0 = ends[0].distanceKm, let d1 = ends[1].distanceKm, d1 < d0 { ends.reverse() }
            return ends
        }
    }

    /// 背景地図：国土地理院の標準地図（ラスタ）。出典表示が必要。
    static func styleURL() -> URL {
        let style = """
        {
          "version": 8,
          "sources": {
            "gsi": {
              "type": "raster",
              "tiles": ["https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png"],
              "tileSize": 256,
              "minzoom": 5,
              "maxzoom": 18,
              "attribution": "国土地理院"
            }
          },
          "layers": [{ "id": "gsi", "type": "raster", "source": "gsi" }]
        }
        """
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gsi-style.json")
        try? style.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
