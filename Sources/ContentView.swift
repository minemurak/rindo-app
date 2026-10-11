import SwiftUI

/// 手順0用の最小画面。TestFlight経由でiPhoneに届くことを確かめるためのもの。
/// 手順3で地図画面に置き換える。
struct ContentView: View {
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private var isConfigured: Bool {
        !Secrets.supabaseURL.isEmpty && !Secrets.supabaseAnonKey.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("林道アプリ 試作")
                .font(.title.bold())
            Text("ビルド \(buildNumber)")
                .foregroundStyle(.secondary)
            Label(isConfigured ? "接続情報: 設定済み" : "接続情報: 未設定",
                  systemImage: isConfigured ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(isConfigured ? .green : .orange)
        }
        .padding()
    }
}
