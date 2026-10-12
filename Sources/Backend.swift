import Foundation
import Supabase

/// Supabase への接続（アプリ全体で1つ）。接続情報は Secrets.swift（ビルド時に GitHub の Secrets から作る）。
enum Backend {
    static let client: SupabaseClient? = {
        // 貼り付け時に混じりやすい空白・末尾の「/」・「/rest/v1」を取り除く
        var urlText = Secrets.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/", "/rest/v1", "/rest/v1/"] where urlText.hasSuffix(suffix) {
            urlText.removeLast(suffix.count)
        }
        let key = Secrets.supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlText), url.host != nil, !key.isEmpty else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var host: String { client.map { _ in URL(string: Secrets.supabaseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "" } ?? "" }
}
