-- Padelent launch email to everyone on the waitlist (the "signups" table).
-- Run this whole file once in the Supabase SQL Editor. It only sets things up and sends nothing.
--
-- Then:
--   1. Send yourself a test of both versions:
--        select public.send_launch_email('you@example.com');
--   2. When you are happy, send it to everyone on the waitlist:
--        select public.send_launch_email();
--
-- Safe to run step 2 again: nobody gets it twice, and anyone who already has an account is skipped.

create table if not exists public.launch_emails_sent (
  email text primary key,
  sent_at timestamptz not null default now()
);
alter table public.launch_emails_sent enable row level security;
revoke all on public.launch_emails_sent from anon, authenticated;

create or replace function public.launch_email_json(p_to text, p_role text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from text := public.admin_name(); v_subject text; v_heading text; v_lines text[]; v_button text; v_url text;
        v_foot text := 'You are getting this because you joined the Padelent waitlist at padelent.com. Don''t want any more emails? Just reply "unsubscribe".';
begin
  if p_role = 'coach' then
    v_subject := 'Padelent is open for coaches';
    v_heading := 'Start coaching on Padelent';
    v_lines := array[
      'You told us you coach padel, so you are one of the first to hear: Padelent is open.',
      'Make your profile and set your own price. Players send you clips of their game, and you reply with a personal video lesson, from wherever you are, in your own time.',
      'You keep 80% of every lesson. Stripe pays it into your bank as soon as you reply.',
      'Sign up, add a photo, a short intro video and a bit about how you coach, and we will approve you. Then share your profile link with your own players.',
      'Any questions, just reply to this email. I read every one.' || chr(10) || v_from || ', founder of Padelent'];
    v_button := 'Create your coach profile';
    v_url := 'https://padelent.com/app/#/signup?role=coach';
  else
    v_subject := 'Padelent is open 🎾';
    v_heading := 'Padelent is live';
    v_lines := array[
      'You signed up to hear when Padelent opened. It is open today.',
      'Pick a coach, send a clip of your padel, and get a personal video lesson back with drills to practise. No court to book, no travelling.',
      'Lots of our coaches offer a free trial lesson, so your first one can cost nothing.',
      'It works on your phone. Open the link, make your free account, and add Padelent to your home screen so it opens like an app.',
      'See you on court.' || chr(10) || v_from || ', founder of Padelent'];
    v_button := 'Find a coach';
    v_url := 'https://padelent.com/app/#/signup';
  end if;
  return jsonb_build_object(
    'from', 'Padelent <info@padelent.com>',
    'to', jsonb_build_array(p_to),
    'reply_to', 'info@padelent.com',
    'subject', v_subject,
    'html', replace(public.padelent_email_html(v_heading, v_lines, v_button, v_url),
              'Padel plus talent · You can reply inside the app, or write to',
              'Padel plus talent · You are getting this because you joined the Padelent waitlist. Don''t want any more emails? Reply "unsubscribe", or write to'),
    'text', v_heading || chr(10) || chr(10) || array_to_string(v_lines, chr(10) || chr(10))
            || chr(10) || chr(10) || v_button || ': ' || v_url || chr(10) || chr(10) || v_foot);
end $$;

-- p_test_to given: send both versions to that address only (nothing is recorded).
-- No argument: send to everyone on the waitlist who has not had it and has no account yet.
create or replace function public.send_launch_email(p_test_to text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_emails jsonb; v_n int;
begin
  if p_test_to is not null then
    perform public.send_padelent_batch(jsonb_build_array(
      public.launch_email_json(p_test_to, 'player'),
      public.launch_email_json(p_test_to, 'coach')));
    return 'Test sent: the player and coach versions are on their way to ' || p_test_to;
  end if;

  with todo as (
    select s.email, s.role from public.signups s
    where not exists (select 1 from public.launch_emails_sent x where lower(x.email) = lower(s.email))
      and not exists (select 1 from auth.users u where lower(u.email) = lower(s.email))
  ), rec as (
    insert into public.launch_emails_sent (email) select email from todo on conflict do nothing returning email
  )
  select coalesce(jsonb_agg(public.launch_email_json(t.email, t.role)), '[]'::jsonb), count(*)
  into v_emails, v_n
  from todo t join rec r on r.email = t.email;

  perform public.send_padelent_batch(v_emails);
  return 'Launch email sent to ' || v_n || ' people on the waitlist.';
end $$;

revoke execute on function public.launch_email_json(text, text), public.send_launch_email(text) from public, anon, authenticated;
