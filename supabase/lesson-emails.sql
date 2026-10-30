-- =====================================================================
-- Padelent: emails that tell people when something happens.
--   * Coach: "You have a new lesson" and "Player added to their lesson"
--   * Player: "Your lesson is ready" and "Your coach sent you a message"
--   * Coach: "You are live on Padelent" when you approve them
--   * You (info@padelent.com): "New coach waiting for approval"
-- Uses the same Resend key as the welcome email (vault secret 'resend_api_key').
-- Paste ALL of this into Supabase > SQL Editor > New query and press Run.
-- Safe to run again.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.html_esc(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

create or replace function public.first_name_of(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(split_part(trim(full_name), ' ', 1), ''), 'there') from public.profiles where id = p_id
$$;

-- One branded email. p_lines are plain-text paragraphs (they are escaped here).
create or replace function public.send_padelent_email(
  p_to text, p_subject text, p_heading text, p_lines text[], p_button text, p_url text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_key text; v_paras text := ''; v_text text := ''; l text;
begin
  if p_to is null or p_to = '' then return; end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null then return; end if;

  foreach l in array coalesce(p_lines, '{}') loop
    v_paras := v_paras || '<p style="margin:0 0 14px;font-size:16px;line-height:1.55;color:#D5DEE6;white-space:pre-line;">' || public.html_esc(l) || '</p>';
    v_text := v_text || l || chr(10) || chr(10);
  end loop;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Padelent <info@padelent.com>',
      'to', jsonb_build_array(p_to),
      'reply_to', 'info@padelent.com',
      'subject', p_subject,
      'text', p_heading || chr(10) || chr(10) || v_text || p_button || ': ' || p_url,
      'html',
'<!doctype html><html><body style="margin:0;padding:0;background:#0A1420;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0A1420;"><tr><td align="center" style="padding:28px 12px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;font-family:Helvetica,Arial,sans-serif;color:#FFFFFF;">
<tr><td style="padding:0 8px 22px;">
  <img src="cid:padelent-logo" width="34" height="34" alt="" style="vertical-align:middle;border:0;border-radius:8px;"> <span style="font-size:26px;font-weight:800;letter-spacing:-0.5px;color:#FFFFFF;vertical-align:middle;">Padelent</span>
</td></tr>
<tr><td style="background:#1B2530;border-radius:18px;padding:30px 28px;">
  <h1 style="margin:0 0 14px;font-size:26px;line-height:1.2;color:#FFFFFF;">' || public.html_esc(p_heading) || '</h1>
  ' || v_paras || '
  <a href="' || public.html_esc(p_url) || '" style="display:inline-block;margin-top:8px;background:#D7F23A;color:#0A1420;font-weight:700;font-size:16px;text-decoration:none;padding:14px 28px;border-radius:999px;">' || public.html_esc(p_button) || '</a>
</td></tr>
<tr><td style="padding:22px 8px 0;font-size:13px;line-height:1.5;color:#A9B8C6;text-align:center;">
  Padel plus talent · Questions? Reply to this email or write to <a href="mailto:info@padelent.com" style="color:#D7F23A;">info@padelent.com</a>
</td></tr>
</table></td></tr></table></body></html>',
      'attachments', jsonb_build_array(jsonb_build_object(
        'path', 'https://padelent.com/app/icon-180.png', 'filename', 'padelent-logo.png', 'content_id', 'padelent-logo'))
    ));
exception when others then
  return;  -- an email problem must never break the app
end $$;

revoke execute on function public.send_padelent_email(text, text, text, text[], text, text) from public, anon, authenticated;
revoke execute on function public.first_name_of(uuid) from public, anon, authenticated;

-- ---------- Lessons: new lesson for the coach, finished lesson for the player ----------

create or replace function public.lesson_status_emails() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_coach_email text; v_player_email text; v_first_msg text; v_player text; v_coach text;
begin
  v_player := public.first_name_of(new.player_id);
  v_coach := public.first_name_of(new.coach_id);

  if new.status = 'new' and (tg_op = 'INSERT' or old.status = 'pending_payment') then
    select email into v_coach_email from auth.users where id = new.coach_id;
    select left(body, 300) into v_first_msg from public.messages where lesson_id = new.id order by created_at limit 1;
    perform public.send_padelent_email(v_coach_email,
      'New lesson from ' || v_player || ': ' || left(new.topic, 60),
      'You have a new lesson',
      array_remove(array[
        v_player || ' has sent you a lesson: "' || new.topic || '"',
        case when coalesce(v_first_msg, '') <> '' then '"' || v_first_msg || '"' end,
        'Open it to watch their clips and send back your video reply, whenever suits you.'], null),
      'Open the lesson', 'https://padelent.com/app/#/space/' || new.player_id);
  end if;

  if tg_op = 'UPDATE' and new.status = 'done' and old.status <> 'done' then
    select email into v_player_email from auth.users where id = new.player_id;
    perform public.send_padelent_email(v_player_email,
      v_coach || ' has replied to your lesson',
      'Your lesson is ready',
      array[v_coach || ' has sent back your lesson on "' || new.topic || '".',
            'Watch the reply, try the drills, and let other players know how it went with a quick review.'],
      'Watch your lesson', 'https://padelent.com/app/#/space/' || new.coach_id);
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists lesson_status_emails on public.lessons;
-- Runs at the end of the transaction so the player's first message is already saved.
create constraint trigger lesson_status_emails after insert or update of status on public.lessons
  deferrable initially deferred
  for each row execute function public.lesson_status_emails();

