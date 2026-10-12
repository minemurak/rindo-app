import SwiftUI
import AuthenticationServices

/// 林道の口コミ一覧（シート）。投稿・通報・ブロック・自分の口コミの削除・アカウント管理ができる。
struct ReviewsView: View {
    let road: String
    @ObservedObject var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var composing = false
    @State private var reporting: ReviewStore.Review?
    @State private var notice: String?
    @State private var confirmDeleteAccount = false

    private var list: [ReviewStore.Review] { store.reviews[road] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                if list.isEmpty && !store.loading.contains(road) {
                    ContentUnavailableView("まだ口コミはありません", systemImage: "text.bubble",
                                           description: Text("走ったときの路面の様子を教えてください"))
                }
                ForEach(list) { review in
                    ReviewRow(review: review)
                        .contextMenu { actions(for: review) }
                        .swipeActions { if review.is_mine == true { deleteButton(review) } }
                        .overlay(alignment: .topTrailing) {
                            Menu { actions(for: review) } label: {
                                Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                            }
                            .accessibilityLabel("この口コミの操作")
                        }
                }
                Section {
                    Text("口コミは利用者の投稿です。通行の可否は、必ず現地の標識と管理者の最新情報で確認してください。走行が禁止されている道を走った内容は削除します。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .overlay { if store.loading.contains(road) && list.isEmpty { ProgressView() } }
            .refreshable { await store.load(road: road) }
            .navigationTitle(road)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Label("口コミを書く", systemImage: "square.and.pencil") }
                }
                if store.isSignedIn {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("サインアウト") { Task { await store.signOut() } }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("アカウントを削除", role: .destructive) { confirmDeleteAccount = true }
                    }
                }
            }
            .sheet(isPresented: $composing) { ComposeView(road: road, store: store) }
            .confirmationDialog("この口コミを通報する理由", isPresented: Binding(
                get: { reporting != nil }, set: { if !$0 { reporting = nil } }), titleVisibility: .visible) {
                ForEach(ReviewStore.reportReasons, id: \.self) { reason in
                    Button(reason) {
                        guard let r = reporting else { return }
                        Task {
                            if await store.report(r, reason: reason) {
                                notice = "通報を受け付けました。確認して対応します"
                            }
                        }
                    }
                }
            }
            .confirmationDialog("アカウントを削除しますか？", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
                Button("削除する", role: .destructive) {
                    Task { if await store.deleteAccount() { notice = "アカウントと投稿を削除しました" } }
                }
            } message: {
                Text("書いた口コミ・通報・ブロックもすべて削除され、元に戻せません")
            }
        }
        .task { await store.load(road: road) }
    }

    @ViewBuilder private func actions(for review: ReviewStore.Review) -> some View {
        if review.is_mine == true {
            deleteButton(review)
        } else if store.isSignedIn {
            Button { reporting = review } label: { Label("通報する", systemImage: "flag") }
            Button(role: .destructive) {
                Task {
                    await store.block(authorOf: review, road: road)
                    notice = "\(review.author) の口コミを表示しないようにしました"
                }
            } label: { Label("この投稿者をブロック", systemImage: "hand.raised") }
        } else {
            Button { composing = true } label: { Label("通報・ブロックするにはサインイン", systemImage: "person.crop.circle") }
        }
    }

    private func deleteButton(_ review: ReviewStore.Review) -> some View {
        Button(role: .destructive) { Task { await store.delete(review, road: road) } } label: {
            Label("削除", systemImage: "trash")
        }
    }
}

private struct ReviewRow: View {
    let review: ReviewStore.Review

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ConditionBadge(condition: review.condition)
                Text("\(review.driven_on) 走行").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 28)
            }
            Text(review.body).font(.body)
            HStack {
                Text(review.is_mine == true ? "あなた" : review.author)
                if review.hidden {
                    Text("非表示中（通報により確認待ち）").foregroundStyle(.orange)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ConditionBadge: View {
    let condition: String
    var color: Color {
        switch condition {
        case "良好": return .green
        case "普通": return .blue
        case "荒れ": return .orange
        default: return .red
        }
    }
    var body: some View {
        Text(condition)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 口コミを書く画面。サインインと利用規約への同意がまだなら、先にそれを済ませる。
private struct ComposeView: View {
    let road: String
    @ObservedObject var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agreedTermsVersion") private var agreedVersion = 0
    @State private var drivenOn = Date()
    @State private var condition = "普通"
    @State private var text = ""
    @State private var posting = false

    static let termsVersion = 1
    private let limit = 1000

    var body: some View {
        NavigationStack {
            Form {
                if agreedVersion < Self.termsVersion {
                    Section("利用規約") {
                        ScrollView { Text(Terms.text).font(.footnote) }.frame(height: 220)
                        Button("同意する") { agreedVersion = Self.termsVersion }
                    }
                } else if !store.isSignedIn {
                    Section {
                        Text("口コミを書くには、Apple でサインインしてください。名前とメールアドレスは受け取りません。")
                            .font(.footnote)
                        SignInWithAppleButton(.signIn) { store.prepare($0) } onCompletion: { result in
                            Task { await store.complete(result) }
                        }
                        .frame(height: 44)
                    }
                } else {
                    Section("走った日") {
                        DatePicker("走った日", selection: $drivenOn, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                    }
                    Section("路面の状態") {
                        Picker("路面の状態", selection: $condition) {
                            ForEach(ReviewStore.conditions, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        TextEditor(text: $text).frame(minHeight: 140)
                    } header: {
                        Text("様子")
                    } footer: {
                        Text("\(text.count)／\(limit)字。落石・倒木・ぬかるみ・ゲートの状態などを書いてください。個人を特定できる情報は書かないでください。")
                    }
                }
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("口コミを書く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                if agreedVersion >= Self.termsVersion && store.isSignedIn {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("投稿") {
                            posting = true
                            Task {
                                if await store.post(road: road, drivenOn: drivenOn, condition: condition, body: text) {
                                    dismiss()
                                }
                                posting = false
                            }
                        }
                        .disabled(posting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > limit)
                    }
                }
            }
        }
    }
}

enum Terms {
    static let text = """
    林道アプリ 口コミ利用規約（第1版）

    1. 口コミは、林道の路面や通行の様子を共有するためのものです。投稿はすぐに公開され、誰でも読めます。
    2. 次の投稿を禁止します。違反した投稿は予告なく削除し、投稿者の利用を停止します。
      ・誹謗中傷、差別、わいせつ、暴力的な内容など、他人を不快にさせる内容
      ・個人を特定できる情報、他人の権利を侵害する内容
      ・宣伝、スパム、林道と関係のない内容
      ・一般車両の走行が禁止されている道を走ったことを示す内容や、それをすすめる内容
    3. 不適切な投稿は「通報する」で知らせてください。通報が重なった投稿は自動で非表示にし、運営者が確認します。運営者は通報を確認し、24時間以内を目安に対応します。
    4. 特定の投稿者の口コミは「この投稿者をブロック」で表示しないようにできます。
    5. 口コミの内容は投稿者の体験であり、運営者は正確さを保証しません。通行の可否は、必ず現地の標識と管理者の最新情報で確認してください。
    6. アカウントは「アカウントを削除」でいつでも削除できます。削除すると、書いた口コミも削除されます。
    7. 問い合わせ：GitHub（github.com/minemurak/rindo-app）の Issues
    """
}
