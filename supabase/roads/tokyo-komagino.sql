-- 駒木野線（tokyo-komagino）の区間データ。tools/road.py build data/roads/tokyo-komagino.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 浅川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('駒木野線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '駒木野線');

-- 八王子市：通行止め、起点に柵有、森林伐採作業中のため（約1.2km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '八王子市：通行止め、起点に柵有、森林伐採作業中のため',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.2214591,35.6649583],[139.2215986,35.6650455],[139.2217753,35.6651155],[139.2219634,35.665137],[139.2221154,35.665142],[139.2222737,35.6651301],[139.2224405,35.6651645],[139.2225685,35.6652636],[139.2226253,35.6653737],[139.222668,35.6654996],[139.2227629,35.6655899],[139.2228935,35.6656493],[139.2230314,35.6657195],[139.2231784,35.6657866],[139.2234056,35.6658882],[139.2235681,35.665998],[139.22374,35.6660651],[139.2238846,35.6661035],[139.224174,35.6661213],[139.2245128,35.6661224],[139.2248837,35.6661298],[139.2251619,35.6661765],[139.2256055,35.6662691],[139.2257697,35.6662754],[139.22597,35.6662721],[139.2263654,35.666273],[139.2268849,35.6663793],[139.2271719,35.6664053],[139.2276462,35.6664994],[139.2280476,35.6666531],[139.2286453,35.6667934],[139.2289476,35.6669145],[139.2291026,35.6669412],[139.2293375,35.66692],[139.2303418,35.6668171],[139.2306196,35.666794],[139.2308197,35.6667555],[139.2309482,35.6667077],[139.2311392,35.6666467],[139.2313256,35.666597],[139.2314404,35.6665951],[139.2315568,35.6666103],[139.2316636,35.6666452],[139.231819,35.6667233],[139.2319426,35.6668046],[139.2320725,35.6669497],[139.232296,35.6670584],[139.232483,35.6671089],[139.2327398,35.6671926],[139.2328295,35.6672723],[139.2329191,35.6673823],[139.233227,35.6676292]]}'), 4326)
from roads r, administrators a
where r.name = '駒木野線' and a.name = '東京都森林事務所 浅川林務出張所';

-- 規制：八王子市：通行止め、起点に柵有、森林伐採作業中のため
insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)
select s.id, '全面通行止め', '森林伐採作業中のため', null, null,
  'https://forestry-office.metro.tokyo.lg.jp/about/rin/rin_kisei/index.html', '2026-10-12 11:40+09'
from segments s join roads r on r.id = s.road_id
where r.name = '駒木野線' and s.note = '八王子市：通行止め、起点に柵有、森林伐採作業中のため';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '駒木野線' group by s.id, s.note order by s.id;