-- ---------- Messages inside an open lesson ----------
-- The first message of a lesson is the booking itself (covered above), and a coach
-- reply that finishes the lesson is covered by "Your lesson is ready".

create or replace function public.message_emails() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.lessons; v_first boolean; v_to text; v_from text;
begin
  select * into l from public.lessons where id = new.lesson_id;
  if l.id is null or l.status = 'pending_payment' then return new; end if;
  select not exists (select 1 from public.messages m where m.lesson_id = new.lesson_id and m.id <> new.id and m.created_at <= new.created_at)
    into v_first;
  if v_first then return new; end if;

  v_from := public.first_name_of(new.sender_id);
  if new.sender_id = l.player_id then
    select email into v_to from auth.users where id = l.coach_id;
    perform public.send_padelent_email(v_to,
      v_from || ' added to their lesson',
      v_from || ' sent you more',
      array_remove(array['On the lesson "' || l.topic || '":',
        nullif(left(new.body, 300), ''),
        case when coalesce(array_length(new.videos, 1), 0) > 0
             then array_length(new.videos, 1) || ' new video' || case when array_length(new.videos, 1) > 1 then 's' else '' end || ' added.' end], null),
      'Open the lesson', 'https://padelent.com/app/#/space/' || l.player_id);
  end if;  -- coach messages are handled by coach_message_emails below
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists message_emails on public.messages;
create trigger message_emails after insert on public.messages
  for each row execute function public.message_emails();

-- Coach messages that keep the lesson open: checked at the end of the transaction,
-- so a "Send and mark done" reply sends only "Your lesson is ready".
create or replace function public.coach_message_emails() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.lessons; v_to text; v_from text;
begin
  select * into l from public.lessons where id = new.lesson_id;
  if l.id is null or new.sender_id <> l.coach_id or l.status = 'done' then return null; end if;
  v_from := public.first_name_of(l.coach_id);
  select email into v_to from auth.users where id = l.player_id;
  perform public.send_padelent_email(v_to,
    v_from || ' sent you a message',
    'New message from ' || v_from,
    array_remove(array['On your lesson "' || l.topic || '":', nullif(left(new.body, 300), '')], null),
    'Open the lesson', 'https://padelent.com/app/#/space/' || l.coach_id);
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists coach_message_emails on public.messages;
create constraint trigger coach_message_emails after insert on public.messages
  deferrable initially deferred
  for each row execute function public.coach_message_emails();

-- ---------- Coaches: tell you about new coaches, tell coaches when they are live ----------

create or replace function public.coach_emails() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_email text; v_name text;
begin
  select email into v_email from auth.users where id = new.id;
  select full_name into v_name from public.profiles where id = new.id;
  if tg_op = 'INSERT' then
    perform public.send_padelent_email('info@padelent.com',
      'New coach signed up: ' || coalesce(nullif(v_name, ''), v_email),
      'A new coach has joined',
      array[coalesce(nullif(v_name, ''), 'A coach') || ' (' || v_email || ') has created a coach account.',
            'Once their profile is filled in, approve them on the Admin tab so players can book them.'],
      'Open Admin', 'https://padelent.com/app/#/admin');
  elsif new.approved and not old.approved then
    perform public.send_padelent_email(v_email,
      'You are live on Padelent',
      'You are live, ' || public.first_name_of(new.id) || '!',
      array['Your coach profile has been approved. Players can now find you and send you lessons.',
            'When a lesson comes in we will email you straight away. Reply whenever suits you, from your phone or laptop.',
            'Tip: share your profile with your own players to get your first reviews.'],
      'See your profile', 'https://padelent.com/app/#/coach/' || new.id);
  end if;
  return new;
exception when others then
  return new;
end $$;

drop trigger if exists coach_emails on public.coaches;
create trigger coach_emails after insert or update of approved on public.coaches
  for each row execute function public.coach_emails();
