# 林道アプリ（試作）

全国の林道情報アプリの試作リポジトリ。Macを使わず、GitHub Actions の macOS 環境で
ビルドし、TestFlight 経由で iPhone にインストールする。

## ファイル構成

| パス | 内容 |
| --- | --- |
| `project.yml` | XcodeGen の設定。Xcodeプロジェクトはここから自動生成する |
| `Sources/` | アプリ本体（SwiftUI）とアイコン |
| `.github/workflows/testflight.yml` | main への push でビルドして TestFlight へ送る |
| `.github/workflows/build-check.yml` | main 以外への push で署名なしビルドだけ行う |
| `fastlane/Fastfile` | 署名・ビルド・送信の手順 |
| `fastlane/Matchfile` | 証明書の保管先 |

`Sources/Secrets.swift` と `Sources/Info.plist`、`RindoApp.xcodeproj` はビルド時に作られるため、リポジトリには入れない。

## 設定済みの値

| 項目 | 値 |
| --- | --- |
| Bundle ID | `com.minemurak.rindomap` |
| 証明書保管用リポジトリ | `minemurak/rindo-certificates`（非公開） |

Bundle ID を変える場合は `project.yml`、`fastlane/Fastfile`、`fastlane/Matchfile` の3ファイルを直す。

## 初回の準備

### Apple 側（ブラウザ）

1. App Store Connect の「ユーザとアクセス」で API キー（App Manager 権限）を発行し、.p8 をダウンロードして、キー ID と発行者 ID を控える
2. Certificates, Identifiers & Profiles で Bundle ID を登録する
3. App Store Connect でアプリを新規作成し、2 の Bundle ID を選ぶ
4. TestFlight で自分を内部テスターに登録し、iPhone に TestFlight アプリを入れる

### GitHub 側

1. このリポジトリ（公開）と、証明書保管用の `rindo-certificates`（**非公開**）を作る
2. このリポジトリの Settings → Secrets and variables → Actions で、次の Secrets を登録する

| Secret | 値 |
| --- | --- |
| `ASC_KEY_ID` | API キーのキー ID |
| `ASC_ISSUER_ID` | API キーの発行者 ID |
| `ASC_KEY_CONTENT` | .p8 をメモ帳で開き、`-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` までを丸ごと貼り付けたもの（Base64 にしたものでも可） |
| `TEAM_ID` | Apple Developer のチーム ID |
| `MATCH_PASSWORD` | 証明書を暗号化する任意のパスワード |
| `MATCH_GIT_BASIC_AUTHORIZATION` | 「ユーザー名:個人アクセストークン」を Base64 にしたもの |
| `SUPABASE_URL` | Supabase のプロジェクト URL（手順2まで未設定でよい） |
| `SUPABASE_ANON_KEY` | Supabase の anon キー（手順2まで未設定でよい） |

Base64 は Windows の PowerShell で作れる。

```powershell
# ファイル（.p8）
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8"))
# 文字列（ユーザー名:トークン）
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("ユーザー名:トークン"))
```

個人アクセストークンには、`rindo-certificates` の読み書き権限だけを付ける。

3. Actions タブで「TestFlight」→「Run workflow」を開き、「証明書とプロファイルを新しく作る」に**チェックを入れて**実行する。証明書とプロファイルが作られ、ビルドが TestFlight に送られる
4. 2回目以降はチェックなしで実行する（main への push でも自動で動く）
5. App Store Connect 側の処理が終わると、iPhone の TestFlight アプリに表示される。インストールして「林道アプリ 試作」とビルド番号が出れば手順0は完了

## 普段の流れ

- 作業ブランチに push → 「Build check」で文法エラーを確認
- main に入れる → 「TestFlight」で配信 → iPhone で確認

## 注意

- 鍵・証明書・プロファイルは絶対にコミットしない（`.gitignore` 済み）
- anon キーを知っていれば誰でも API を呼べるため、Supabase の書き込みは行レベルセキュリティで必ず止める
- ライセンスは付けない方針（コードは公開されるが、他人は利用できない）
- 地図の出典表示（© OpenStreetMap contributors、国土地理院）は手順3で地図画面に入れる

## 林道データの追加

`tools/road.py`（Python 3.9 以上、追加ライブラリ不要）で、林道1本を区間に分けた SQL を作る。

1. OSM の線を取る。どちらかの方法で `data/osm/<slug>.geojson` を作る
    - **おすすめ**：Actions タブ →「Fetch OSM」→「Run workflow」で、保存名（slug）・林道名（例：`城[峰峯]`）・範囲（`南,西,北,東`）を入れて実行。混雑していないサーバーを自動で探して取得し、リポジトリにコミットする
    - 手動：`python3 tools/road.py link 城峰 --bbox 南,西,北,東` で出るリンクを開き、Export → GeoJSON → download で保存
2. 区間の境目にする地名は `python3 tools/road.py place 風早峠` で国土地理院の地名検索を開き、座標を調べる
3. `data/roads/<slug>.json` を書く（`data/roads/joubu-chichibu.json` が見本）。一般通行区分と規制は管理者の公式情報で決める
4. `python3 tools/road.py build data/roads/<slug>.json` で `data/segments/<slug>.geojson` と `supabase/roads/<slug>.sql` ができる
5. `python3 tools/road.py bundle` で全林道を `supabase/all-roads.sql` にまとめ、Supabase の SQL Editor で実行する（何度実行しても同じ状態になる）

同じ名前の線に枝道や離れた部分があれば、いちばん長くつながった本線だけを使い、除いた長さを表示する。境目の点が線から100m以上離れているときも警告する。

## 通行止め情報の更新確認（毎日自動）

GitHub Actions の「Watch closures」が毎朝 5:47（日本時間）に、`data/watch/sources.json` に並べた自治体のページ（PDF を含む）を確認する。

- 前回から本文が変わっていたら、差分を書いた Issue「通行止め情報の更新 YYYY-MM-DD」を立てる。Issue の通知メールで気づける
- 3日続けてページを取得できなかったときも Issue を立てる（ページの場所が変わった可能性）
- Issue を見て、必要なら `data/roads/` の設定を直し、`python3 tools/road.py build`・`bundle` を実行し、Supabase で `supabase/all-roads.sql` を実行する。終わったら Issue を閉じる
- 見に行くページを増やすときは `sources.json` に足す。`start`・`end`（正規表現）で本文の範囲を決めると、メニューなどの変化で知らせなくなる
- リポジトリに60日間更新がないと、GitHub が毎日の実行を止める。止まったら Actions タブで「Enable workflow」を押す
