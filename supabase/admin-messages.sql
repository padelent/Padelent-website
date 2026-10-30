-- =====================================================================
-- Padelent: messages from you (admin) to coaches and players.
--   * Broadcast to coaches, players or everyone. Each person gets it in
--     their Padelent inbox plus an email.
--   * Anyone can reply; replies land in your Admin > Messages as a
--     private chat you can answer.
-- Needs lesson-emails.sql to have been run first (it uses its email helpers).
-- Paste ALL of this into Supabase > SQL Editor > New query and press Run.
-- Safe to run again.
-- =====================================================================

create table if not exists public.inbox_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,   -- the coach or player in the chat
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  broadcast_id uuid,
  read_by_user boolean not null default false,
  read_by_admin boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists inbox_messages_user_idx on public.inbox_messages (user_id, created_at);

create table if not exists public.broadcasts (
  id uuid primary key default gen_random_uuid(),
  audience text not null check (audience in ('coaches', 'players', 'everyone')),
  body text not null,
  recipients int not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.inbox_messages enable row level security;
alter table public.broadcasts enable row level security;
revoke all on public.inbox_messages, public.broadcasts from anon, authenticated;

-- ---------- Email helpers ----------

create or replace function public.padelent_email_html(p_heading text, p_lines text[], p_button text, p_url text)
returns text language plpgsql immutable as $$
declare v_paras text := ''; l text;
begin
  foreach l in array coalesce(p_lines, '{}') loop
    v_paras := v_paras || '<p style="margin:0 0 14px;font-size:16px;line-height:1.55;color:#D5DEE6;white-space:pre-line;">' || public.html_esc(l) || '</p>';
  end loop;
  return '<!doctype html><html><body style="margin:0;padding:0;background:#0A1420;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0A1420;"><tr><td align="center" style="padding:28px 12px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;font-family:Helvetica,Arial,sans-serif;color:#FFFFFF;">
<tr><td style="padding:0 8px 22px;font-size:26px;font-weight:800;letter-spacing:-0.5px;color:#FFFFFF;"><span style="color:#D7F23A;">&#9679;</span> Padelent</td></tr>
<tr><td style="background:#1B2530;border-radius:18px;padding:30px 28px;">
  <h1 style="margin:0 0 14px;font-size:24px;line-height:1.2;color:#FFFFFF;">' || public.html_esc(p_heading) || '</h1>
  ' || v_paras || '
  <a href="' || public.html_esc(p_url) || '" style="display:inline-block;margin-top:8px;background:#D7F23A;color:#0A1420;font-weight:700;font-size:16px;text-decoration:none;padding:14px 28px;border-radius:999px;">' || public.html_esc(p_button) || '</a>
</td></tr>
<tr><td style="padding:22px 8px 0;font-size:13px;line-height:1.5;color:#A9B8C6;text-align:center;">
  Padel plus talent · You can reply inside the app, or write to <a href="mailto:info@padelent.com" style="color:#D7F23A;">info@padelent.com</a>
</td></tr>
</table></td></tr></table></body></html>';
end $$;

-- Send many emails in one go (Resend's batch endpoint takes up to 100 at a time).
create or replace function public.send_padelent_batch(p_emails jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_key text; i int := 0; n int := jsonb_array_length(coalesce(p_emails, '[]'::jsonb)); v_chunk jsonb;
begin
  if n = 0 then return; end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null then return; end if;
  while i < n loop
    select coalesce(jsonb_agg(e), '[]'::jsonb) into v_chunk
    from (select e from jsonb_array_elements(p_emails) with ordinality as t(e, ord) where ord > i and ord <= i + 100) x;
    perform net.http_post(
      url := 'https://api.resend.com/emails/batch',
      headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
      body := v_chunk);
    i := i + 100;
  end loop;
exception when others then
  return;
end $$;

revoke execute on function public.send_padelent_batch(jsonb) from public, anon, authenticated;

create or replace function public.admin_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(split_part(trim(full_name), ' ', 1), ''), 'Padelent') from public.profiles where is_admin order by created_at limit 1
$$;

-- ---------- For coaches and players ----------

create or replace function public.inbox_unread() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.inbox_messages where user_id = auth.uid() and sender_id <> auth.uid() and not read_by_user
$$;

-- Returns the chat with Padelent and marks it read.
create or replace function public.my_inbox() returns json
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v json;
begin
  if v_uid is null then return null; end if;
  select json_build_object(
    'admin_name', public.admin_name(),
    'messages', coalesce((select json_agg(json_build_object(
        'id', m.id, 'mine', m.sender_id = v_uid, 'body', m.body, 'created_at', m.created_at, 'broadcast', m.broadcast_id is not null)
      order by m.created_at) from public.inbox_messages m where m.user_id = v_uid), '[]'::json))
  into v;
  update public.inbox_messages set read_by_user = true where user_id = v_uid and not read_by_user;
  return v;
end $$;

create or replace function public.send_inbox_message(p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; v_email text;
begin
  if v_uid is null then raise exception 'Please log in again.'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Write a message first.'; end if;
  insert into public.inbox_messages (user_id, sender_id, body, read_by_user, read_by_admin)
  values (v_uid, v_uid, left(trim(p_body), 5000), true, false);
  select p.full_name, u.email into v_name, v_email from public.profiles p join auth.users u on u.id = p.id where p.id = v_uid;
  perform public.send_padelent_email('info@padelent.com',
    'Reply from ' || coalesce(nullif(v_name, ''), v_email),
    coalesce(nullif(v_name, ''), v_email) || ' replied',
    array[left(trim(p_body), 600)],
    'Open in Admin', 'https://padelent.com/app/#/admin/chat/' || v_uid);
end $$;

-- ---------- For you (admin) ----------

create or replace function public.admin_broadcast(p_audience text, p_body text) returns int
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_b uuid; v_n int; v_from text := public.admin_name(); v_emails jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if p_audience not in ('coaches', 'players', 'everyone') then raise exception 'Pick who to send it to.'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Write a message first.'; end if;

  insert into public.broadcasts (audience, body, created_by) values (p_audience, trim(p_body), v_uid) returning id into v_b;

  insert into public.inbox_messages (user_id, sender_id, body, broadcast_id, read_by_user, read_by_admin)
  select p.id, v_uid, left(trim(p_body), 5000), v_b, false, true
  from public.profiles p
  where p.id <> v_uid
    and (p_audience = 'everyone' or (p_audience = 'coaches' and p.role = 'coach') or (p_audience = 'players' and p.role = 'player'));
  get diagnostics v_n = row_count;
  update public.broadcasts set recipients = v_n where id = v_b;

  select coalesce(jsonb_agg(jsonb_build_object(
      'from', 'Padelent <info@padelent.com>',
      'to', jsonb_build_array(u.email),
      'reply_to', 'info@padelent.com',
      'subject', 'A message from ' || v_from || ' at Padelent',
      'html', public.padelent_email_html('Hi ' || coalesce(nullif(split_part(trim(p.full_name), ' ', 1), ''), 'there') || ',',
                regexp_split_to_array(trim(p_body), '\n\s*\n') || array['— ' || v_from || ', Padelent'],
                'Reply in the app', 'https://padelent.com/app/#/inbox'),
      'text', trim(p_body) || chr(10) || chr(10) || '— ' || v_from || ', Padelent' || chr(10) || 'Reply in the app: https://padelent.com/app/#/inbox')), '[]'::jsonb)
    into v_emails
  from public.inbox_messages m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
  where m.broadcast_id = v_b and u.email is not null;
  perform public.send_padelent_batch(v_emails);
  return v_n;
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
    'broadcasts', coalesce((select json_agg(json_build_object('audience', audience, 'body', body, 'recipients', recipients, 'created_at', created_at) order by created_at desc)
       from (select * from public.broadcasts order by created_at desc limit 5) b), '[]'::json),
    'threads', coalesce((select json_agg(x order by x.unread > 0 desc, x.last_at desc) from (
      select m.user_id, p.full_name, p.role, u.email,
             max(m.created_at) as last_at,
             (array_agg(m.body order by m.created_at desc))[1] as last_body,
             bool_or(m.sender_id = m.user_id) as replied,
             count(*) filter (where m.sender_id = m.user_id and not m.read_by_admin) as unread
      from public.inbox_messages m join public.profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
      group by m.user_id, p.full_name, p.role, u.email
      having bool_or(m.sender_id = m.user_id) or bool_or(m.broadcast_id is null)
    ) x), '[]'::json));
end $$;

create or replace function public.admin_thread(p_user uuid) returns json
language plpgsql security definer set search_path = public as $$
declare v json;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  select json_build_object('user_id', p.id, 'full_name', p.full_name, 'role', p.role, 'email', u.email,
    'messages', coalesce((select json_agg(json_build_object('id', m.id, 'from_admin', m.sender_id <> m.user_id, 'body', m.body,
        'created_at', m.created_at, 'broadcast', m.broadcast_id is not null) order by m.created_at)
      from public.inbox_messages m where m.user_id = p.id), '[]'::json))
  into v from public.profiles p join auth.users u on u.id = p.id where p.id = p_user;
  update public.inbox_messages set read_by_admin = true where user_id = p_user and not read_by_admin;
  return v;
end $$;

create or replace function public.admin_send(p_user uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text; v_first text; v_from text := public.admin_name();
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'Write a message first.'; end if;
  insert into public.inbox_messages (user_id, sender_id, body, read_by_user, read_by_admin)
  values (p_user, auth.uid(), left(trim(p_body), 5000), false, true);
  select u.email, coalesce(nullif(split_part(trim(p.full_name), ' ', 1), ''), 'there') into v_email, v_first
  from auth.users u join public.profiles p on p.id = u.id where u.id = p_user;
  perform public.send_padelent_email(v_email,
    'New message from ' || v_from || ' at Padelent',
    'Hi ' || v_first || ',',
    array[left(trim(p_body), 1500), '— ' || v_from || ', Padelent'],
    'Reply in the app', 'https://padelent.com/app/#/inbox');
end $$;

revoke execute on function public.inbox_unread(), public.my_inbox(), public.send_inbox_message(text),
  public.admin_broadcast(text, text), public.admin_conversations(), public.admin_thread(uuid), public.admin_send(uuid, text),
  public.admin_name() from public, anon;
grant execute on function public.inbox_unread(), public.my_inbox(), public.send_inbox_message(text),
  public.admin_broadcast(text, text), public.admin_conversations(), public.admin_thread(uuid), public.admin_send(uuid, text),
  public.admin_name() to authenticated;
