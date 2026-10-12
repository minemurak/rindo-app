-- 口コミ（手順：schema.sql のあとに、SQL Editor で全文を実行する。何度実行しても同じ状態になる）
--
-- 方針
--   ・読むのはログインなしで誰でも。書くのは「Apple でサインイン」した人だけ
--   ・投稿はすぐ公開。通報が 3 件たまると自動で非表示にし、管理画面で確認する
--   ・ブロックした人の口コミは、ブロックした本人には見えない
--   ・利用停止（banned_users）にした人は投稿・通報できない
--   ・1 人 1 日 10 件まで
--   ・アカウント削除（delete_my_account）で、その人の口コミ・通報・ブロックとアカウントを消す

set search_path = public, extensions;

-- 1. 表
create table if not exists admins (
  user_id uuid primary key references auth.users on delete cascade
);

create table if not exists banned_users (
  user_id uuid primary key references auth.users on delete cascade,
  reason text,
  created_at timestamptz not null default now()
);

create table if not exists reviews (
  id bigint generated always as identity primary key,
  road_id bigint not null references roads on delete cascade,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  driven_on date not null,
  condition text not null check (condition in ('良好', '普通', '荒れ', '通行できず')),
  body text not null check (char_length(body) between 1 and 1000),
  hidden boolean not null default false,       -- 通報がたまった・管理者が隠した
  report_count int not null default 0,
  created_at timestamptz not null default now(),
  check (driven_on <= (now() at time zone 'Asia/Tokyo')::date + 1)
);
create index if not exists reviews_road_idx on reviews (road_id, created_at desc);
create index if not exists reviews_user_idx on reviews (user_id, created_at desc);

create table if not exists review_reports (
  review_id bigint not null references reviews on delete cascade,
  reporter uuid not null default auth.uid() references auth.users on delete cascade,
  reason text not null check (reason in ('不適切な内容', '走行禁止区間の走行', 'スパム・宣伝', 'その他')),
  created_at timestamptz not null default now(),
  primary key (review_id, reporter)
);

create table if not exists user_blocks (
  blocker uuid not null default auth.uid() references auth.users on delete cascade,
  blocked uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

-- 2. 判定用の関数
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;

create or replace function is_banned() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from banned_users where user_id = auth.uid())
$$;

create or replace function blocked_by_me(author uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from user_blocks where blocker = auth.uid() and blocked = author)
$$;

-- 3. 投稿数の上限（1 人 1 日 10 件）
create or replace function reviews_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from reviews
      where user_id = new.user_id and created_at > now() - interval '1 day') >= 10 then
    raise exception '投稿は1日10件までです';
  end if;
  return new;
end $$;
drop trigger if exists reviews_rate_limit on reviews;
create trigger reviews_rate_limit before insert on reviews
  for each row execute function reviews_rate_limit();

-- 4. 通報が入ったら数を数え、3 件で非表示にする
create or replace function review_reported() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update reviews
     set report_count = report_count + 1,
         hidden = hidden or report_count + 1 >= 3
   where id = new.review_id;
  return new;
end $$;
drop trigger if exists review_reported on review_reports;
create trigger review_reported after insert on review_reports
  for each row execute function review_reported();

-- 5. 読み書きのルール（RLS）
alter table reviews enable row level security;
alter table review_reports enable row level security;
alter table user_blocks enable row level security;
alter table admins enable row level security;
alter table banned_users enable row level security;

drop policy if exists "口コミは誰でも読める" on reviews;
create policy "口コミは誰でも読める" on reviews for select
  using (
    (not hidden or user_id = auth.uid() or is_admin())
    and not blocked_by_me(reviews.user_id)
  );

drop policy if exists "サインインした人が自分の名前で書ける" on reviews;
create policy "サインインした人が自分の名前で書ける" on reviews for insert to authenticated
  with check (user_id = auth.uid() and not hidden and report_count = 0 and not is_banned());

drop policy if exists "自分の口コミは消せる" on reviews;
create policy "自分の口コミは消せる" on reviews for delete to authenticated
  using (user_id = auth.uid() or is_admin());

drop policy if exists "管理者は表示・非表示を切り替えられる" on reviews;
create policy "管理者は表示・非表示を切り替えられる" on reviews for update to authenticated
  using (is_admin()) with check (is_admin());

drop policy if exists "通報できる" on review_reports;
create policy "通報できる" on review_reports for insert to authenticated
  with check (reporter = auth.uid() and not is_banned());

