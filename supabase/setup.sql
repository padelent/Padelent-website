-- Padelent: list of people who sign up on padelent.com
-- Paste all of this into Supabase > SQL Editor > New query, then press Run.

create table if not exists public.signups (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  role text not null check (role in ('player', 'coach')),
  source text,
  created_at timestamptz not null default now()
);

-- Lock the table down: the website may add sign-ups, but nobody can read the list from the website.
alter table public.signups enable row level security;

drop policy if exists "Anyone can sign up" on public.signups;
create policy "Anyone can sign up"
  on public.signups
  for insert
  to anon
  with check (true);

grant insert on table public.signups to anon;
