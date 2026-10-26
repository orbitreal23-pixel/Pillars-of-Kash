# Pillars of Kash: going live (about 30 minutes)

**Hosting:** Supabase (database + logins, free tier to start) and Cloudflare Pages (the website, free). Pick the nearest Supabase region (London or Frankfurt).

1. **Supabase:** create a project at supabase.com. SQL Editor > run, in this order, `schema.sql`, `02_loans_and_tools.sql`, then `04_withdrawals_reports.sql`.
2. **Auth settings:** Authentication > Providers > Email: turn OFF "Confirm email". Authentication > Policies: set minimum password length to 6.
3. **First Super Admin:** Authentication > Users > Add user: email `256772000000@pillars.local` (your phone as 256 + number, no zero), password = your 6-digit PIN, tick auto-confirm. Then in SQL Editor:
   ```sql
   insert into members(name,phone) values('Your Name','256772000000');
   insert into staff(user_id,member_id,name,role)
   select u.id,m.id,m.name,'admin' from auth.users u, members m
   where u.email='256772000000@pillars.local' and m.phone='256772000000';
   ```
4. **Edge function** (needed for Users & roles): install the Supabase CLI, then `supabase login`, `supabase link --project-ref YOUR-REF`, `supabase functions deploy admin-users`.
5. **Website:** edit `web/config.js` with your Project URL and anon key (Project Settings > API). In Cloudflare Pages create a project, upload the `web` folder, and open the address it gives you.
6. **Import your data:** in SQL Editor run `supabase/03_import_data.sql` (60 members, 178 payments, USh 890,000). Members have no phone numbers yet: use Members > Edit to add each phone, then give them a login in Users & roles. Run the import once only.
7. Sign in with your phone and PIN, add members, then give each one a login in Users & roles.

Security notes: all rules (roles, maker-checker, "members see only their own account") are enforced by the database, not the page. The anon key is meant to be public. Keep the service-role key secret and never put it in `web/`. Turn on daily backups (Supabase Pro) before real money is recorded.
