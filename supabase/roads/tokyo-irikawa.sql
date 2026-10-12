-- 入川線（tokyo-irikawa）の区間データ。tools/road.py build data/roads/tokyo-irikawa.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 多摩川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('入川線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '入川線');

-- 奥多摩町：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可（約0.6km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '奥多摩町：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.1294373,35.8265669],[139.1297321,35.8264907],[139.1299937,35.8263972],[139.1302087,35.8263126],[139.1303937,35.8262136],[139.1307534,35.8260706],[139.130847,35.8259906],[139.130898,35.8259496],[139.131027,35.8259142],[139.131127,35.8257582],[139.131269,35.8255882],[139.131369,35.8255192],[139.131514,35.8254862],[139.131732,35.8254686],[139.1318083,35.8255196],[139.1319031,35.8256256],[139.1321179,35.8256571],[139.132234,35.8257036],[139.132311,35.8258106],[139.132323,35.8259796],[139.132306,35.8261876],[139.132301,35.8263946],[139.132323,35.8265266],[139.132346,35.8265926],[139.132379,35.8266586],[139.132402,35.8267036],[139.132416,35.8267336],[139.132441,35.8267786],[139.132466,35.8268116],[139.132491,35.8268396],[139.132524,35.8268646],[139.132586,35.8269036],[139.132704,35.8269526],[139.1329493,35.8269272],[139.1330623,35.8269422],[139.1332343,35.8269712],[139.1337749,35.8270074]]}'), 4326)
from roads r, administrators a
where r.name = '入川線' and a.name = '東京都森林事務所 多摩川林務出張所';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '入川線' group by s.id, s.note order by s.id;
