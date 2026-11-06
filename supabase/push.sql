-- Padelent phone notifications (Web Push).
-- Run this whole file in the Supabase SQL Editor, after deploying the "send-push" Edge Function.
-- Safe to run again.
--
-- How it works:
--   * A player or coach taps "Turn on notifications" in the app. Their phone gives the app a
--     private address for notifications, saved in push_subscriptions.
--   * When something happens (new lesson, coach reply, new message, a broadcast from you),
--     these triggers ask the send-push Edge Function to deliver a notification.
--   * The notification keys are made automatically the first time (nobody has to copy any keys).
--   * Emails keep going as normal, so nobody misses anything if notifications are off.

-- ---------- Settings and keys (private) ----------

create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  function_url text not null,
  subject text not null default 'mailto:info@padelent.com',
  public_key text,
  private_key text,
  setup_request bigint,
  setup_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

insert into public.push_config (id, function_url)
values (1, 'https://bjqffcfbnfyoumklewbd.supabase.co/functions/v1/send-push')
on conflict (id) do update set function_url = excluded.function_url, updated_at = now();

create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

create table if not exists public.push_log (
  request_id bigint primary key,
  created_at timestamptz not null default now()
);
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;

-- Makes the notification keys the first time (the Edge Function creates them), and
-- returns the public key the app needs. The private key never leaves the database.
create or replace function public.push_public_key() returns text
language plpgsql security definer set search_path = public, net as $$
declare c public.push_config; r record; j jsonb;
begin
  select * into c from public.push_config where id = 1;
  if c.public_key is not null then return c.public_key; end if;
  if c.setup_request is not null then
    select status_code, content into r from net._http_response where id = c.setup_request;
    if r.status_code = 200 then
      begin j := r.content::jsonb; exception when others then j := null; end;
      if j ? 'publicKey' and j ? 'privateKey' then
        update public.push_config set public_key = j->>'publicKey', private_key = j->>'privateKey', updated_at = now() where id = 1;
        return j->>'publicKey';
      end if;
    end if;
  end if;
  -- Ask the Edge Function for new keys (again after a minute if the last try did not work).
  if c.setup_at is null or c.setup_at < now() - interval '1 minute' then
    update public.push_config set setup_at = now(),
      setup_request = net.http_post(url := c.function_url || '?setup=1', body := '{}'::jsonb,
                                    headers := '{"Content-Type": "application/json"}'::jsonb)
    where id = 1;
  end if;
  return null;
end $$;

-- ---------- Sending ----------

create or replace function public.push_send(p_users uuid[], p_title text, p_body text, p_url text, p_tag text default null)
returns void
language plpgsql security definer set search_path = public, net as $$
declare c public.push_config; v_subs jsonb; v_req bigint;
begin
  select * into c from public.push_config where id = 1;
  if c.public_key is null or c.private_key is null then return; end if;
  select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)), '[]'::jsonb)
    into v_subs from public.push_subscriptions where user_id = any(p_users);
  if jsonb_array_length(v_subs) = 0 then return; end if;
  v_req := net.http_post(
    url := c.function_url,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object(
      'vapid', jsonb_build_object('publicKey', c.public_key, 'privateKey', c.private_key, 'subject', c.subject),
      'subs', v_subs,
      'payload', jsonb_build_object('title', left(p_title, 120), 'body', left(coalesce(p_body, ''), 240),
                                    'url', coalesce(p_url, '/app/'), 'tag', p_tag)),
    timeout_milliseconds := 15000);
  insert into public.push_log (request_id) values (v_req) on conflict do nothing;
exception when others then
  return;  -- a notification must never stop a lesson or message from saving
end $$;

create or replace function public.push_admins(p_title text, p_body text, p_url text, p_tag text default null) returns void
language sql security definer set search_path = public as $$
  select public.push_send(array(select id from public.profiles where is_admin), p_title, p_body, p_url, p_tag)
$$;

-- Removes phones that have switched notifications off or deleted the app.
create or replace function public.push_cleanup() returns void
language plpgsql security definer set search_path = public, net as $$
declare l record; j jsonb;
begin
  for l in select p.request_id, r.status_code, r.content from public.push_log p
           join net._http_response r on r.id = p.request_id loop
    if l.status_code = 200 then
      begin j := l.content::jsonb; exception when others then j := null; end;
      if j ? 'gone' then
        delete from public.push_subscriptions where endpoint in (select jsonb_array_elements_text(j->'gone'));
      end if;
    end if;
    delete from public.push_log where request_id = l.request_id;
  end loop;
  delete from public.push_log where created_at < now() - interval '1 day';
exception when others then
  return;
end $$;

