-- =====================================================================
-- Padelent: welcome email with the "get the app" guide, sent the moment
-- someone creates an account. Emails are sent through Resend.
--
-- Before running this, store your Resend API key once (replace re_xxx):
--   select vault.create_secret('re_xxx', 'resend_api_key');
-- Then paste ALL of this into Supabase > SQL Editor > New query and press Run.
-- Safe to run again.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.send_welcome_email() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  v_email text;
  v_first text;
  v_is_coach boolean := new.role = 'coach';
  v_intro text;
  v_html text;
  v_text text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'resend_api_key' limit 1;
  if v_key is null then return new; end if;
  select email into v_email from auth.users where id = new.id;
  if v_email is null then return new; end if;

  v_first := coalesce(nullif(split_part(trim(new.full_name), ' ', 1), ''), 'there');
  v_first := replace(replace(replace(v_first, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

  v_intro := case when v_is_coach then
    'Thanks for joining Padelent as a coach. Next, add a photo, a short intro about you, your price and your specialities. We check every coach before they go live and will email you as soon as players can find and book you.'
  else
    'You are all set. Pick a coach, send them a clip of your game and get a personal video lesson back. Add your level and court side on your profile so coaches can coach your game, not a generic one.'
  end;

  v_html :=
'<!doctype html><html><body style="margin:0;padding:0;background:#0A1420;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0A1420;"><tr><td align="center" style="padding:28px 12px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;font-family:Helvetica,Arial,sans-serif;color:#FFFFFF;">
<tr><td style="padding:0 8px 22px;">
  <img src="https://padelent.com/app/icon-180.png" width="34" height="34" alt="" style="vertical-align:middle;border:0;border-radius:8px;"> <span style="font-size:26px;font-weight:800;letter-spacing:-0.5px;color:#FFFFFF;vertical-align:middle;">Padelent</span>
  <span style="float:right;font-size:11px;font-weight:700;letter-spacing:2px;color:#D7F23A;line-height:32px;">PADEL PLUS TALENT</span>
</td></tr>
<tr><td style="background:#1B2530;border-radius:18px;padding:30px 28px;">
  <h1 style="margin:0 0 12px;font-size:28px;line-height:1.15;color:#FFFFFF;">Welcome to Padelent, ' || v_first || '!</h1>
  <p style="margin:0 0 22px;font-size:16px;line-height:1.55;color:#D5DEE6;">' || v_intro || '</p>
  <a href="https://padelent.com/app/" style="display:inline-block;background:#D7F23A;color:#0A1420;font-weight:700;font-size:16px;text-decoration:none;padding:14px 28px;border-radius:999px;">Open Padelent</a>
</td></tr>
<tr><td style="padding:30px 8px 10px;">
  <h2 style="margin:0 0 6px;font-size:21px;color:#FFFFFF;">Put Padelent on your phone</h2>
  <p style="margin:0 0 16px;font-size:15px;line-height:1.5;color:#A9B8C6;">Takes two minutes. Follow the steps below and it opens like any other app.</p>
  <img src="https://padelent.com/app/install-guide.jpg" width="584" alt="How to add Padelent to your iPhone home screen: open padelent.com/app in Safari, tap the three dots, Share, View More, Add to Home Screen, then Add." style="display:block;width:100%;max-width:584px;height:auto;border:0;border-radius:14px;">
</td></tr>
<tr><td style="padding:22px 8px 0;font-size:13px;line-height:1.5;color:#A9B8C6;text-align:center;">
  Questions? Just reply to this email or write to <a href="mailto:info@padelent.com" style="color:#D7F23A;">info@padelent.com</a>.<br>
  You are getting this because you created a Padelent account. <a href="https://padelent.com/privacy.html" style="color:#A9B8C6;">Privacy</a>
</td></tr>
</table></td></tr></table></body></html>';

  v_text := 'Welcome to Padelent, ' || v_first || '!' || chr(10) || chr(10) || v_intro || chr(10) || chr(10) ||
    'Open Padelent: https://padelent.com/app/' || chr(10) || chr(10) ||
    'Put it on your iPhone: open padelent.com/app in Safari, tap the three dots (bottom right), Share, View More, Add to Home Screen, then Add.' || chr(10) ||
    'On Android: open it in Chrome, tap the menu, then Add to Home screen.' || chr(10) || chr(10) ||
    'Questions? Reply to this email or write to info@padelent.com.';

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_key, 'Content-Type', 'application/json'),
    body := jsonb_build_object(
      'from', 'Padelent <info@padelent.com>',
      'to', jsonb_build_array(v_email),
      'reply_to', 'info@padelent.com',
      'subject', case when v_is_coach then 'Welcome to Padelent, coach' else 'Welcome to Padelent' end,
      'html', v_html,
      'text', v_text)
  );
  return new;
exception when others then
  -- An email problem must never stop someone signing up.
  return new;
end $$;

revoke execute on function public.send_welcome_email() from public, anon, authenticated;

drop trigger if exists send_welcome_email on public.profiles;
create trigger send_welcome_email after insert on public.profiles
  for each row execute function public.send_welcome_email();
