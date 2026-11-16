-- Padelent: photos and videos in messages (broadcasts, your private chats, and replies to you).
-- Paste all of this into the Supabase SQL Editor and press Run, after admin-messages.sql.
-- Safe to run again. If you ever run admin-messages.sql again, run this file again afterwards.
--
-- Photos and videos are stored privately in the "chat-media" bucket. Only the people in that
-- chat (and you) can open them, through short-lived links the app asks for.

-- ---------- Columns ----------
alter table public.inbox_messages add column if not exists media_path text;
alter table public.inbox_messages add column if not exists media_type text;
alter table public.broadcasts add column if not exists media_path text;
alter table public.broadcasts add column if not exists media_type text;

alter table public.inbox_messages drop constraint if exists inbox_messages_media_type_check;
alter table public.inbox_messages add constraint inbox_messages_media_type_check check (media_type is null or media_type in ('image', 'video'));

-- A message can be text, a voice note, a photo or video, or any mix.
alter table public.inbox_messages drop constraint if exists inbox_messages_has_content;
alter table public.inbox_messages add constraint inbox_messages_has_content
  check (char_length(body) <= 5000 and (char_length(body) >= 1 or audio_path is not null or media_path is not null));

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 52428800,
        array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic',
              'video/mp4', 'video/quicktime', 'video/webm', 'video/x-m4v', 'video/3gpp'])
on conflict (id) do update set public = false, file_size_limit = 52428800, allowed_mime_types = excluded.allowed_mime_types;

-- A photo or video must be one the sender uploaded to their own folder.
create or replace function public.check_chat_media(p_media text) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(p_media, '') = '' then return null; end if;
  if split_part(p_media, '/', 1) <> auth.uid()::text or p_media like '%..%' then raise exception 'That photo or video could not be sent.'; end if;
  return p_media;
end $$;

create or replace function public.chat_media_kind(p_media text, p_type text) returns text
language sql immutable as $$
  select case when p_media is null then null when p_type in ('image', 'video') then p_type
              when p_media ~* '\.(jpe?g|png|webp|gif|heic)$' then 'image' else 'video' end
$$;

create or replace function public.can_see_chat_media(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.inbox_messages m where m.media_path = p_name and auth.uid() in (m.user_id, m.sender_id))
$$;

drop policy if exists "padelent chat media upload" on storage.objects;
create policy "padelent chat media upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-media' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "padelent chat media view" on storage.objects;
create policy "padelent chat media view" on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and ((storage.foldername(name))[1] = auth.uid()::text or public.can_see_chat_media(name)));

-- What a message says in emails and notifications when it has no text.
create or replace function public.inbox_attachment_note(p_audio text, p_media_kind text, p_you boolean default true) returns text
language sql immutable as $$
  select case
    when p_media_kind = 'image' then case when p_you then '📷 I''ve sent you a photo. Tap the button below to see it in the app.' else '📷 They sent you a photo.' end
    when p_media_kind = 'video' then case when p_you then '🎬 I''ve sent you a video. Tap the button below to watch it in the app.' else '🎬 They sent you a video.' end
    when p_audio is not null then case when p_you then '🎙️ I''ve sent you a voice note. Tap the button below to listen in the app.' else '🎙️ They sent you a voice note.' end
  end
$$;

-- ---------- Reading chats ----------
create or replace function public.my_inbox() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v json;
begin
  if v_uid is null then return null; end if;
  select json_build_object(
    'admin_name', public.admin_name(),
    'messages', coalesce((select json_agg(json_build_object(
        'id', m.id, 'mine', m.sender_id = v_uid, 'body', m.body, 'created_at', m.created_at, 'broadcast', m.broadcast_id is not null,
        'image_url', m.image_url, 'audio_path', m.audio_path, 'media_path', m.media_path, 'media_type', m.media_type)
      order by m.created_at) from public.inbox_messages m where m.user_id = v_uid), '[]'::json))
  into v;
  update public.inbox_messages set read_by_user = true where user_id = v_uid and not read_by_user;
  return v;
