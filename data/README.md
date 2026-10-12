# data

林道データは `tools/road.py` で作る。手順は README の「林道データの追加」を参照。

| フォルダ | 内容 |
| --- | --- |
| `osm/` | Overpass Turbo から書き出した OSM の線（元データ） |
| `gsi/` | 国土地理院の道路中心線（OSM で線がない部分を補う元データ。Actions の「Fetch GSI roads」で取得） |
| `roads/` | 林道ごとの設定（OSM の名前、区間の境目、一般通行区分、規制、出典） |
| `segments/` | ツールが作った区間データ（GeoJSON）。手で編集しない |

対応する SQL は `supabase/roads/<slug>.sql`（同じくツールが作る）。

## 出典とライセンス

- 林道の線：© OpenStreetMap contributors（ODbL）。アプリ内に出典表示が必要
- OSM で線がない部分：国土地理院 道路中心線。アプリ内に「国土地理院」の出典表示が必要
- 区間の境目：国土地理院の地名データ、各管理者の位置図など（設定ファイルの `splits[].source` に記録）
- 一般通行区分と規制：各管理者の公式情報（設定ファイルの `restrictions[].source_url` に記録）。OSM のタグでは決めない

## 設定ファイルの追加項目

- `join_tolerance_m`：線の端どうしをつなぐ距離（既定 30m）。トンネルや OSM の描き方で線が離れているときに広げる
- `gap_fills`：OSM の線の途切れを、国土地理院の道路中心線（徒歩道を除く）の最短経路で補う。`[{"note", "file": "data/gsi/<slug>.geojson", "from": [経度, 緯度], "to": [経度, 緯度]}]`
- `segments[].administrator`：区間ごとの管理者（`{"name": ..., "kind": ...}`）。県境をまたぐ道で使う。省略時は全体の `administrator`

## 登録済みの林道

| slug | 林道 | 区間 | 境目の出典 |
| --- | --- | --- | --- |
| `joubu-chichibu` | 上武秩父線 | 3（約19.2km、うち3.9kmが大型車通行止め） | 風早峠：国土地理院 地名データ／更木線分岐：県の位置図からの推定（誤差約150m） |
| `jomine-1` | 城峰1号線（OSM 名：林道城峯1号線） | 1（約5.7km、規制なし） | 境目なし。北端で上武秩父線と接続 |
| `minoyama` | 蓑山線 | 1（約6.1km） | 秩父農林振興センター |
| `futagoyama` | 二子山線 | 1（約13.1km）。東側（西秩父線）へは通り抜け不可 | 秩父農林振興センター。OSM の同名の離れた線は除外 |
| `hirasaka-tobimura` | 平坂飛村線 | 1（約9.8km） | 川越農林振興センター |
| `tochiyadani` | 栃屋谷線 | 1（約3.6km） | 川越農林振興センター |
| `karibazaka` | 苅場坂線 | 1（約5.4km） | 川越農林振興センター |
| `gongendo` | 権現堂線 | 1（約10.0km） | 川越農林振興センター |
| `mikabo-super` | 御荷鉾スーパー林道（群馬） | 1（約65.0km、冬季閉鎖 12/10〜4/20） | 管理者は沿線市町村としてまとめて登録。OSM の線がない2か所（約1.0km・約2.2km）は国土地理院の道路中心線で補う（`gap_fills`）。線は `osm/mikabo-all.geojson`（群馬西部と東側の取得結果から御荷鉾スーパー林道だけを抜き出したもの） |
| `yakyuzawa` | 矢弓沢線（群馬・上野村） | 1（約7.1km、規制なし） | 上野村 |
| `ushiroyama` | 後山線（群馬・上野村） | 1（約2.0km、全面通行止め） | 上野村 |
| `kamakake` | カマカケ線（群馬・上野村） | 1（約2.6km、全面通行止め） | 上野村 |
| `ueno-otaki` | 上野大滝線（群馬・埼玉） | 2（群馬側 約9.8km／埼玉側 約7.7km、どちらも全面通行止め） | 天丸トンネル（県境）で区切り、区間ごとに管理者を分ける（`segments[].administrator`）。トンネル部分の途切れは `join_tolerance_m: 150` でつなぐ |

全林道をまとめた SQL は `supabase/all-roads.sql`（`python3 tools/road.py bundle` で作る）。
