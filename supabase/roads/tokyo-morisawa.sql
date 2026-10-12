-- 森沢線（tokyo-morisawa）の区間データ。tools/road.py build data/roads/tokyo-morisawa.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 秋川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('森沢線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '森沢線');

-- 檜原村：通行止め、起点に柵有（約1.1km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '檜原村：通行止め、起点に柵有',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.0642488,35.7083251],[139.0647761,35.7083682],[139.0648752,35.708305],[139.0651194,35.7082417],[139.0653778,35.7083107],[139.0658272,35.7086929],[139.0658662,35.7087763],[139.066075,35.7094574],[139.0666589,35.710331],[139.0668925,35.710558],[139.0671584,35.710823],[139.0672985,35.7108913],[139.0674036,35.7109482],[139.0675904,35.7111833],[139.0676487,35.711206],[139.0681484,35.7113311],[139.068564,35.7115624],[139.0689213,35.711898],[139.0690404,35.711989],[139.0693206,35.7121331],[139.0695471,35.7123436],[139.069902,35.712463],[139.0701939,35.7126602],[139.0702803,35.7127076],[139.0711115,35.7129161],[139.0712166,35.7129825],[139.071366,35.7131057],[139.0715342,35.7131835],[139.0717396,35.7132062],[139.0718657,35.7131816],[139.0720082,35.7130735],[139.0720619,35.7130318],[139.0723724,35.7130071],[139.0724238,35.7129901],[139.0725009,35.7129256],[139.0725709,35.7129351],[139.0731067,35.7131753]]}'), 4326)
from roads r, administrators a
where r.name = '森沢線' and a.name = '東京都森林事務所 秋川林務出張所';

-- 規制：檜原村：通行止め、起点に柵有
insert into restrictions (segment_id, kind, reason, starts_on, ends_on, source_url, fetched_at)
select s.id, '全面通行止め', null, null, null,
  'https://forestry-office.metro.tokyo.lg.jp/about/rin/rin_kisei/index.html', '2026-10-12 11:40+09'
from segments s join roads r on r.id = s.road_id
where r.name = '森沢線' and s.note = '檜原村：通行止め、起点に柵有';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '森沢線' group by s.id, s.note order by s.id;
