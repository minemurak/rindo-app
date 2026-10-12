-- 陣馬線（tokyo-jinba）の区間データ。tools/road.py build data/roads/tokyo-jinba.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 浅川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('陣馬線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '陣馬線');

-- 八王子市：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可（約0.1km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '八王子市：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.1686384,35.6576391],[139.1687811,35.6575452],[139.168937,35.6574198],[139.168987,35.657318],[139.1690567,35.6571742],[139.1691506,35.6570434],[139.1692767,35.6569061],[139.1692981,35.6568462],[139.169282,35.656795],[139.1692311,35.6567231],[139.1689602,35.6566141]]}'), 4326)
from roads r, administrators a
where r.name = '陣馬線' and a.name = '東京都森林事務所 浅川林務出張所';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '陣馬線' group by s.id, s.note order by s.id;
