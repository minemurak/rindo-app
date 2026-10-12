-- 御前山線（tokyo-gozenyama）の区間データ。tools/road.py build data/roads/tokyo-gozenyama.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 秋川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('御前山線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '御前山線');

-- 檜原村：通行止め、起点に柵有、道路崩壊のため（約0.6km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '檜原村：通行止め、起点に柵有、道路崩壊のため',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.0806882,35.7512962],[139.0809465,35.7509332],[139.0810284,35.7508514],[139.0811134,35.7507849],[139.0812268,35.7507721],[139.0814379,35.7507619],[139.0815418,35.7507619],[139.0816678,35.7507338],[139.0817774,35.7507015],[139.0818789,35.7506136],[139.081964,35.7505037],[139.0820522,35.7504091],[139.0821908,35.7503298],[139.0822884,35.750271],[139.0823262,35.750225],[139.0823703,35.7501253],[139.0825058,35.7499438],[139.0826601,35.7498876],[139.0827862,35.7498927],[139.0831323,35.7499821],[139.0833093,35.7500365],[139.0835614,35.7501671],[139.0836376,35.7501808],[139.0836938,35.7501688],[139.0837223,35.7501388],[139.0837223,35.7500888],[139.0836558,35.7500202],[139.0835051,35.7499146],[139.083371,35.749858],[139.0832454,35.7498373],[139.0831484,35.7497905],[139.0827514,35.7495707],[139.0825829,35.7495086],[139.0824757,35.7494847],[139.0823496,35.7495043],[139.0822906,35.7495239],[139.0822343,35.7495696],[139.0821881,35.7496077],[139.0821404,35.7496632],[139.0820862,35.7497165],[139.0819929,35.7497873],[139.0816544,35.750006]]}'), 4326)
from roads r, administrators a
where r.name = '御前山線' and a.name = '東京都森林事務所 秋川林務出張所';

-- 規制：檜原村：通行止め、起点に柵有、道路崩壊のため
insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)
select s.id, '全面通行止め', '道路崩壊のため', null, null,
  'https://forestry-office.metro.tokyo.lg.jp/about/rin/rin_kisei/index.html', '2026-10-12 11:40+09'
from segments s join roads r on r.id = s.road_id
where r.name = '御前山線' and s.note = '檜原村：通行止め、起点に柵有、道路崩壊のため';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '御前山線' group by s.id, s.note order by s.id;