select cron.schedule('padelent-push-cleanup', '17 * * * *', 'select public.push_cleanup()');

revoke execute on function public.push_send(uuid[], text, text, text, text), public.push_admins(text, text, text, text),
  public.push_cleanup() from public, anon, authenticated;

-- ---------- For the app ----------

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in again.'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Notifications could not be turned on on this phone.';
  end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, last_seen = now();
end $$;

create or replace function public.remove_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

create or replace function public.push_test() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.push_subscriptions where user_id = auth.uid()) then return false; end if;
  perform public.push_send(array[auth.uid()], 'Notifications are on 🎾', 'This is how Padelent will let you know about lessons and messages.', '/app/', 'test');
  return true;
end $$;

revoke execute on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text),
  public.push_test(), public.push_public_key() from public, anon;
grant execute on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text),
  public.push_test(), public.push_public_key() to authenticated;

-- ---------- What sends a notification ----------

-- Lessons: a new (paid) lesson for the coach; "your lesson is ready" for the player.
create or replace function public.lesson_push() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'new' and (tg_op = 'INSERT' or old.status = 'pending_payment') then
    perform public.push_send(array[new.coach_id], 'New lesson from ' || public.first_name_of(new.player_id),
      new.topic, '/app/#/space/' || new.player_id, 'lesson-' || new.id);
  end if;
  if tg_op = 'UPDATE' and new.status = 'done' and old.status <> 'done' then
    perform public.push_send(array[new.player_id], public.first_name_of(new.coach_id) || ' has replied to your lesson',
      'Tap to watch your lesson on "' || left(new.topic, 80) || '"', '/app/#/space/' || new.coach_id, 'lesson-' || new.id);
  end if;
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists lesson_push on public.lessons;
create constraint trigger lesson_push after insert or update of status on public.lessons
  deferrable initially deferred
  for each row execute function public.lesson_push();

-- Lesson chat messages (the booking itself and the reply that finishes a lesson are covered above).
create or replace function public.message_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.lessons; v_text text;
begin
  select * into l from public.lessons where id = new.lesson_id;
  if l.id is null or l.status = 'pending_payment' then return null; end if;
  if not exists (select 1 from public.messages m where m.lesson_id = new.lesson_id and m.id <> new.id and m.created_at <= new.created_at) then
    return null;  -- first message = the booking
  end if;
  v_text := coalesce(nullif(left(new.body, 200), ''),
    case when coalesce(array_length(new.videos, 1), 0) > 0 then 'Sent you a new video' else 'Sent you a message' end);
  if new.sender_id = l.player_id then
    perform public.push_send(array[l.coach_id], public.first_name_of(l.player_id), v_text, '/app/#/space/' || l.player_id, 'chat-' || l.id);
  elsif new.sender_id = l.coach_id and not (l.status = 'done' and l.done_at >= now()) then
    perform public.push_send(array[l.player_id], public.first_name_of(l.coach_id), v_text, '/app/#/space/' || l.coach_id, 'chat-' || l.id);
  end if;
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists message_push on public.messages;
create constraint trigger message_push after insert on public.messages
  deferrable initially deferred
  for each row execute function public.message_push();

-- Messages with you: broadcasts (one notification request for everyone), your private messages, and replies to you.
create or replace function public.inbox_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_from text := public.admin_name();
begin
  for r in select broadcast_id, array_agg(user_id) as users, min(body) as body, bool_or(audio_path is not null) as voice
           from new_rows where broadcast_id is not null group by broadcast_id loop
    perform public.push_send(r.users, v_from || ' from Padelent',
      coalesce(nullif(left(r.body, 200), ''), case when r.voice then '🎙️ Sent you a voice note' end), '/app/#/inbox', 'inbox');
  end loop;
  for r in select * from new_rows where broadcast_id is null loop
    if r.sender_id = r.user_id then
      perform public.push_admins(coalesce(nullif(public.first_name_of(r.user_id), ''), 'Someone') || ' replied',
        coalesce(nullif(left(r.body, 200), ''), case when r.audio_path is not null then '🎙️ Sent you a voice note' end),
        '/app/#/admin/chat/' || r.user_id, 'admin-' || r.user_id);
    else
      perform public.push_send(array[r.user_id], v_from || ' from Padelent',
        coalesce(nullif(left(r.body, 200), ''), case when r.audio_path is not null then '🎙️ Sent you a voice note' end),
        '/app/#/inbox', 'inbox');
    end if;
  end loop;
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists inbox_push on public.inbox_messages;
create trigger inbox_push after insert on public.inbox_messages
  referencing new table as new_rows
  for each statement execute function public.inbox_push();

-- Make the keys now, so they are ready by the time someone turns notifications on.
select public.push_public_key();
