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
            onSelect(SegmentInfo(
                road: attrs["road"] as? String ?? "",
                note: attrs["note"] as? String ?? "",
                access: attrs["access"] as? String ?? "不明",
                surface: attrs["surface"] as? String ?? "不明",
                restriction: attrs["restriction_text"] as? String ?? ""
            ))
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
