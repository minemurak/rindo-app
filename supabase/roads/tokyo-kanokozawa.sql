-- 鹿の子沢線（tokyo-kanokozawa）の区間データ。tools/road.py build data/roads/tokyo-kanokozawa.json で生成。手で編集しない。
-- schema.sql を実行したあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる。
-- 出典：線：© OpenStreetMap contributors（ODbL）
-- 出典：通行可否と規制：東京都森林事務所「森林事務所管理林道の通行規制について」通行状況一覧（令和8年10月2日現在）。「通行規制」は林業関係者以外の車両の乗り入れを規制。data/sources/tokyo-forestry-2026-10-02.tsv

set search_path = public, extensions;

insert into administrators (name, kind) values ('東京都森林事務所 浅川林務出張所', '都')
on conflict (name) do nothing;
insert into roads (name, kind) values ('鹿の子沢線', '林道')
on conflict (name) do nothing;

delete from segments where road_id = (select id from roads where name = '鹿の子沢線');

-- 八王子市：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可（約0.7km）
insert into segments (road_id, administrator_id, surface, difficulty, general_access, note, geom)
select r.id, a.id, null, null, '不可', '八王子市：通行規制、起点に柵有。林業関係者以外の車両は乗り入れ不可',
  ST_SetSRID(ST_GeomFromGeoJSON('{"type":"LineString","coordinates":[[139.2336655,35.689524],[139.2337639,35.689515],[139.2339138,35.6895276],[139.2340976,35.6895606],[139.2343029,35.6896207],[139.2345153,35.6896985],[139.2346903,35.6897643],[139.2348753,35.6898237],[139.2350806,35.6898692],[139.2352742,35.6898613],[139.2359567,35.6898657],[139.2361822,35.6898949],[139.236393,35.6899222],[139.236555,35.6899707],[139.236755,35.6900615],[139.2368979,35.6901296],[139.2371175,35.6902155],[139.2372627,35.6902777],[139.2374919,35.6902831],[139.2377869,35.6902461],[139.2381359,35.6901609],[139.238502,35.6901618],[139.2388207,35.6901784],[139.2392817,35.6902403],[139.2393731,35.6902396],[139.2394613,35.6902424],[139.2395812,35.6902107],[139.2397667,35.6901374],[139.2398746,35.6901023],[139.2401289,35.6900239],[139.2403239,35.6899486],[139.2405237,35.689888],[139.2407523,35.6898242],[139.2409613,35.6897964],[139.241184,35.6898043],[139.2413254,35.689797]]}'), 4326)
from roads r, administrators a
where r.name = '鹿の子沢線' and a.name = '東京都森林事務所 浅川林務出張所';

-- 確認：この林道の区間と規制の数
select s.note as 区間, count(x.id) as 規制数
from segments s join roads r on r.id = s.road_id left join restrictions x on x.segment_id = s.id
where r.name = '鹿の子沢線' group by s.id, s.note order by s.id;
