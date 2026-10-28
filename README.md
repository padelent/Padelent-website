# Padelent website and app

padelent.com, hosted on Netlify from this repository (no build step).

- `index.html`, `privacy.html`, `favicon.svg`, `og-image.png`: the coming-soon site with the sign-up pop-up.
- `app/`: the Padelent app at padelent.com/app. Plain HTML, CSS and JavaScript that talk to Supabase directly.
  - `app/config.js`: Supabase URL, the publishable key, the Padelent share, and the payments switch.
- `supabase/setup.sql`: the waitlist `signups` table used by the coming-soon form.
- `supabase/app-schema.sql`: everything the app needs: tables, security rules, functions and the video storage buckets. Run it in the Supabase SQL Editor. It is safe to run again after changes.

## How the app is put together

- Accounts: Supabase Auth (email and password). Signing up as a player or coach creates the matching profile.
- Coaches are hidden until an admin approves them on `/app/#/admin`.
- Players book a coach, upload up to 3 clips (private `lesson-videos` bucket), and get one private space per coach with all their lessons.
- Lesson statuses: new, awaiting (coach opened it), done (coach replied). Players review each finished lesson.
- All writes go through database functions that check who is asking; players can only see their own lessons, and coaches only their own players.
- Payments: `paymentsEnabled` is false while testing, so lessons are free. Stripe Connect will be added next.

## Make yourself admin

After signing up in the app, run this in the Supabase SQL Editor with your email:

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'YOUR EMAIL');
```
