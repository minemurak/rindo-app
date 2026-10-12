-- 笛吹線（tokyo-usuki）の区間データ。tools/road.py build data/roads/tokyo-usuki.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 秋川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('笛吹線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '笛吹線');

-- 檜原村：通行止め、起点に柵有（約1.0km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '檜原村：通行止め、起点に柵有',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.0719798,35.7049985],[139.072234,35.7052289],[139.0723002,35.7053327],[139.072313,35.7054291],[139.0722646,35.7055379],[139.0720525,35.7055553],[139.0720682,35.7056249],[139.0723571,35.7057947],[139.072462,35.7061251],[139.0726223,35.7063972],[139.0726327,35.7066358],[139.072745,35.7068527],[139.0725595,35.7073381],[139.0723944,35.7076344],[139.0721845,35.7078262],[139.0717945,35.7079862],[139.0717913,35.7080344],[139.0720694,35.7081393],[139.072129,35.7081635],[139.0721804,35.708186],[139.07221,35.7083072],[139.0722775,35.7083943],[139.0724811,35.7084061],[139.0729812,35.7084951],[139.0731902,35.708664],[139.0732787,35.7088356],[139.0733243,35.7089839],[139.0733732,35.7092506],[139.0732475,35.709512],[139.0732312,35.7097014],[139.0732651,35.7098227],[139.0732919,35.7098512],[139.0734282,35.7098382],[139.0735235,35.7096581],[139.0737042,35.709197],[139.0736929,35.7089454],[139.0736638,35.7086453],[139.0737094,35.7084132],[139.0738172,35.7083438],[139.0738589,35.7083683],[139.0738984,35.7084128],[139.0738931,35.7085088],[139.0738948,35.7086907],[139.0738741,35.708913],[139.0739481,35.7092781],[139.0740733,35.7094944]]}'), 4326)
from roads r, administrators a
where r.name = '笛吹線' and a.name = '東京都森林事務所 秋川林務出張所';

-- 規制：檜原村：通行止め、起点に柵有
insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)
select s.id, '全面通行止め', null, null, null,
  'https://forestry-office.metro.tokyo.lg.jp/about/rin/rin_kisei/index.html', '2026-10-12 11:40+09'
from segments s join roads r on r.id = s.road_id
where r.name = '笛吹線' and s.note = '檜原村：通行止め、起点に柵有';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '笛吹線' group by s.id, s.note order by s.id;
