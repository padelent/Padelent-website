-- Padelent card payments with Stripe Connect.
-- Run this in the Supabase SQL Editor after app-schema.sql. Safe to run again.
--
-- How the money moves:
--   1. A player books a paid lesson and pays Padelent on a Stripe payment page.
--   2. The lesson goes to the coach once the payment is confirmed.
--   3. When the coach replies (lesson Done), the coach's share (price minus Padelent's 20%)
--      is sent to their Stripe account. Stripe pays it into their bank automatically.
--   4. If a coach never replies, refund the player in the Stripe dashboard. The coach is not paid.
--
-- The Stripe secret key lives in the vault, never in this file:
--   select vault.create_secret('sk_test_...', 'stripe_secret_key');
-- Card payments switch on in the app as soon as that key is saved.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ---------- Talking to Stripe ---------------------------------------------

create or replace function public.app_base() returns text
language sql immutable as $$ select 'https://padelent.com/app/' $$;

-- Percent-encode text for a Stripe form body.
create or replace function public.form_enc(t text) returns text
language plpgsql immutable as $$
declare b bytea := convert_to(coalesce(t, ''), 'UTF8'); o text := ''; c int;
begin
  for i in 0 .. length(b) - 1 loop
    c := get_byte(b, i);
    if c between 48 and 57 or c between 65 and 90 or c between 97 and 122 or c in (45, 46, 95, 126) then
      o := o || chr(c);
    else
      o := o || '%' || upper(lpad(to_hex(c), 2, '0'));
    end if;
  end loop;
  return o;
end $$;

