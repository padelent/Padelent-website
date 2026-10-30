-- =====================================================================
-- Padelent app: database setup
-- Paste ALL of this into Supabase > SQL Editor > New query, then press Run.
-- Safe to run again: it only adds or updates, it never deletes data.
-- =====================================================================

-- ---------- Tables ----------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('player', 'coach')),
  full_name text not null default '' check (char_length(full_name) <= 80),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.coaches (
  id uuid primary key references public.profiles(id) on delete cascade,
  approved boolean not null default false,
  headline text not null default '' check (char_length(headline) <= 120),
  club text not null default '' check (char_length(club) <= 120),
  city text not null default '' check (char_length(city) <= 80),
  bio text not null default '' check (char_length(bio) <= 2000),
  photo_url text,
  intro_video_url text,
  racket text not null default '' check (char_length(racket) <= 80),
  hand text not null default '' check (hand in ('', 'right', 'left')),
  side text not null default '' check (side in ('', 'drive', 'reves', 'both')),
  playing_level text not null default '' check (char_length(playing_level) <= 120),
  years_coaching int check (years_coaching between 0 and 70),
  qualifications text not null default '' check (char_length(qualifications) <= 200),
  languages text not null default '' check (char_length(languages) <= 120),
  specialities text[] not null default '{}',
  price_pence int not null default 3000 check (price_pence between 500 and 100000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.players (
  id uuid primary key references public.profiles(id) on delete cascade,
  level numeric(2,1) check (level between 0 and 7),
  hand text not null default '' check (hand in ('', 'right', 'left')),
  side text not null default '' check (side in ('', 'drive', 'reves', 'both')),
  racket text not null default '' check (char_length(racket) <= 80),
  home_club text not null default '' check (char_length(home_club) <= 120),
  playing_for text not null default '' check (char_length(playing_for) <= 60),
  how_often text not null default '' check (char_length(how_often) <= 60),
  working_on text[] not null default '{}',
  goal text not null default '' check (char_length(goal) <= 500),
  updated_at timestamptz not null default now()
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  coach_id uuid not null references public.coaches(id) on delete cascade,
  topic text not null check (char_length(topic) between 1 and 140),
  status text not null default 'new' check (status in ('pending_payment', 'new', 'awaiting', 'done')),
  price_pence int not null,
  platform_fee_pence int not null,
  paid boolean not null default false,
  stripe_session_id text,
  created_at timestamptz not null default now(),
  opened_at timestamptz,
  done_at timestamptz
);
-- After a lesson is done, player and coach can keep chatting until the coach closes it.
alter table public.lessons add column if not exists closed_at timestamptz;
alter table public.lessons add column if not exists needs_coach boolean not null default false;
create index if not exists lessons_coach_idx on public.lessons (coach_id, created_at desc);
create index if not exists lessons_player_idx on public.lessons (player_id, created_at desc);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null default '' check (char_length(body) <= 5000),
  videos text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists messages_lesson_idx on public.messages (lesson_id, created_at);

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null unique references public.lessons(id) on delete cascade,
  coach_id uuid not null references public.coaches(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  tags text[] not null default '{}',
  comment text not null default '' check (char_length(comment) <= 500),
  display_name text not null,
  topic text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists reviews_coach_idx on public.reviews (coach_id, created_at desc);

-- ---------- Security: nobody writes tables directly ------------------
-- Every change goes through the functions further down, which check who is asking.

alter table public.profiles enable row level security;
alter table public.coaches  enable row level security;
alter table public.players  enable row level security;
alter table public.lessons  enable row level security;
alter table public.messages enable row level security;
alter table public.reviews  enable row level security;

revoke all on public.profiles, public.coaches, public.players, public.lessons, public.messages, public.reviews from anon, authenticated;
grant select on public.profiles, public.coaches, public.players, public.lessons, public.messages to authenticated;
grant select on public.reviews to anon, authenticated;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select to authenticated using (id = auth.uid());

drop policy if exists "approved or own coach" on public.coaches;
create policy "approved or own coach" on public.coaches for select to authenticated using (approved or id = auth.uid());

drop policy if exists "own player or my coach" on public.players;
create policy "own player or my coach" on public.players for select to authenticated using (
  id = auth.uid() or exists (select 1 from public.lessons l where l.player_id = players.id and l.coach_id = auth.uid())
);

drop policy if exists "my lessons" on public.lessons;
create policy "my lessons" on public.lessons for select to authenticated using (auth.uid() in (player_id, coach_id));

drop policy if exists "messages in my lessons" on public.messages;
create policy "messages in my lessons" on public.messages for select to authenticated using (
  exists (select 1 from public.lessons l where l.id = messages.lesson_id and auth.uid() in (l.player_id, l.coach_id))
);

drop policy if exists "reviews are public" on public.reviews;
create policy "reviews are public" on public.reviews for select to anon, authenticated using (true);

-- ---------- Settings ---------------------------------------------------

-- Padelent's share of each lesson, in percent.
create or replace function public.platform_fee_percent() returns int
language sql immutable as $$ select 20 $$;

-- Switch to true once Stripe is connected: lessons then wait for payment before the coach sees them.
create or replace function public.payments_required() returns boolean
language sql immutable as $$ select false $$;

-- ---------- New accounts ---------------------------------------------

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_role text := coalesce(new.raw_user_meta_data->>'role', 'player');
  v_name text := left(trim(coalesce(new.raw_user_meta_data->>'full_name', '')), 80);
begin
  if v_role not in ('player', 'coach') then v_role := 'player'; end if;
  insert into public.profiles (id, role, full_name) values (new.id, v_role, v_name) on conflict (id) do nothing;
  if v_role = 'coach' then
    insert into public.coaches (id) values (new.id) on conflict (id) do nothing;
  else
    insert into public.players (id) values (new.id) on conflict (id) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ---------- Public coach list ------------------------------------------

-- (Rebuilt each time; also removes the old Instagram field.)
drop view if exists public.coach_cards;
alter table public.coaches drop column if exists instagram;

create view public.coach_cards as
select c.id, p.full_name, c.headline, c.club, c.city, c.bio, c.photo_url, c.intro_video_url,
       c.racket, c.hand, c.side, c.playing_level, c.years_coaching, c.qualifications, c.languages,
       c.specialities, c.price_pence, c.created_at,
       coalesce(r.avg_rating, 0)::float as avg_rating,
       coalesce(r.review_count, 0)::int as review_count,
       coalesce(l.lessons_done, 0)::int as lessons_done
from public.coaches c
join public.profiles p on p.id = c.id
left join (select coach_id, round(avg(rating)::numeric, 2) as avg_rating, count(*) as review_count
           from public.reviews group by coach_id) r on r.coach_id = c.id
left join (select coach_id, count(*) as lessons_done
           from public.lessons where status = 'done' group by coach_id) l on l.coach_id = c.id
where c.approved;

grant select on public.coach_cards to anon, authenticated;

-- ---------- My account -------------------------------------------------

create or replace function public.my_profile() returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v json;
begin
  if v_uid is null then return null; end if;
  select json_build_object(
    'id', p.id, 'role', p.role, 'full_name', p.full_name, 'is_admin', p.is_admin,
    'coach', (select row_to_json(c) from public.coaches c where c.id = p.id),
    'player', (select row_to_json(pl) from public.players pl where pl.id = p.id)
  ) into v from public.profiles p where p.id = v_uid;
  return v;
end $$;

create or replace function public.save_my_profile(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_role is null then raise exception 'Please log in again.'; end if;

  if p ? 'full_name' then
    update public.profiles set full_name = left(trim(p->>'full_name'), 80) where id = v_uid;
  end if;

  if v_role = 'coach' then
    update public.coaches set
      headline       = coalesce(p->>'headline', headline),
      club           = coalesce(p->>'club', club),
      city           = coalesce(p->>'city', city),
      bio            = coalesce(p->>'bio', bio),
      photo_url      = case when p ? 'photo_url' then nullif(p->>'photo_url', '') else photo_url end,
      intro_video_url= case when p ? 'intro_video_url' then nullif(p->>'intro_video_url', '') else intro_video_url end,
      racket         = coalesce(p->>'racket', racket),
      hand           = coalesce(p->>'hand', hand),
      side           = coalesce(p->>'side', side),
      playing_level  = coalesce(p->>'playing_level', playing_level),
      years_coaching = case when p ? 'years_coaching' then nullif(p->>'years_coaching', '')::int else years_coaching end,
      qualifications = coalesce(p->>'qualifications', qualifications),
      languages      = coalesce(p->>'languages', languages),
      specialities   = case when p ? 'specialities' then array(select jsonb_array_elements_text(p->'specialities')) else specialities end,
      price_pence    = coalesce((p->>'price_pence')::int, price_pence),
      updated_at     = now()
    where id = v_uid;
  else
    update public.players set
      level      = case when p ? 'level' then nullif(p->>'level', '')::numeric else level end,
      hand       = coalesce(p->>'hand', hand),
      side       = coalesce(p->>'side', side),
      racket     = coalesce(p->>'racket', racket),
      home_club  = coalesce(p->>'home_club', home_club),
      playing_for= coalesce(p->>'playing_for', playing_for),
      how_often  = coalesce(p->>'how_often', how_often),
      working_on = case when p ? 'working_on' then array(select jsonb_array_elements_text(p->'working_on')) else working_on end,
      goal       = coalesce(p->>'goal', goal),
      updated_at = now()
    where id = v_uid;
  end if;
  return public.my_profile();
end $$;

-- ---------- Lessons ----------------------------------------------------

create or replace function public.book_lesson(p_coach uuid, p_topic text, p_body text, p_videos text[])
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_price int; v_id uuid; v text;
begin
  if not exists (select 1 from public.players where id = v_uid) then
    raise exception 'Only player accounts can book lessons.';
  end if;
  select price_pence into v_price from public.coaches where id = p_coach and approved;
  if v_price is null then raise exception 'This coach is not taking lessons right now.'; end if;
  if coalesce(trim(p_topic), '') = '' then raise exception 'Tell your coach what you want help with.'; end if;
  if coalesce(array_length(p_videos, 1), 0) = 0 then raise exception 'Add at least one video.'; end if;
  if array_length(p_videos, 1) > 3 then raise exception 'You can send up to 3 videos per lesson.'; end if;
  foreach v in array p_videos loop
    if split_part(v, '/', 1) <> v_uid::text then raise exception 'Video upload not recognised.'; end if;
  end loop;

  update public.lessons set closed_at = now(), needs_coach = false
  where player_id = v_uid and coach_id = p_coach and status = 'done' and closed_at is null;

  insert into public.lessons (player_id, coach_id, topic, status, price_pence, platform_fee_pence)
  values (v_uid, p_coach, left(trim(p_topic), 140),
          case when public.payments_required() then 'pending_payment' else 'new' end,
          v_price, round(v_price * public.platform_fee_percent() / 100.0))
  returning id into v_id;

  insert into public.messages (lesson_id, sender_id, body, videos)
  values (v_id, v_uid, left(coalesce(p_body, ''), 5000), p_videos);
  return v_id;
end $$;

create or replace function public.open_lesson(p_lesson uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.lessons set status = 'awaiting', opened_at = now()
  where id = p_lesson and coach_id = auth.uid() and status = 'new';
  update public.lessons set needs_coach = false
  where id = p_lesson and coach_id = auth.uid() and needs_coach;
end $$;

-- Coach: finish the follow-up chat on a done lesson.
create or replace function public.close_lesson(p_lesson uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.lessons set closed_at = now(), needs_coach = false
  where id = p_lesson and coach_id = auth.uid() and status = 'done' and closed_at is null;
  if not found then raise exception 'Only a finished lesson can be closed.'; end if;
end $$;

create or replace function public.send_message(p_lesson uuid, p_body text, p_videos text[], p_mark_done boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); l public.lessons; v text;
begin
  select * into l from public.lessons where id = p_lesson;
  if l.id is null or v_uid not in (l.player_id, l.coach_id) then raise exception 'Lesson not found.'; end if;
  if l.status = 'pending_payment' then raise exception 'This lesson has not been paid for yet.'; end if;
  if coalesce(trim(p_body), '') = '' and coalesce(array_length(p_videos, 1), 0) = 0 then
    raise exception 'Write a message or add a video.';
  end if;
  if coalesce(array_length(p_videos, 1), 0) > 3 then raise exception 'You can send up to 3 videos at a time.'; end if;
  foreach v in array coalesce(p_videos, '{}') loop
    if split_part(v, '/', 1) <> v_uid::text then raise exception 'Video upload not recognised.'; end if;
  end loop;
  if l.closed_at is not null then
    raise exception 'This lesson is closed. Book a new lesson to keep working together.';
  end if;

  insert into public.messages (lesson_id, sender_id, body, videos)
  values (p_lesson, v_uid, left(coalesce(p_body, ''), 5000), coalesce(p_videos, '{}'));

  if v_uid = l.player_id and l.status = 'done' then
    update public.lessons set needs_coach = true where id = p_lesson;
  end if;

  if v_uid = l.coach_id then
    update public.lessons set needs_coach = false where id = p_lesson and needs_coach;
    if p_mark_done then
      update public.lessons set status = 'done', done_at = now(), opened_at = coalesce(opened_at, now()) where id = p_lesson;
    elsif l.status = 'new' then
      update public.lessons set status = 'awaiting', opened_at = now() where id = p_lesson;
    end if;
  end if;
end $$;

create or replace function public.post_review(p_lesson uuid, p_rating int, p_tags text[], p_comment text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); l public.lessons; v_name text;
begin
  select * into l from public.lessons where id = p_lesson;
  if l.id is null or l.player_id <> v_uid then raise exception 'Lesson not found.'; end if;
  if l.status <> 'done' then raise exception 'You can review once your coach has replied.'; end if;
  if p_rating not between 1 and 5 then raise exception 'Pick between 1 and 5 stars.'; end if;
  select trim(split_part(full_name, ' ', 1)) ||
         case when position(' ' in trim(full_name)) > 0
              then ' ' || upper(left(trim(substring(trim(full_name) from position(' ' in trim(full_name)))), 1)) || '.'
              else '' end
    into v_name from public.profiles where id = v_uid;
  insert into public.reviews (lesson_id, coach_id, player_id, rating, tags, comment, display_name, topic)
  values (p_lesson, l.coach_id, v_uid, p_rating, coalesce(p_tags, '{}'), left(coalesce(p_comment, ''), 500),
          coalesce(nullif(v_name, ''), 'Padelent player'), l.topic)
  on conflict (lesson_id) do update set rating = excluded.rating, tags = excluded.tags,
    comment = excluded.comment, created_at = now();
end $$;

-- Coach: every lesson, newest first.
create or replace function public.coach_feed() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
    select l.id, l.player_id, l.topic, l.status, l.created_at, l.price_pence, l.platform_fee_pence, l.closed_at, l.needs_coach,
           p.full_name as player_name, pl.level, pl.side, pl.hand,
           (select count(*) from public.lessons l2 where l2.player_id = l.player_id and l2.coach_id = l.coach_id
              and l2.status <> 'pending_payment' and l2.created_at <= l.created_at) as nth,
           (select coalesce(sum(coalesce(array_length(m.videos, 1), 0)), 0) from public.messages m
              where m.lesson_id = l.id and m.sender_id = l.player_id) as video_count
    from public.lessons l
    join public.profiles p on p.id = l.player_id
    join public.players pl on pl.id = l.player_id
    where l.coach_id = auth.uid() and l.status <> 'pending_payment'
  ) x
$$;

-- Player: one row per coach they have had lessons with.
create or replace function public.player_coaches() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.last_at desc), '[]'::json) from (
    select l.coach_id, p.full_name as coach_name, c.photo_url, c.club,
           count(*) as lesson_count,
           max(l.created_at) as last_at,
           (array_agg(l.status order by l.created_at desc))[1] as last_status,
           (array_agg(l.closed_at order by l.created_at desc))[1] as last_closed_at,
           (array_agg(l.topic order by l.created_at desc))[1] as last_topic,
           count(*) filter (where l.status = 'done' and not exists (select 1 from public.reviews r where r.lesson_id = l.id)) as to_review
    from public.lessons l
    join public.profiles p on p.id = l.coach_id
    join public.coaches c on c.id = l.coach_id
    where l.player_id = auth.uid() and l.status <> 'pending_payment'
    group by l.coach_id, p.full_name, c.photo_url, c.club
  ) x
$$;

-- The shared space between one player and one coach, with every lesson and message.
create or replace function public.get_space(p_other uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_role text; v_player uuid; v_coach uuid; v_other json;
begin
  select role into v_role from public.profiles where id = v_uid;
  if v_role = 'coach' then
    v_coach := v_uid; v_player := p_other;
    if not exists (select 1 from public.lessons where coach_id = v_coach and player_id = v_player) then return null; end if;
    select json_build_object('id', p.id, 'full_name', p.full_name, 'player', row_to_json(pl)) into v_other
    from public.profiles p join public.players pl on pl.id = p.id where p.id = v_player;
  elsif v_role = 'player' then
    v_player := v_uid; v_coach := p_other;
    select json_build_object('id', c.id, 'full_name', c.full_name, 'photo_url', c.photo_url, 'club', c.club,
                             'price_pence', c.price_pence) into v_other
    from public.coach_cards c where c.id = v_coach;
    if v_other is null then
      select json_build_object('id', p.id, 'full_name', p.full_name, 'photo_url', c.photo_url, 'club', c.club,
                               'price_pence', c.price_pence) into v_other
      from public.profiles p join public.coaches c on c.id = p.id
      where p.id = v_coach and exists (select 1 from public.lessons where coach_id = v_coach and player_id = v_player);
    end if;
    if v_other is null then return null; end if;
  else
    return null;
  end if;

  return json_build_object(
    'role', v_role,
    'other', v_other,
    'lessons', coalesce((
      select json_agg(json_build_object(
        'id', l.id, 'topic', l.topic, 'status', l.status, 'price_pence', l.price_pence, 'closed_at', l.closed_at, 'needs_coach', l.needs_coach,
        'created_at', l.created_at, 'done_at', l.done_at,
        'review', (select json_build_object('rating', r.rating, 'comment', r.comment) from public.reviews r where r.lesson_id = l.id),
        'messages', coalesce((select json_agg(json_build_object(
              'id', m.id, 'sender_id', m.sender_id, 'body', m.body, 'videos', m.videos, 'created_at', m.created_at)
            order by m.created_at) from public.messages m where m.lesson_id = l.id), '[]'::json)
      ) order by l.created_at)
      from public.lessons l
      where l.player_id = v_player and l.coach_id = v_coach and l.status <> 'pending_payment'
    ), '[]'::json)
  );
end $$;

-- ---------- Admin (you) ------------------------------------------------

create or replace function public.admin_overview() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return json_build_object(
    'coaches', coalesce((select json_agg(json_build_object(
        'id', c.id, 'full_name', p.full_name, 'email', u.email, 'approved', c.approved, 'club', c.club,
        'city', c.city, 'price_pence', c.price_pence, 'photo_url', c.photo_url, 'bio', c.bio,
        'qualifications', c.qualifications, 'created_at', c.created_at) order by c.approved, c.created_at desc)
      from public.coaches c join public.profiles p on p.id = c.id join auth.users u on u.id = c.id), '[]'::json),
    'players', (select count(*) from public.players),
    'lessons', (select count(*) from public.lessons where status <> 'pending_payment'),
    'lessons_done', (select count(*) from public.lessons where status = 'done'),
    'revenue_pence', (select coalesce(sum(platform_fee_pence), 0) from public.lessons where status <> 'pending_payment')
  );
end $$;

create or replace function public.admin_set_approved(p_coach uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.coaches set approved = p_approved where id = p_coach;
end $$;

-- Functions are for logged-in users only (the coach list view above is public).
revoke execute on function public.my_profile(), public.save_my_profile(jsonb),
  public.book_lesson(uuid, text, text, text[]), public.open_lesson(uuid), public.close_lesson(uuid),
  public.send_message(uuid, text, text[], boolean), public.post_review(uuid, int, text[], text),
  public.coach_feed(), public.player_coaches(), public.get_space(uuid),
  public.admin_overview(), public.admin_set_approved(uuid, boolean) from public, anon;
grant execute on function public.my_profile(), public.save_my_profile(jsonb),
  public.book_lesson(uuid, text, text, text[]), public.open_lesson(uuid), public.close_lesson(uuid),
  public.send_message(uuid, text, text[], boolean), public.post_review(uuid, int, text[], text),
  public.coach_feed(), public.player_coaches(), public.get_space(uuid),
  public.admin_overview(), public.admin_set_approved(uuid, boolean) to authenticated;

-- ---------- Video and photo storage ----------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('coach-media', 'coach-media', true, 52428800,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'video/mp4', 'video/quicktime', 'video/webm'])
on conflict (id) do update set public = true;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lesson-videos', 'lesson-videos', false, 52428800,
        array['video/mp4', 'video/quicktime', 'video/webm', 'video/x-m4v', 'video/3gpp'])
on conflict (id) do update set public = false;

create or replace function public.can_view_video(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.messages m join public.lessons l on l.id = m.lesson_id
    where p_name = any(m.videos) and auth.uid() in (l.player_id, l.coach_id)
  )
$$;

drop policy if exists "padelent coach media upload" on storage.objects;
create policy "padelent coach media upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'coach-media' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "padelent coach media manage" on storage.objects;
create policy "padelent coach media manage" on storage.objects for delete to authenticated
  using (bucket_id = 'coach-media' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "padelent lesson video upload" on storage.objects;
create policy "padelent lesson video upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'lesson-videos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "padelent lesson video watch" on storage.objects;
create policy "padelent lesson video watch" on storage.objects for select to authenticated
  using (bucket_id = 'lesson-videos' and ((storage.foldername(name))[1] = auth.uid()::text or public.can_view_video(name)));
