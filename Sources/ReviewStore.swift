import Foundation
import Supabase
import AuthenticationServices
import CryptoKit

/// 口コミの読み書きと、サインイン状態（Apple でサインイン）。
/// 読むのはサインインなしでもできる。書く・通報・ブロックはサインインが必要。
@MainActor
final class ReviewStore: ObservableObject {
    struct Review: Decodable, Identifiable, Equatable {
        let id: Int
        let author: String
        let is_mine: Bool?
        let author_id: String
        let driven_on: String
        let condition: String
        let body: String
        let hidden: Bool
        let created_at: String
    }

    static let conditions = ["良好", "普通", "荒れ", "通行できず"]
    static let reportReasons = ["不適切な内容", "走行禁止区間の走行", "スパム・宣伝", "その他"]

    @Published private(set) var reviews: [String: [Review]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var error: String?
    @Published private(set) var isSignedIn = false

    /// サインイン要求に付ける使い捨ての文字列（なりすまし防止）。Apple には SHA256 を渡す
    private var currentNonce: String?

    init() {
        isSignedIn = Backend.client?.auth.currentSession != nil
    }

    // MARK: 読む

    func load(road: String) async {
        guard let client = Backend.client else { error = "接続情報が未設定です"; return }
        loading.insert(road)
        defer { loading.remove(road) }
        do {
            let list: [Review] = try await client
                .rpc("reviews_for_road", params: ["road_name": road])
                .execute().value
            reviews[road] = list
            error = nil
        } catch {
            self.error = "口コミを読み込めません（通信できるときに表示）"
        }
    }

    // MARK: 書く

    struct NewReview: Encodable {
        let road_name: String
        let driven_on: String
        let condition: String
        let body: String
    }

    func post(road: String, drivenOn: Date, condition: String, body: String) async -> Bool {
        guard let client = Backend.client else { return false }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        do {
            _ = try await client.rpc("post_review", params: NewReview(
                road_name: road, driven_on: f.string(from: drivenOn), condition: condition,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines))).execute()
            await load(road: road)
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "投稿できませんでした")
            return false
        }
    }

    func delete(_ review: Review, road: String) async {
        guard let client = Backend.client else { return }
        do {
            try await client.from("reviews").delete().eq("id", value: review.id).execute()
            await load(road: road)
        } catch {
            self.error = Self.message(for: error, fallback: "削除できませんでした")
        }
    }

    // MARK: 通報・ブロック

    struct Report: Encodable { let review_id: Int; let reason: String }
    struct Block: Encodable { let blocked: String }

    func report(_ review: Review, reason: String) async -> Bool {
        guard let client = Backend.client else { return false }
        do {
            try await client.from("review_reports").insert(Report(review_id: review.id, reason: reason)).execute()
            return true
        } catch {
            // 同じ口コミを2回通報したときも「受け付けた」扱いにする
            if String(describing: error).contains("duplicate") { return true }
            self.error = Self.message(for: error, fallback: "通報できませんでした")
            return false
        }
    }

    func block(authorOf review: Review, road: String) async {
        guard let client = Backend.client else { return }
        do {
            try await client.from("user_blocks").insert(Block(blocked: review.author_id)).execute()
            await load(road: road)
        } catch {
            if !String(describing: error).contains("duplicate") {
                self.error = Self.message(for: error, fallback: "ブロックできませんでした")
            }
        }
    }

    // MARK: サインイン（Apple）

    /// SignInWithAppleButton の要求を整える
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = []   // 名前・メールは受け取らない
        request.nonce = Self.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        guard let client = Backend.client else { return }
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code != .canceled {
                error = "サインインできませんでした（\(e.localizedDescription)）"
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                error = "サインインできませんでした（Apple からの情報が不足）"
                return
            }
            do {
                try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: token, nonce: nonce))
                isSignedIn = true
                error = nil
            } catch {
                self.error = "サインインできませんでした（\(String(describing: error).prefix(120))）"
            }
        }
    }

    func signOut() async {
        try? await Backend.client?.auth.signOut()
        isSignedIn = false
        reviews = [:]
    }

    /// アカウントを削除する（口コミ・通報・ブロックも消える）
    func deleteAccount() async -> Bool {
        guard let client = Backend.client else { return false }
        do {
            try await client.rpc("delete_my_account").execute()
            try? await client.auth.signOut()
            isSignedIn = false
            reviews = [:]
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "アカウントを削除できませんでした")
            return false
        }
    }

    // MARK: 補助

    private static func message(for error: Error, fallback: String) -> String {
        let text = String(describing: error)
        if text.contains("1日10件") { return "投稿は1日10件までです" }
        if text.contains("row-level security") { return "\(fallback)（この操作は許可されていません）" }
        return "\(fallback)（\(text.prefix(100))）"
    }

    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &generator)! })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