-- One call to the Stripe API. Params are a flat object, e.g. {"metadata[lesson_id]": "..."}.
create or replace function public.stripe(p_method text, p_path text, p_params jsonb default '{}', p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; v_body text := ''; k text; v text; v_url text; h extensions.http_header[]; r extensions.http_response; j jsonb;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'stripe_secret_key' limit 1;
  if v_key is null then raise exception 'Card payments are not set up yet.'; end if;
  for k, v in select key, value from jsonb_each_text(coalesce(p_params, '{}')) order by key loop
    v_body := v_body || case when v_body = '' then '' else '&' end || public.form_enc(k) || '=' || public.form_enc(v);
  end loop;
  v_url := 'https://api.stripe.com/v1/' || p_path;
  h := array[row('Authorization', 'Bearer ' || v_key)::extensions.http_header];
  if p_idem is not null then h := h || row('Idempotency-Key', p_idem)::extensions.http_header; end if;
  if p_method = 'GET' then
    if v_body <> '' then v_url := v_url || '?' || v_body; end if;
    r := extensions.http(row('GET', v_url, h, null, null)::extensions.http_request);
  else
    r := extensions.http(row(p_method, v_url, h, 'application/x-www-form-urlencoded', v_body)::extensions.http_request);
  end if;
  begin j := r.content::jsonb; exception when others then j := '{}'::jsonb; end;
  if r.status >= 400 then
    raise exception 'Payment problem: %', coalesce(j->'error'->>'message', 'Stripe error ' || r.status);
  end if;
  return j;
end $$;

revoke execute on function public.stripe(text, text, jsonb, text) from public, anon, authenticated;

-- Stripe's newer v2 API (JSON). Used for coach accounts.
create or replace function public.stripe_v2(p_method text, p_path text, p_body jsonb default null, p_idem text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_key text; h extensions.http_header[]; r extensions.http_response; j jsonb;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'stripe_secret_key' limit 1;
  if v_key is null then raise exception 'Card payments are not set up yet.'; end if;
  h := array[row('Authorization', 'Bearer ' || v_key)::extensions.http_header,
             row('Stripe-Version', '2026-10-28.endive')::extensions.http_header];
  if p_idem is not null then h := h || row('Idempotency-Key', p_idem)::extensions.http_header; end if;
  r := extensions.http(row(p_method, 'https://api.stripe.com/v2/' || p_path, h,
         case when p_method = 'GET' then null else 'application/json' end,
         case when p_method = 'GET' then null else coalesce(p_body, '{}'::jsonb)::text end)::extensions.http_request);
  begin j := r.content::jsonb; exception when others then j := '{}'::jsonb; end;
  if r.status >= 400 then
    raise exception 'Payment problem: %', coalesce(j->'error'->>'message', 'Stripe error ' || r.status);
  end if;
  return j;
end $$;

revoke execute on function public.stripe_v2(text, text, jsonb, text) from public, anon, authenticated;

-- ---------- Coaches: getting paid ---------------------------------------------

-- Refresh a coach's payout status from Stripe.
create or replace function public.refresh_coach_payouts(p_coach uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_acct text; a jsonb; v_ready boolean;
begin
  select stripe_account_id into v_acct from public.coaches where id = p_coach;
  if v_acct is null then return null; end if;
  a := public.stripe_v2('GET', 'core/accounts/' || v_acct || '?include=configuration.recipient');
  v_ready := coalesce(a#>>'{configuration,recipient,capabilities,stripe_balance,stripe_transfers,status}', '') = 'active';
  update public.coaches set payouts_ready = v_ready where id = p_coach and payouts_ready is distinct from v_ready;
  return jsonb_build_object(
    'ready', v_ready,
    'details_submitted', v_ready or coalesce(a#>>'{configuration,recipient,capabilities,stripe_balance,stripe_transfers,status_details,0,code}', '') = 'requirements_pending_verification',
    'payouts_enabled', v_ready,
    'due', coalesce(jsonb_array_length(a->'requirements'->'entries'), 0));
end $$;

revoke execute on function public.refresh_coach_payouts(uuid) from public, anon, authenticated;

-- Coach: where am I with payouts?
create or replace function public.coach_payout_status() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); c public.coaches; st jsonb;
begin
  select * into c from public.coaches where id = v_uid;
  if c.id is null then raise exception 'Only coach accounts have payouts.'; end if;
  if not public.payments_required() then return jsonb_build_object('payments', false); end if;
  if c.stripe_account_id is null then return jsonb_build_object('payments', true, 'has_account', false, 'ready', false, 'country', c.payout_country); end if;
  st := public.refresh_coach_payouts(v_uid);
  return st || jsonb_build_object('payments', true, 'has_account', true, 'country', coalesce(c.payout_country, 'GB'));
end $$;

-- Coach: a Stripe link to set up (or finish setting up) payouts.
-- The country each coach's Stripe account is set up in (Stripe cannot change it later).
alter table public.coaches add column if not exists payout_country text;

drop function if exists public.coach_payout_link();
create or replace function public.coach_payout_link(p_country text default null) returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); c public.coaches; v_email text; a jsonb; l jsonb; v_country text;
begin
  select * into c from public.coaches where id = v_uid;
  if c.id is null then raise exception 'Only coach accounts have payouts.'; end if;
  v_country := upper(coalesce(nullif(trim(p_country), ''), c.payout_country, 'GB'));
  if v_country !~ '^[A-Z]{2}$' then raise exception 'Pick the country you live in.'; end if;
  -- Picked a different country before finishing setup: start a fresh Stripe account in that country.
  if c.stripe_account_id is not null and not c.payouts_ready and v_country <> coalesce(c.payout_country, 'GB') then
    update public.coaches set stripe_account_id = null where id = v_uid;
    c.stripe_account_id := null;
  end if;
  if c.stripe_account_id is null then
    select email into v_email from auth.users where id = v_uid;
    a := public.stripe_v2('POST', 'core/accounts', jsonb_build_object(
      'contact_email', v_email,
      'display_name', coalesce(nullif((select full_name from public.profiles where id = v_uid), ''), 'Padelent coach'),
      'identity', jsonb_build_object('country', v_country, 'entity_type', 'individual'),
      'dashboard', 'express',
      'defaults', jsonb_build_object('responsibilities', jsonb_build_object('fees_collector', 'application', 'losses_collector', 'application')),
      'configuration', jsonb_build_object('recipient', jsonb_build_object('capabilities', jsonb_build_object(
        'stripe_balance', jsonb_build_object('stripe_transfers', jsonb_build_object('requested', true))))),
      'metadata', jsonb_build_object('padelent_coach', v_uid::text)), 'padelent-acct6-' || v_uid || '-' || v_country);
    update public.coaches set stripe_account_id = a->>'id', payout_country = v_country where id = v_uid;
    c.stripe_account_id := a->>'id';
  end if;
  l := public.stripe_v2('POST', 'core/account_links', jsonb_build_object(
    'account', c.stripe_account_id,
    'use_case', jsonb_build_object('type', 'account_onboarding', 'account_onboarding', jsonb_build_object(
      'refresh_url', public.app_base() || '#/payouts',
      'return_url', public.app_base() || '#/payouts',
      'collection_options', jsonb_build_object('fields', 'eventually_due')))));
  return l->>'url';
end $$;

-- Coach: open their Stripe Express dashboard (payouts, bank details).
create or replace function public.coach_dashboard_link() returns text
language plpgsql security definer set search_path = public as $$
declare v_acct text;
begin
  select stripe_account_id into v_acct from public.coaches where id = auth.uid();
  if v_acct is null then raise exception 'Set up payouts first.'; end if;
  begin
    return public.stripe('POST', 'accounts/' || v_acct || '/login_links')->>'url';
  exception when others then
    return 'https://connect.stripe.com/express_login';
  end;
end $$;

-- ---------- Players: paying for a lesson ---------------------------------------------

-- Internal: a lesson's payment has arrived. The coach now sees it.
create or replace function public.mark_lesson_paid(p_lesson uuid, p_session jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare l public.lessons;
begin
  select * into l from public.lessons where id = p_lesson for update;
  if l.id is null or l.status <> 'pending_payment' then return; end if;
  update public.lessons set closed_at = now(), needs_coach = false
  where player_id = l.player_id and coach_id = l.coach_id and status = 'done' and closed_at is null;
  update public.lessons set
    status = 'new', paid = true,
    payment_intent = coalesce(p_session->'payment_intent'->>'id', p_session->>'payment_intent'),
    charge_id = p_session->'payment_intent'->>'latest_charge'
  where id = p_lesson;
  -- First lesson of a monthly plan: the plan starts now.
  if p_session->>'mode' = 'subscription' and l.subscription_id is not null then
    update public.subscriptions set status = 'active', checked_at = null,
      stripe_subscription_id = coalesce(p_session->'subscription'->>'id', p_session->>'subscription'),
      stripe_customer_id = coalesce(p_session->'customer'->>'id', p_session->>'customer')
    where id = l.subscription_id and status = 'pending';
  end if;
end $$;

revoke execute on function public.mark_lesson_paid(uuid, jsonb) from public, anon, authenticated;

-- Player: get the Stripe payment page for a lesson that is waiting for payment.
-- Returns null if it is already paid.
create or replace function public.lesson_checkout(p_lesson uuid) returns text
language plpgsql security definer set search_path = public as $$
declare l public.lessons; s jsonb; v_email text; v_coach text; c public.coaches; v_sub uuid;
begin
  select * into l from public.lessons where id = p_lesson and player_id = auth.uid();
  if l.id is null then raise exception 'Lesson not found.'; end if;
  if l.status <> 'pending_payment' then return null; end if;
  if l.stripe_session_id is not null then
    s := public.stripe('GET', 'checkout/sessions/' || l.stripe_session_id, '{"expand[]": "payment_intent"}');
    if s->>'payment_status' = 'paid' then perform public.mark_lesson_paid(l.id, s); return null; end if;
    if s->>'status' = 'open' then return s->>'url'; end if;
  end if;
  select email into v_email from auth.users where id = l.player_id;
  select full_name into v_coach from public.profiles where id = l.coach_id;

  if l.kind = 'monthly' then
    -- Start a monthly plan; this lesson is the first one in it.
    select * into c from public.coaches where id = l.coach_id;
    if not c.offers_monthly or c.monthly_price_pence is null or not c.payouts_ready then
      raise exception 'This coach is not taking monthly plans right now.';
    end if;
    if exists (select 1 from public.subscriptions where player_id = l.player_id and coach_id = l.coach_id and status in ('active', 'past_due')) then
      raise exception 'You already have a monthly plan with this coach.';
    end if;
    insert into public.subscriptions (player_id, coach_id, price_pence, videos_per_week)
    values (l.player_id, l.coach_id, c.monthly_price_pence, c.monthly_videos_per_week) returning id into v_sub;
    s := public.stripe('POST', 'checkout/sessions', jsonb_build_object(
      'mode', 'subscription',
      'client_reference_id', l.id::text,
      'customer_email', v_email,
      'line_items[0][quantity]', '1',
      'line_items[0][price_data][currency]', 'gbp',
      'line_items[0][price_data][unit_amount]', c.monthly_price_pence::text,
      'line_items[0][price_data][recurring][interval]', 'month',
      'line_items[0][price_data][product_data][name]', 'Monthly padel coaching with ' || coalesce(nullif(v_coach, ''), 'your coach'),
      'line_items[0][price_data][product_data][description]',
        'Up to ' || c.monthly_videos_per_week || ' video lesson' || case when c.monthly_videos_per_week = 1 then '' else 's' end || ' a week. Cancel any time.',
      'subscription_data[metadata][padelent_subscription]', v_sub::text,
      'subscription_data[metadata][coach_id]', l.coach_id::text,
      'metadata[lesson_id]', l.id::text,
      'metadata[subscription_id]', v_sub::text,
      'success_url', public.app_base() || '#/paid/' || l.id,
      'cancel_url', public.app_base() || '#/paid/' || l.id || '?cancelled=1'), 'padelent-sub-' || l.id || '-' || v_sub);
    update public.subscriptions set stripe_session_id = s->>'id' where id = v_sub;
    update public.lessons set stripe_session_id = s->>'id', subscription_id = v_sub where id = l.id;
    return s->>'url';
  end if;

  s := public.stripe('POST', 'checkout/sessions', jsonb_build_object(
    'mode', 'payment',
    'client_reference_id', l.id::text,
    'customer_email', v_email,
    'line_items[0][quantity]', '1',
    'line_items[0][price_data][currency]', 'gbp',
    'line_items[0][price_data][unit_amount]', l.price_pence::text,
    'line_items[0][price_data][product_data][name]', 'Padel video lesson with ' || coalesce(nullif(v_coach, ''), 'your coach'),
    'line_items[0][price_data][product_data][description]', l.topic,
    'payment_intent_data[transfer_group]', l.id::text,
    'payment_intent_data[description]', 'Padelent lesson: ' || left(l.topic, 100),
    'payment_intent_data[metadata][lesson_id]', l.id::text,
    'metadata[lesson_id]', l.id::text,
    'success_url', public.app_base() || '#/paid/' || l.id,
    'cancel_url', public.app_base() || '#/paid/' || l.id || '?cancelled=1'));
  update public.lessons set stripe_session_id = s->>'id' where id = l.id;
  return s->>'url';
end $$;

-- Player: back from the payment page. Has it gone through?
create or replace function public.confirm_lesson_payment(p_lesson uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.lessons; s jsonb;
begin
  select * into l from public.lessons where id = p_lesson and player_id = auth.uid();
  if l.id is null then return jsonb_build_object('status', 'missing'); end if;
  if l.status = 'pending_payment' and l.stripe_session_id is not null then
    s := public.stripe('GET', 'checkout/sessions/' || l.stripe_session_id, '{"expand[]": "payment_intent"}');
    if s->>'payment_status' = 'paid' then perform public.mark_lesson_paid(l.id, s); end if;
    select * into l from public.lessons where id = p_lesson;
  end if;
  return jsonb_build_object('status', case when l.status = 'pending_payment' then 'unpaid' else 'paid' end,
    'coach_id', l.coach_id, 'coach_name', (select full_name from public.profiles where id = l.coach_id), 'price_pence', l.price_pence,
    'kind', l.kind, 'plan_price_pence', (select price_pence from public.subscriptions where id = l.subscription_id));
end $$;

-- Player: changed their mind before paying.
create or replace function public.cancel_pending_lesson(p_lesson uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_coach uuid;
begin
  delete from public.lessons where id = p_lesson and player_id = auth.uid() and status = 'pending_payment'
  returning coach_id into v_coach;
  return v_coach;
end $$;

-- ---------- Monthly plans ---------------------------------------------

-- Player: my monthly plan with this coach (null if none).
create or replace function public.my_plan(p_coach uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', s.id, 'status', s.status, 'price_pence', s.price_pence, 'videos_per_week', s.videos_per_week,
    'renews_at', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
    'used', (select count(*) from public.lessons l where l.player_id = s.player_id and l.coach_id = s.coach_id
               and l.kind = 'monthly' and l.status <> 'pending_payment' and l.created_at > now() - interval '7 days'),
    'next_open', (select min(l.created_at) + interval '7 days' from public.lessons l where l.player_id = s.player_id and l.coach_id = s.coach_id
               and l.kind = 'monthly' and l.status <> 'pending_payment' and l.created_at > now() - interval '7 days'))
  from public.subscriptions s
  where s.player_id = auth.uid() and s.coach_id = p_coach and s.status in ('active', 'past_due')
  order by s.created_at desc limit 1
$$;

-- Internal: refresh one plan from Stripe and pay the coach their share of any new monthly payment.
create or replace function public.sync_subscription(p_sub uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.subscriptions; st jsonb; ch jsonb; c jsonb; v_status text; v_end text; v_acct text; v_share int; t jsonb;
begin
  select * into v from public.subscriptions where id = p_sub;
  if v.id is null or v.stripe_subscription_id is null then return; end if;
  st := public.stripe('GET', 'subscriptions/' || v.stripe_subscription_id);
  v_status := case st->>'status' when 'active' then 'active' when 'trialing' then 'active'
                when 'past_due' then 'past_due' when 'unpaid' then 'past_due' when 'incomplete' then 'past_due'
                else 'cancelled' end;
  v_end := coalesce(st->>'current_period_end', st#>>'{items,data,0,current_period_end}');
  update public.subscriptions set status = v_status,
    current_period_end = case when v_end ~ '^[0-9]+$' then to_timestamp(v_end::bigint) else current_period_end end,
    cancel_at_period_end = coalesce((st->>'cancel_at_period_end')::boolean, false),
    cancelled_at = case when v_status = 'cancelled' then coalesce(cancelled_at, now()) end,
    checked_at = now()
  where id = p_sub;

  if v.stripe_customer_id is null then return; end if;
  select stripe_account_id into v_acct from public.coaches where id = v.coach_id;
  ch := public.stripe('GET', 'charges', jsonb_build_object('customer', v.stripe_customer_id, 'limit', '20'));
  for c in select value from jsonb_array_elements(coalesce(ch->'data', '[]'::jsonb)) loop
    continue when c->>'status' <> 'succeeded' or not coalesce((c->>'paid')::boolean, false);
    continue when exists (select 1 from public.subscription_payments where charge_id = c->>'id' and (transfer_id is not null or refunded));
    v_share := round((c->>'amount')::int * (100 - public.platform_fee_percent()) / 100.0);
    if coalesce((c->>'amount_refunded')::int, 0) > 0 then
      insert into public.subscription_payments (charge_id, subscription_id, coach_id, player_id, amount_pence, coach_share_pence, refunded)
      values (c->>'id', v.id, v.coach_id, v.player_id, (c->>'amount')::int, v_share, true)
      on conflict (charge_id) do update set refunded = true;
      continue;
    end if;
    begin
      if v_acct is null then raise exception 'Coach has no payout account.'; end if;
      t := public.stripe('POST', 'transfers', jsonb_build_object(
        'amount', v_share::text, 'currency', 'gbp', 'destination', v_acct,
        'source_transaction', c->>'id', 'transfer_group', 'plan-' || v.id,
        'description', 'Padelent monthly plan', 'metadata[subscription_id]', v.id::text), 'padelent-planpay-' || (c->>'id'));
      insert into public.subscription_payments (charge_id, subscription_id, coach_id, player_id, amount_pence, coach_share_pence, transfer_id)
      values (c->>'id', v.id, v.coach_id, v.player_id, (c->>'amount')::int, v_share, t->>'id')
      on conflict (charge_id) do update set transfer_id = excluded.transfer_id, transfer_error = null;
    exception when others then
      insert into public.subscription_payments (charge_id, subscription_id, coach_id, player_id, amount_pence, coach_share_pence, transfer_error)
      values (c->>'id', v.id, v.coach_id, v.player_id, (c->>'amount')::int, v_share, left(sqlerrm, 300))
      on conflict (charge_id) do update set transfer_error = excluded.transfer_error;
    end;
  end loop;
end $$;

revoke execute on function public.sync_subscription(uuid) from public, anon, authenticated;

-- Player: cancel at the end of the month already paid for (or undo that).
create or replace function public.set_plan_cancel(p_sub uuid, p_cancel boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v public.subscriptions;
begin
  select * into v from public.subscriptions where id = p_sub and player_id = auth.uid() and status in ('active', 'past_due');
  if v.id is null then raise exception 'Plan not found.'; end if;
  perform public.stripe('POST', 'subscriptions/' || v.stripe_subscription_id,
    jsonb_build_object('cancel_at_period_end', case when p_cancel then 'true' else 'false' end));
  perform public.sync_subscription(v.id);
  return public.my_plan(v.coach_id);
end $$;

-- Coach: monthly plan members and payments, for the Earnings page.
create or replace function public.coach_plans() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('player_name', p.full_name, 'status', s.status, 'price_pence', s.price_pence,
        'videos_per_week', s.videos_per_week, 'renews_at', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end, 'since', s.created_at)
        order by s.created_at desc)
      from public.subscriptions s join public.profiles p on p.id = s.player_id
      where s.coach_id = auth.uid() and s.status in ('active', 'past_due')), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('player_name', p.full_name, 'created_at', sp.created_at,
        'amount_pence', sp.amount_pence, 'share_pence', sp.coach_share_pence, 'paid_out', sp.transfer_id is not null) order by sp.created_at desc)
      from public.subscription_payments sp left join public.profiles p on p.id = sp.player_id
      where sp.coach_id = auth.uid() and not sp.refunded), '[]'::jsonb))
$$;

-- Anyone: what can be booked with this coach right now?
create or replace function public.booking_options(p_coach uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'payments', public.payments_required(),
    'paid_ready', coalesce((select payouts_ready from public.coaches where id = p_coach), false),
    'free_available', public.free_lesson_available(p_coach),
    'plan', public.my_plan(p_coach))
$$;

-- ---------- Every 5 minutes: confirm payments, pay coaches ---------------------------------------------

create or replace function public.payments_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare l record; s jsonb; ch jsonb; t jsonb; c record;
begin
  if not public.payments_required() then return; end if;

  -- Payments where the player closed the page before coming back to the app.
  for l in select id, stripe_session_id from public.lessons
           where status = 'pending_payment' and stripe_session_id is not null and created_at > now() - interval '3 days' loop
    begin
      s := public.stripe('GET', 'checkout/sessions/' || l.stripe_session_id, '{"expand[]": "payment_intent"}');
      if s->>'payment_status' = 'paid' then perform public.mark_lesson_paid(l.id, s); end if;
    exception when others then null;
    end;
  end loop;
  -- Bookings never paid for.
  delete from public.lessons where status = 'pending_payment' and created_at < now() - interval '3 days';

  -- Coaches who finished Stripe setup but did not come back to the app.
  for c in select id from public.coaches where stripe_account_id is not null and not payouts_ready loop
    begin perform public.refresh_coach_payouts(c.id); exception when others then null; end;
  end loop;

  -- Pay the coach for lessons they have replied to.
  for l in select ls.id, ls.charge_id, ls.topic, ls.price_pence - ls.platform_fee_pence as share, co.stripe_account_id as acct
           from public.lessons ls join public.coaches co on co.id = ls.coach_id
           where ls.status = 'done' and ls.paid and ls.transfer_id is null and ls.refunded_at is null
             and ls.charge_id is not null and ls.price_pence > ls.platform_fee_pence and co.stripe_account_id is not null loop
    begin
      ch := public.stripe('GET', 'charges/' || l.charge_id);
      if coalesce((ch->>'amount_refunded')::int, 0) > 0 then
        update public.lessons set refunded_at = now(), closed_at = coalesce(closed_at, now()) where id = l.id;
      else
        t := public.stripe('POST', 'transfers', jsonb_build_object(
          'amount', l.share::text,
          'currency', 'gbp',
          'destination', l.acct,
          'source_transaction', l.charge_id,
          'transfer_group', l.id::text,
          'description', 'Padelent lesson: ' || left(l.topic, 100),
          'metadata[lesson_id]', l.id::text), 'padelent-transfer-' || l.id);
        update public.lessons set transfer_id = t->>'id', transferred_at = now(), transfer_error = null where id = l.id;
      end if;
    exception when others then
      update public.lessons set transfer_error = left(sqlerrm, 300) where id = l.id;
    end;
  end loop;

  -- Monthly plans: check each one every 30 minutes; pay coaches for new monthly payments.
  for l in select id from public.subscriptions
           where status in ('active', 'past_due') and stripe_subscription_id is not null
             and (checked_at is null or checked_at < now() - interval '30 minutes') loop
    begin perform public.sync_subscription(l.id);
    exception when others then update public.subscriptions set checked_at = now() where id = l.id;
    end;
  end loop;
  delete from public.subscriptions s where s.status = 'pending' and s.created_at < now() - interval '3 days'
    and not exists (select 1 from public.lessons x where x.subscription_id = s.id and x.status <> 'pending_payment');

  -- Refunds made in the Stripe dashboard before the coach replied: close the lesson.
  for l in select id, charge_id from public.lessons
           where status in ('new', 'awaiting') and paid and refunded_at is null and charge_id is not null
             and created_at < now() - interval '6 days' loop
    begin
      ch := public.stripe('GET', 'charges/' || l.charge_id);
      if coalesce((ch->>'amount_refunded')::int, 0) > 0 then
        update public.lessons set refunded_at = now(), closed_at = coalesce(closed_at, now()) where id = l.id;
      end if;
    exception when others then null;
    end;
  end loop;
end $$;

revoke execute on function public.payments_sweep() from public, anon, authenticated;

select cron.schedule('padelent-payments', '*/5 * * * *', 'select public.payments_sweep()');

-- ---------- Who can call what ---------------------------------------------

revoke execute on function public.coach_payout_status(), public.coach_payout_link(text), public.coach_dashboard_link(),
  public.lesson_checkout(uuid), public.confirm_lesson_payment(uuid), public.cancel_pending_lesson(uuid),
  public.set_plan_cancel(uuid, boolean), public.coach_plans() from public, anon;
grant execute on function public.coach_payout_status(), public.coach_payout_link(text), public.coach_dashboard_link(),
  public.lesson_checkout(uuid), public.confirm_lesson_payment(uuid), public.cancel_pending_lesson(uuid),
  public.set_plan_cancel(uuid, boolean), public.coach_plans() to authenticated;
grant execute on function public.my_plan(uuid) to anon, authenticated;
grant execute on function public.booking_options(uuid) to anon, authenticated;