end $$;

create or replace function public.admin_thread(p_user uuid) returns json
language plpgsql security definer set search_path = public as $$
declare v json;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  select json_build_object('user_id', p.id, 'full_name', p.full_name, 'role', p.role, 'email', u.email,
    'messages', coalesce((select json_agg(json_build_object('id', m.id, 'from_admin', m.sender_id <> m.user_id, 'body', m.body,
        'created_at', m.created_at, 'broadcast', m.broadcast_id is not null, 'image_url', m.image_url, 'audio_path', m.audio_path,
        'media_path', m.media_path, 'media_type', m.media_type) order by m.created_at)
      from public.inbox_messages m where m.user_id = p.id), '[]'::json))
  into v from public.profiles p join auth.users u on u.id = p.id where p.id = p_user;
  update public.inbox_messages set read_by_admin = true where user_id = p_user and not read_by_admin;
  return v;
end $$;

create or replace function public.admin_conversations() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return json_build_object(
    'unread', (select count(*) from public.inbox_messages m where m.sender_id = m.user_id and not m.read_by_admin),
    'counts', json_build_object(
      'coaches', (select count(*) from public.profiles where role = 'coach' and not is_admin),
      'players', (select count(*) from public.profiles where role = 'player' and not is_admin)),
    'broadcasts', coalesce((select json_agg(json_build_object('audience', audience, 'body', body, 'voice', audio_path is not null,
         'media', media_type, 'recipients', recipients, 'created_at', created_at) order by created_at desc)
       from (select * from public.broadcasts order by created_at desc limit 5) b), '[]'::json),
    'threads', coalesce((select json_agg(x order by x.unread > 0 desc, x.last_at desc) from (
      select m.user_id, p.full_name, p.role, u.email,
             max(m.created_at) as last_at,
             (array_agg(coalesce(nullif(m.body, ''),
                case m.media_type when 'image' then '📷 Photo' when 'video' then '🎬 Video' end,
                '🎙️ Voice note') order by m.created_at desc))[1] as last_body,
             bool_or(m.sender_id = m.user_id) as replied,
             count(*) filter (where m.sender_id = m.user_id and not m.read_by_admin) as unread
      from public.inbox_messages m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
      group by m.user_id, p.full_name, p.role, u.email
      having bool_or(m.sender_id = m.user_id) or bool_or(m.broadcast_id is null)
    ) x), '[]'::json));
end $$;

