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

-- ---------- Coaches: getting paid ---------------------------------------------

-- Refresh a coach's payout status from Stripe.
create or replace function public.refresh_coach_payouts(p_coach uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_acct text; a jsonb; v_ready boolean;
begin
  select stripe_account_id into v_acct from public.coaches where id = p_coach;
  if v_acct is null then return null; end if;
  a := public.stripe('GET', 'accounts/' || v_acct);
  v_ready := coalesce(a->'capabilities'->>'transfers', '') = 'active';
  update public.coaches set payouts_ready = v_ready where id = p_coach and payouts_ready is distinct from v_ready;
  return jsonb_build_object(
    'ready', v_ready,
    'details_submitted', coalesce((a->>'details_submitted')::boolean, false),
    'payouts_enabled', coalesce((a->>'payouts_enabled')::boolean, false),
    'due', coalesce(jsonb_array_length(a->'requirements'->'currently_due'), 0));
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
  if c.stripe_account_id is null then return jsonb_build_object('payments', true, 'has_account', false, 'ready', false); end if;
  st := public.refresh_coach_payouts(v_uid);
  return st || jsonb_build_object('payments', true, 'has_account', true);
end $$;

-- Coach: a Stripe link to set up (or finish setting up) payouts.
create or replace function public.coach_payout_link() returns text
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); c public.coaches; v_email text; a jsonb; l jsonb;
begin
  select * into c from public.coaches where id = v_uid;
  if c.id is null then raise exception 'Only coach accounts have payouts.'; end if;
  if c.stripe_account_id is null then
    select email into v_email from auth.users where id = v_uid;
    a := public.stripe('POST', 'accounts', jsonb_build_object(
      'type', 'express',
      'country', 'GB',
      'email', v_email,
      'business_type', 'individual',
      'capabilities[transfers][requested]', 'true',
      'business_profile[mcc]', '8299',
      'business_profile[product_description]', 'Online padel coaching: personal video lessons sold through Padelent.',
      'business_profile[url]', 'https://padelent.com/coach/' || v_uid,
      'metadata[padelent_coach]', v_uid::text), 'padelent-acct-' || v_uid);
    update public.coaches set stripe_account_id = a->>'id' where id = v_uid;
    c.stripe_account_id := a->>'id';
  end if;
  l := public.stripe('POST', 'account_links', jsonb_build_object(
    'account', c.stripe_account_id,
    'type', 'account_onboarding',
    'refresh_url', public.app_base() || '#/payouts',
    'return_url', public.app_base() || '#/payouts'));
  return l->>'url';
end $$;

-- Coach: open their Stripe Express dashboard (payouts, bank details).
create or replace function public.coach_dashboard_link() returns text
language plpgsql security definer set search_path = public as $$
declare v_acct text;
begin
  select stripe_account_id into v_acct from public.coaches where id = auth.uid();
  if v_acct is null then raise exception 'Set up payouts first.'; end if;
  return public.stripe('POST', 'accounts/' || v_acct || '/login_links')->>'url';
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
end $$;

revoke execute on function public.mark_lesson_paid(uuid, jsonb) from public, anon, authenticated;

-- Player: get the Stripe payment page for a lesson that is waiting for payment.
-- Returns null if it is already paid.
create or replace function public.lesson_checkout(p_lesson uuid) returns text
language plpgsql security definer set search_path = public as $$
declare l public.lessons; s jsonb; v_email text; v_coach text;
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
    'coach_id', l.coach_id, 'coach_name', (select full_name from public.profiles where id = l.coach_id), 'price_pence', l.price_pence);
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

-- Anyone: what can be booked with this coach right now?
create or replace function public.booking_options(p_coach uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'payments', public.payments_required(),
    'paid_ready', coalesce((select payouts_ready from public.coaches where id = p_coach), false),
    'free_available', public.free_lesson_available(p_coach))
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

revoke execute on function public.coach_payout_status(), public.coach_payout_link(), public.coach_dashboard_link(),
  public.lesson_checkout(uuid), public.confirm_lesson_payment(uuid), public.cancel_pending_lesson(uuid) from public, anon;
grant execute on function public.coach_payout_status(), public.coach_payout_link(), public.coach_dashboard_link(),
  public.lesson_checkout(uuid), public.confirm_lesson_payment(uuid), public.cancel_pending_lesson(uuid) to authenticated;
grant execute on function public.booking_options(uuid) to anon, authenticated;
