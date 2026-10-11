# data

| ファイル | 内容 | 出典 |
| --- | --- | --- |
| `joubu-chichibu-line.geojson` | 林道上武秩父線の線（OSM の7本を西→東の1本に結合、約19.2km）。区間分割前の素材 | © OpenStreetMap contributors（ODbL） |

OpenStreetMap のデータは ODbL ライセンス。アプリ内に「© OpenStreetMap contributors」の表示が必要。
一般通行の可否は OSM のタグではなく、管理者（自治体）の公式情報で決める。

| `joubu-chichibu-segments.geojson` | 上武秩父線を風早峠で2区間に分けたもの（西 14.38km／東 4.83km） | 線：© OpenStreetMap contributors／風早峠の位置：国土地理院 地名データ |

区間の境目の「更木線分岐」は位置未確認。確認できたら区間を追加で分け、大型車通行不可の規制を `supabase/segments.sql` に加える。