drop policy if exists "通報は自分のものと管理者だけ見える" on review_reports;
create policy "通報は自分のものと管理者だけ見える" on review_reports for select to authenticated
  using (reporter = auth.uid() or is_admin());

drop policy if exists "管理者は通報を消せる" on review_reports;
create policy "管理者は通報を消せる" on review_reports for delete to authenticated
  using (is_admin());

drop policy if exists "ブロックは本人だけ" on user_blocks;
create policy "ブロックは本人だけ" on user_blocks for all to authenticated
  using (blocker = auth.uid()) with check (blocker = auth.uid());

drop policy if exists "管理者だけ見える" on admins;
create policy "管理者だけ見える" on admins for select to authenticated using (is_admin());

drop policy if exists "利用停止は管理者だけ" on banned_users;
create policy "利用停止は管理者だけ" on banned_users for all to authenticated
  using (is_admin()) with check (is_admin());

grant select on reviews to anon, authenticated;
grant insert, delete, update on reviews to authenticated;
grant select, insert, delete on review_reports to authenticated;
grant select, insert, delete on user_blocks to authenticated;
grant select on admins to authenticated;
grant select, insert, delete on banned_users to authenticated;

-- 6. 林道ごとの口コミ一覧（新しい順・最大100件）。投稿者は ID の先頭だけを出す
create or replace function reviews_for_road(road_name text)
returns table (id bigint, author text, is_mine boolean, author_id uuid, driven_on date,
               condition text, body text, hidden boolean, created_at timestamptz)
language sql stable set search_path = public as $$
  select r.id, 'ライダー' || upper(substr(replace(r.user_id::text, '-', ''), 1, 4)),
         r.user_id = auth.uid(), r.user_id, r.driven_on, r.condition, r.body, r.hidden, r.created_at
    from reviews r join roads d on d.id = r.road_id
   where d.name = road_name
   order by r.created_at desc
   limit 100
$$;
grant execute on function reviews_for_road(text) to anon, authenticated;

-- 7. 口コミを書く（林道名で指定）
create or replace function post_review(road_name text, driven_on date, condition text, body text)
returns bigint
language plpgsql set search_path = public as $$
declare new_id bigint;
begin
  insert into reviews (road_id, driven_on, condition, body)
  select id, post_review.driven_on, post_review.condition, btrim(post_review.body)
    from roads where name = road_name
  returning id into new_id;
  if new_id is null then raise exception '林道が見つかりません：%', road_name; end if;
  return new_id;
end $$;
grant execute on function post_review(text, date, text, text) to authenticated;

-- 8. アカウント削除（App Store の決まり：アプリ内で削除できること）
create or replace function delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'サインインしていません'; end if;
  delete from auth.users where id = auth.uid();   -- 口コミ・通報・ブロックは on delete cascade で消える
end $$;
revoke all on function delete_my_account() from public, anon;
grant execute on function delete_my_account() to authenticated;

-- 9. 管理画面用：通報のある口コミ・非表示の口コミ
create or replace function admin_review_queue()
returns table (id bigint, road text, author_id uuid, driven_on date, condition text, body text,
               hidden boolean, report_count int, reasons text, created_at timestamptz, banned boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '管理者だけが使えます'; end if;
  return query
  select r.id, d.name, r.user_id, r.driven_on, r.condition, r.body, r.hidden, r.report_count,
         (select string_agg(x.reason, '、') from review_reports x where x.review_id = r.id),
         r.created_at, exists (select 1 from banned_users b where b.user_id = r.user_id)
    from reviews r join roads d on d.id = r.road_id
   where r.hidden or r.report_count > 0
   order by r.hidden desc, r.created_at desc;
end $$;
grant execute on function admin_review_queue() to authenticated;

-- 10. 管理画面用：最近の口コミ（すべて）
create or replace function admin_recent_reviews(days int default 14)
returns table (id bigint, road text, author_id uuid, driven_on date, condition text, body text,
               hidden boolean, report_count int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '管理者だけが使えます'; end if;
  return query
  select r.id, d.name, r.user_id, r.driven_on, r.condition, r.body, r.hidden, r.report_count, r.created_at
    from reviews r join roads d on d.id = r.road_id
   where r.created_at > now() - make_interval(days => days)
   order by r.created_at desc;
end $$;
grant execute on function admin_recent_reviews(int) to authenticated;
