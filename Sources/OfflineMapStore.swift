import Foundation
import MapLibre

/// 上武秩父線周辺の背景地図を、オフライン用に端末へ保存する（手順4）。
/// 地理院タイルの大量取得は利用条件上の制約があるため、範囲とズームを狭く保つ。
@MainActor
final class OfflineMapStore: NSObject, ObservableObject {
    @Published private(set) var status = "背景地図：未保存"
    @Published private(set) var isDownloading = false
    @Published private(set) var isComplete = false

    /// 保存する範囲（区間データの取得範囲と同じ）とズーム
    static let bounds = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(latitude: 36.08, longitude: 138.93),
        ne: CLLocationCoordinate2D(latitude: 36.13, longitude: 139.08))
    static let minZoom = 10.0
    static let maxZoom = 16.0
    static let contextKey = "joubu-chichibu"

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

    private var existingPack: MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first {
            String(data: $0.context, encoding: .utf8) == Self.contextKey
        }
    }

    func refresh() {
        guard let pack = existingPack else { return }
        pack.requestProgress()
        update(from: pack)
    }

    func download() {
        if let pack = existingPack {
            isDownloading = true
            pack.resume()
            return
        }
        let region = MLNTilePyramidOfflineRegion(
            styleURL: MapView.styleURL(), bounds: Self.bounds,
            fromZoomLevel: Self.minZoom, toZoomLevel: Self.maxZoom)
        guard let context = Self.contextKey.data(using: .utf8) else { return }
        isDownloading = true
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

    @objc private func progressChanged(_ note: Notification) {
        guard let pack = note.object as? MLNOfflinePack,
              String(data: pack.context, encoding: .utf8) == Self.contextKey else { return }
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
