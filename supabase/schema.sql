-- 林道アプリ 試作用スキーマ（手順2）
-- Supabase の SQL Editor に全文を貼り付けて「Run」で実行する。
-- 何度実行しても同じ状態になるように書いてある。

-- 1. PostGIS を有効にする（Supabase では extensions スキーマに入る）
create extension if not exists postgis with schema extensions;

set search_path = public, extensions;

-- 2. テーブル
create table if not exists administrators (
  id bigint generated always as identity primary key,
  name text not null unique,
  kind text not null                       -- 県 / 市町村 / 国有林 など
);

create table if not exists roads (
  id bigint generated always as identity primary key,
  name text not null unique,
  kind text not null default '林道'          -- 林道 / 作業道 / 市町村道 など
);

create table if not exists segments (
  id bigint generated always as identity primary key,
  road_id bigint not null references roads(id),
  administrator_id bigint references administrators(id),
  surface text,                            -- 舗装 / 未舗装
  difficulty smallint check (difficulty between 1 and 3),
  general_access text not null default '不明'
    check (general_access in ('可', '不可', '不明')),
  note text,                               -- 区間の説明（例：更木線分岐〜風早峠）
  geom extensions.geometry(LineString, 4326) not null
);
create index if not exists segments_geom_idx on segments using gist (geom);

create table if not exists restrictions (
  id bigint generated always as identity primary key,
  segment_id bigint not null references segments(id) on delete cascade,
  kind text not null,                      -- 全面通行止め / 大型車両通行止め など
  reason text,
  starts_on date,
  ends_on date,                            -- 当面の間は null
  source_url text,
  fetched_at timestamptz
);

-- 3. 範囲検索の関数：表示範囲の区間を GeoJSON で返す
create or replace function segments_in_bbox(
  min_lon float8, min_lat float8, max_lon float8, max_lat float8)
returns json
language sql stable
set search_path = public, extensions
as $$
  select json_build_object(
    'type', 'FeatureCollection',
    'features', coalesce(json_agg(json_build_object(
      'type', 'Feature',
      'geometry', ST_AsGeoJSON(s.geom)::json,
      'properties', json_build_object(
        'id', s.id,
        'road', r.name,
        'administrator', a.name,
        'access', s.general_access,
        'surface', s.surface,
        'difficulty', s.difficulty,
        'note', s.note,
        'restrictions', (
          select coalesce(json_agg(json_build_object(
                   'kind', x.kind, 'reason', x.reason,
                   'source_url', x.source_url, 'fetched_at', x.fetched_at)), '[]'::json)
          from restrictions x
          where x.segment_id = s.id
            and (x.ends_on is null or x.ends_on >= current_date))
      )
    )), '[]'::json))
  from segments s
  join roads r on r.id = s.road_id
  left join administrators a on a.id = s.administrator_id
  where s.geom && ST_MakeEnvelope(min_lon, min_lat, max_lon, max_lat, 4326);
$$;

-- 4. 行レベルセキュリティ：誰でも読めるが、アプリからは書き込めない
alter table administrators enable row level security;
alter table roads          enable row level security;
alter table segments       enable row level security;
alter table restrictions   enable row level security;

drop policy if exists "anyone can read" on administrators;
drop policy if exists "anyone can read" on roads;
drop policy if exists "anyone can read" on segments;
drop policy if exists "anyone can read" on restrictions;
create policy "anyone can read" on administrators for select using (true);
create policy "anyone can read" on roads          for select using (true);
create policy "anyone can read" on segments       for select using (true);
create policy "anyone can read" on restrictions   for select using (true);

grant execute on function segments_in_bbox(float8, float8, float8, float8) to anon, authenticated;

-- 5. 初期データ（管理者2件と林道1件）
insert into administrators (name, kind) values
  ('秩父農林振興センター', '県'),
  ('寄居林業事務所', '県')
on conflict (name) do nothing;

insert into roads (name, kind) values
  ('上武秩父線', '林道')
on conflict (name) do nothing;

-- 区間データ（segments）と規制（restrictions）は、林道の線データができてから
-- supabase/segments.sql で入れる。

-- 6. 確認：区間を入れる前なので features が空の結果が返れば成功
select segments_in_bbox(138.8, 35.9, 139.3, 36.3);
