# data

林道データは `tools/road.py` で作る。手順は README の「林道データの追加」を参照。

| フォルダ | 内容 |
| --- | --- |
| `osm/` | Overpass Turbo から書き出した OSM の線（元データ） |
| `roads/` | 林道ごとの設定（OSM の名前、区間の境目、一般通行区分、規制、出典） |
| `segments/` | ツールが作った区間データ（GeoJSON）。手で編集しない |

対応する SQL は `supabase/roads/<slug>.sql`（同じくツールが作る）。

## 出典とライセンス

- 林道の線：© OpenStreetMap contributors（ODbL）。アプリ内に出典表示が必要
- 区間の境目：国土地理院の地名データ、各管理者の位置図など（設定ファイルの `splits[].source` に記録）
- 一般通行区分と規制：各管理者の公式情報（設定ファイルの `restrictions[].source_url` に記録）。OSM のタグでは決めない

## 登録済みの林道

| slug | 林道 | 区間 | 境目の出典 |
| --- | --- | --- | --- |
| `joubu-chichibu` | 上武秩父線 | 3（約19.2km、うち3.9kmが大型車通行止め） | 風早峠：国土地理院 地名データ／更木線分岐：県の位置図からの推定（誤差約150m） |
