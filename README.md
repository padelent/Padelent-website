# Padelent website

The coming-soon site for padelent.com: the home page, a sign-up pop-up for players and coaches, and a privacy page.

- `index.html`, `privacy.html`, `favicon.svg`: the site, served as static files by Vercel.
- `supabase/setup.sql`: creates the `signups` table the sign-up form writes to. Run it once in the Supabase SQL Editor.

Sign-ups are saved through the Supabase Data API using the project's public anon key, which is set near the bottom of `index.html`. The table only allows the website to add rows; it cannot read them back.