-- ---------- Sending ----------
drop function if exists public.send_inbox_message(text);
drop function if exists public.send_inbox_message(text, text);
create or replace function public.send_inbox_message(p_body text, p_audio text default null, p_media text default null, p_media_type text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; v_email text; v_body text := left(coalesce(trim(p_body), ''), 5000); v_kind text;
begin
  if v_uid is null then raise exception 'Please log in again.'; end if;
  p_audio := public.check_voice_note(p_audio);
  p_media := public.check_chat_media(p_media);
  v_kind := public.chat_media_kind(p_media, p_media_type);
  if v_body = '' and p_audio is null and p_media is null then raise exception 'Write a message, record a voice note or add a photo or video first.'; end if;
  insert into public.inbox_messages (user_id, sender_id, body, audio_path, media_path, media_type, read_by_user, read_by_admin)
  values (v_uid, v_uid, v_body, p_audio, p_media, v_kind, true, false);
  select p.full_name, u.email into v_name, v_email from public.profiles p join auth.users u on u.id = p.id where p.id = v_uid;
  perform public.send_padelent_email('info@padelent.com',
    'Reply from ' || coalesce(nullif(v_name, ''), v_email),
    coalesce(nullif(v_name, ''), v_email) || ' replied',
    array_remove(array[nullif(left(v_body, 600), ''),
      case when p_audio is not null then '🎙️ They sent you a voice note.' end,
      case when v_kind is not null then public.inbox_attachment_note(null, v_kind, false) end], null),
    'Open in Admin', 'https://padelent.com/app/#/admin/chat/' || v_uid);
end $$;

drop function if exists public.admin_broadcast(text, text);
drop function if exists public.admin_broadcast(text, text, text);
create or replace function public.admin_broadcast(p_audience text, p_body text, p_audio text default null, p_media text default null, p_media_type text default null) returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_b uuid; v_n int; v_from text := public.admin_name(); v_emails jsonb; v_kind text;
        v_body text := left(coalesce(trim(p_body), ''), 5000); v_paras text[]; v_subject text; v_button text;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_audience not in ('coaches', 'players', 'everyone') then raise exception 'Pick who to send it to.'; end if;
  p_audio := public.check_voice_note(p_audio);
  p_media := public.check_chat_media(p_media);
  v_kind := public.chat_media_kind(p_media, p_media_type);
  if v_body = '' and p_audio is null and p_media is null then raise exception 'Write a message, record a voice note or add a photo or video first.'; end if;
  v_paras := case when v_body = '' then array[]::text[] else regexp_split_to_array(v_body, '\n\s*\n') end
             || array_remove(array[
                  case when v_kind is not null then public.inbox_attachment_note(null, v_kind) end,
                  case when p_audio is not null then public.inbox_attachment_note(p_audio, null) end], null);
  v_subject := case when v_kind = 'video' then v_from || ' sent you a video on Padelent'
                    when v_kind = 'image' then v_from || ' sent you a photo on Padelent'
                    when p_audio is not null then v_from || ' sent you a voice note on Padelent'
                    else 'A message from ' || v_from || ' at Padelent' end;
  v_button := case when v_kind = 'video' then 'Watch in the app' when v_kind = 'image' then 'See it in the app'
                   when p_audio is not null then 'Listen in the app' else 'Reply in the app' end;

  insert into public.broadcasts (audience, body, audio_path, media_path, media_type, created_by)
  values (p_audience, v_body, p_audio, p_media, v_kind, v_uid) returning id into v_b;

  insert into public.inbox_messages (user_id, sender_id, body, audio_path, media_path, media_type, broadcast_id, read_by_user, read_by_admin)
  select p.id, v_uid, v_body, p_audio, p_media, v_kind, v_b, false, true
  from public.profiles p
  where p.id <> v_uid
    and (p_audience = 'everyone' or (p_audience = 'coaches' and p.role = 'coach') or (p_audience = 'players' and p.role = 'player'));
  get diagnostics v_n = row_count;
  update public.broadcasts set recipients = v_n where id = v_b;

  select coalesce(jsonb_agg(jsonb_build_object(
      'from', 'Padelent <info@padelent.com>',
      'to', jsonb_build_array(u.email),
      'reply_to', 'info@padelent.com',
      'subject', v_subject,
      'html', public.padelent_email_html('Hi ' || coalesce(nullif(split_part(trim(p.full_name), ' ', 1), ''), 'there') || ',',
                v_paras || array['— ' || v_from || ', Padelent'], v_button, 'https://padelent.com/app/#/inbox'),
      'text', array_to_string(v_paras, chr(10) || chr(10)) || chr(10) || chr(10) || '— ' || v_from || ', Padelent' || chr(10) || 'Open the app: https://padelent.com/app/#/inbox')), '[]'::jsonb)
    into v_emails
  from public.inbox_messages m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
  where m.broadcast_id = v_b and u.email is not null;
  perform public.send_padelent_batch(v_emails);
  return v_n;
end $$;

drop function if exists public.admin_send(uuid, text);
drop function if exists public.admin_send(uuid, text, text);
create or replace function public.admin_send(p_user uuid, p_body text, p_audio text default null, p_media text default null, p_media_type text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text; v_first text; v_from text := public.admin_name(); v_body text := left(coalesce(trim(p_body), ''), 5000); v_kind text;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  p_audio := public.check_voice_note(p_audio);
  p_media := public.check_chat_media(p_media);
  v_kind := public.chat_media_kind(p_media, p_media_type);
  if v_body = '' and p_audio is null and p_media is null then raise exception 'Write a message, record a voice note or add a photo or video first.'; end if;
  insert into public.inbox_messages (user_id, sender_id, body, audio_path, media_path, media_type, read_by_user, read_by_admin)
  values (p_user, auth.uid(), v_body, p_audio, p_media, v_kind, false, true);
  select u.email, coalesce(nullif(split_part(trim(p.full_name), ' ', 1), ''), 'there') into v_email, v_first
  from auth.users u join public.profiles p on p.id = u.id where u.id = p_user;
  perform public.send_padelent_email(v_email,
    'New message from ' || v_from || ' at Padelent',
    'Hi ' || v_first || ',',
    array_remove(array[nullif(left(v_body, 1500), ''),
      case when v_kind is not null then public.inbox_attachment_note(null, v_kind) end,
      case when p_audio is not null then public.inbox_attachment_note(p_audio, null) end,
      '— ' || v_from || ', Padelent'], null),
    'Reply in the app', 'https://padelent.com/app/#/inbox');
end $$;

revoke execute on function public.send_inbox_message(text, text, text, text), public.admin_broadcast(text, text, text, text, text),
  public.admin_send(uuid, text, text, text, text), public.check_chat_media(text), public.can_see_chat_media(text),
  public.my_inbox(), public.admin_thread(uuid), public.admin_conversations() from public, anon;
grant execute on function public.send_inbox_message(text, text, text, text), public.admin_broadcast(text, text, text, text, text),
  public.admin_send(uuid, text, text, text, text), public.check_chat_media(text), public.can_see_chat_media(text),
  public.my_inbox(), public.admin_thread(uuid), public.admin_conversations() to authenticated;

-- ---------- Phone notifications ----------
-- Same as in push.sql, but says "Sent you a photo / video" when there is no text.
do $$
begin
  if to_regprocedure('public.push_send(uuid[], text, text, text, text)') is null then return; end if;
  execute $f$
create or replace function public.inbox_push() returns trigger
language plpgsql security definer set search_path = public as $b$
declare r record; v_from text := public.admin_name();
begin
  for r in select broadcast_id, array_agg(user_id) as users, min(body) as body, bool_or(audio_path is not null) as voice, min(media_type) as media
           from new_rows where broadcast_id is not null group by broadcast_id loop
    perform public.push_send(r.users, v_from || ' from Padelent',
      coalesce(nullif(left(r.body, 200), ''), case r.media when 'image' then '📷 Sent you a photo' when 'video' then '🎬 Sent you a video' end,
               case when r.voice then '🎙️ Sent you a voice note' end), '/app/#/inbox', 'inbox');
  end loop;
  for r in select * from new_rows where broadcast_id is null loop
    if r.sender_id = r.user_id then
      perform public.push_admins(coalesce(nullif(public.first_name_of(r.user_id), ''), 'Someone') || ' replied',
        coalesce(nullif(left(r.body, 200), ''), case r.media_type when 'image' then '📷 Sent you a photo' when 'video' then '🎬 Sent you a video' end,
                 case when r.audio_path is not null then '🎙️ Sent you a voice note' end),
        '/app/#/admin/chat/' || r.user_id, 'admin-' || r.user_id);
    else
      perform public.push_send(array[r.user_id], v_from || ' from Padelent',
        coalesce(nullif(left(r.body, 200), ''), case r.media_type when 'image' then '📷 Sent you a photo' when 'video' then '🎬 Sent you a video' end,
                 case when r.audio_path is not null then '🎙️ Sent you a voice note' end),
        '/app/#/inbox', 'inbox');
    end if;
  end loop;
  return null;
exception when others then
  return null;
end $b$;
  $f$;
end $$;
