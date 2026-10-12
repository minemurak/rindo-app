-- 広町線（tokyo-hiromachi）の区間データ。tools/road.py build data/roads/tokyo-hiromachi.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 浅川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('広町線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '広町線');

-- 八王子市：特になし（約0.5km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '可', '八王子市：特になし',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.2773958,35.7070981],[139.277409,35.7071633],[139.2774511,35.7072207],[139.2775077,35.7072441],[139.2775961,35.7072668],[139.2776976,35.7073251],[139.2778611,35.7074742],[139.277993,35.7075894],[139.2781031,35.7077298],[139.2782767,35.7079948],[139.2783254,35.7080662],[139.2784095,35.7082079],[139.2784274,35.7083067],[139.2784454,35.708444],[139.2785315,35.7086218],[139.2785905,35.7087614],[139.2787135,35.7089812],[139.2787699,35.7090884],[139.2788727,35.7092124],[139.279017,35.7093164],[139.2791652,35.7093986],[139.279299,35.709497],[139.2794949,35.7096942],[139.2796056,35.7098543],[139.2796932,35.71001],[139.2798517,35.7102002],[139.2801096,35.7104691],[139.2802634,35.710561],[139.2804021,35.7106302]]}'), 4326)
from roads r, administrators a
where r.name = '広町線' and a.name = '東京都森林事務所 浅川林務出張所';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '広町線' group by s.id, s.note order by s.id;
