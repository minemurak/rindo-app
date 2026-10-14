import SwiftUI

/// 出典と利用上の注意。国土地理院・OpenStreetMap・Open-Meteo の出典明示の決まりに合わせる。
struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("背景地図") {
                    Link("地理院タイル（国土地理院）", destination: URL(string: "https://maps.gsi.go.jp/development/ichiran.html")!)
                    Text("縮尺の小さい地図（ズーム8以下）の出所：The bathymetric contours are derived from those contained within the GEBCO Digital Atlas, published by the British Oceanographic Data Centre on behalf of IOC and IHO (2003)／海上保安庁許可第292502号（水路業務法第25条に基づく類似刊行物）／Shoreline data is derived from: United States. National Imagery and Mapping Agency. \"Vector Map Level 0 (VMAP0).\" Bethesda, MD: Denver, CO: The Agency; USGS Information Services, 1997.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("林道の線") {
                    Link("© OpenStreetMap contributors（ODbL）", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                }
                Section("通行可否・規制") {
                    Text("各林道の管理者（埼玉県・東京都森林事務所・上野村ほか）の公開情報をもとに作成。最新の状況は必ず管理者の情報と現地の標識で確認してください。")
                        .font(.footnote)
                }
                Section("天気") {
                    Link("Weather data by Open-Meteo.com（CC BY 4.0）", destination: URL(string: "https://open-meteo.com/")!)
                }
                Section("保存した地図について") {
                    Text("オフライン用に保存した地図は、ご自身の利用（私的利用）の範囲でお使いください。保存した地図を公開したり、それをもとに別の地図などを作ったりする場合は、国土地理院への申請が必要になることがあります。")
                        .font(.footnote)
                    Link("地図の利用手続ナビ（国土地理院）", destination: URL(string: "https://service.gsi.go.jp/onestop/navi/index/")!)
                    Link("国土地理院コンテンツ利用規約", destination: URL(string: "https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html")!)
                }
            }
            .navigationTitle("出典と注意")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
