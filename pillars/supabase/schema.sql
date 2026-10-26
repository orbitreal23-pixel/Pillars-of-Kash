-- Pillars of Kash: run once in Supabase > SQL Editor
create type app_role as enum ('admin','treasurer','secretary','auditor','member');
create table members(id uuid primary key default gen_random_uuid(), seq serial unique,
 acct text generated always as ('PKG-'||lpad(seq::text,4,'0')) stored,
 name text not null, phone text unique, nin text, dob date, gender text,
 joined date default current_date, status text not null default 'Active');
create table staff(user_id uuid primary key references auth.users on delete cascade,
 member_id uuid references members, name text not null, role app_role not null default 'member');
create table entries(id bigserial primary key, member_id uuid not null references members,
 kind text not null check (kind in ('pay','wd','rev')), month text, amt int not null, method text,
 paid_on date not null default current_date, status text not null default 'pend' check (status in ('pend','ok','rej')),
 made_by uuid references staff, checked_by uuid references staff, receipt text, reason text,
 created timestamptz not null default now());
create unique index one_pay_per_month on entries(member_id,month) where kind='pay' and status<>'rej';
create table audit(id bigserial primary key, at timestamptz not null default now(), who text, action text);
create sequence rct;

create function my_role() returns app_role language sql stable security definer set search_path=public as $$select role from staff where user_id=auth.uid()$$;
create function my_member() returns uuid language sql stable security definer set search_path=public as $$select member_id from staff where user_id=auth.uid()$$;
create function my_name() returns text language sql stable security definer set search_path=public as $$select name from staff where user_id=auth.uid()$$;
create function log_a(t text) returns void language sql security definer set search_path=public as $$insert into audit(who,action) values(coalesce(my_name(),'System'),t)$$;

alter table members enable row level security; alter table staff enable row level security;
alter table entries enable row level security; alter table audit enable row level security;
create policy r_members on members for select using (my_role() in ('admin','treasurer','secretary','auditor') or id=my_member());
create policy r_entries on entries for select using (my_role() in ('admin','treasurer','auditor') or member_id=my_member());
create policy r_staff on staff for select using (my_role()='admin' or user_id=auth.uid());
create policy r_audit on audit for select using (my_role() in ('admin','auditor'));
-- No insert/update/delete policies: all writes go through the functions below.

create function add_member(n text,p text,nin text,dob date,g text) returns members language plpgsql security definer set search_path=public as $$
declare m members; begin
 if coalesce(my_role()::text,'') not in ('admin','secretary') then raise exception 'Not allowed'; end if;
 insert into members(name,phone,nin,dob,gender) values(trim(n),p,nin,dob,g) returning * into m;
 perform log_a('Added member '||m.acct); return m; end$$;

create function record_payment(mid uuid,mon text,a int,meth text) returns void language plpgsql security definer set search_path=public as $$
begin
 if coalesce(my_role()::text,'') not in ('admin','treasurer') then raise exception 'Not allowed'; end if;
 if a<=0 then raise exception 'Invalid amount'; end if;
 insert into entries(member_id,kind,month,amt,method,made_by) values(mid,'pay',mon,a,meth,auth.uid());
 perform log_a('Recorded payment for '||(select acct from members where id=mid)||' (pending approval)'); end$$;

create function decide_entry(eid bigint,ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare e entries; begin
 select * into e from entries where id=eid and status='pend' for update;
 if not found then raise exception 'Entry not pending'; end if;
 if coalesce(my_role()::text,'') not in ('admin','treasurer') or (e.kind<>'pay' and my_role()<>'admin') then raise exception 'Not allowed'; end if;
 if e.made_by=auth.uid() then raise exception 'Maker-checker: you cannot approve your own entry'; end if;
 update entries set status=case when ok then 'ok' else 'rej' end, checked_by=auth.uid(),
  receipt=case when ok then 'RCT-'||lpad(nextval('rct')::text,5,'0') end where id=eid;
 perform log_a(case when ok then 'Approved' else 'Rejected' end||' entry for '||(select acct from members where id=e.member_id)); end$$;

grant execute on function add_member,record_payment,decide_entry to authenticated;
revoke execute on function log_a from public, anon, authenticated;
