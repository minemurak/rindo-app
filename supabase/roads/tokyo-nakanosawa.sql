-- 中の沢線（tokyo-nakanosawa）の区間データ。tools/road.py build data/roads/tokyo-nakanosawa.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 浅川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('中の沢線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '中の沢線');

-- 八王子市：通行止め、起点に柵有、道路崩壊のため（約0.9km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '八王子市：通行止め、起点に柵有、道路崩壊のため',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.2233938,35.6619504],[139.2233938,35.6621221],[139.2233686,35.6622477],[139.2233313,35.6624],[139.2233313,35.6625482],[139.2233313,35.6626789],[139.2233527,35.6628271],[139.2234064,35.6629884],[139.2235008,35.6631553],[139.2235882,35.663307],[139.2237122,35.6634896],[139.2238302,35.6636857],[139.2239839,35.6638736],[139.2241842,35.6640344],[139.2243452,35.6641346],[139.2246397,35.6642925],[139.2248812,35.664325],[139.2250188,35.6643339],[139.2254312,35.664512],[139.225618,35.6645045],[139.2259713,35.6644711],[139.2262406,35.6644341],[139.226541,35.6644609],[139.2267061,35.6644629],[139.2269274,35.6644673],[139.2270723,35.6644934],[139.2272054,35.6645501],[139.2274187,35.6646286],[139.227647,35.6647061],[139.2277945,35.6648105],[139.2280142,35.6648378],[139.2281807,35.6648437],[139.2283673,35.664848],[139.2285505,35.6649233],[139.228602,35.6649963],[139.2286741,35.6652145],[139.2286903,35.6653855],[139.2286901,35.6656384],[139.2287558,35.6658914],[139.2288108,35.6660472],[139.228936,35.6662235],[139.2289825,35.6663342],[139.2289903,35.6664979],[139.2290201,35.6666108],[139.2290741,35.6667792],[139.2291098,35.6668908]]}'), 4326)
from roads r, administrators a
where r.name = '中の沢線' and a.name = '東京都森林事務所 浅川林務出張所';

-- 規制：八王子市：通行止め、起点に柵有、道路崩壊のため
insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)
select s.id, '全面通行止め', '道路崩壊のため', null, null,
  'https://forestry-office.metro.tokyo.lg.jp/about/rin/rin_kisei/index.html', '2026-10-12 11:40+09'
from segments s join roads r on r.id = s.road_id
where r.name = '中の沢線' and s.note = '八王子市：通行止め、起点に柵有、道路崩壊のため';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '中の沢線' group by s.id, s.note order by s.id;
