-- Run after 02_loans_and_tools.sql (and 03 import). Withdrawals, reversals, status, arrears view.
alter table entries add column ref bigint references entries, add column reversed boolean not null default false;
drop index one_pay_per_month;
create unique index one_pay_per_month on entries(member_id,month) where kind='pay' and status<>'rej' and not reversed;
create table gwds(id bigserial primary key, amt int not null check (amt>0), method text, reason text not null,
 status text not null default 'pend' check (status in ('pend','ok','rej')), made_by uuid, voucher text, created timestamptz not null default now());
alter table gwds enable row level security;
create policy r_gwds on gwds for select using (has_role('admin','treasurer','auditor'));
create sequence wv;

create or replace function sav(m uuid) returns bigint language sql stable security definer set search_path=public as $$select coalesce(sum(amt),0) from entries where member_id=m and status='ok'$$;
create or replace function fund() returns bigint language sql stable security definer set search_path=public as $$
 select (select coalesce(sum(amt),0) from entries where status='ok')-(select coalesce(sum(amt),0) from gwds where status='ok')
 -(select coalesce(sum(case k when 'disb' then amt when 'rep' then -amt else 0 end),0) from loan_entries)$$;
create function avail(m uuid) returns bigint language sql stable security definer set search_path=public as $$
 select sav(m)+coalesce((select sum(amt) from entries where member_id=m and kind='wd' and status='pend'),0)$$;

create function request_withdrawal(mid uuid,a int,meth text,why text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_role('treasurer') then raise exception 'Only the Treasurer records withdrawals'; end if;
 if a<=0 or a>avail(mid) then raise exception 'Amount is more than available savings (USh %)',avail(mid); end if;
 if coalesce(trim(why),'')='' then raise exception 'Reason required'; end if;
 insert into entries(member_id,kind,month,amt,method,reason,made_by) values(mid,'wd',to_char(current_date,'YYYY-MM'),-a,meth,why,auth.uid());
 perform log_a('Requested withdrawal of '||a||' for '||(select acct from members where id=mid)||': '||why); end$$;

create function request_reversal(eid bigint,why text) returns void language plpgsql security definer set search_path=public as $$
declare e entries; begin
 if not has_role('admin','treasurer') then raise exception 'Not allowed'; end if;
 if coalesce(trim(why),'')='' then raise exception 'A reason is required'; end if;
 select * into e from entries where id=eid and status='ok' and kind in ('pay','wd') and not reversed;
 if not found or exists(select 1 from entries where ref=eid and status<>'rej') then raise exception 'This entry cannot be reversed (or already has a reversal)'; end if;
 insert into entries(member_id,kind,month,amt,method,ref,reason,made_by) values(e.member_id,'rev',e.month,-e.amt,e.method,eid,why,auth.uid());
 perform log_a('Requested reversal of '||e.receipt||': '||why); end$$;

create or replace function decide_entry(eid bigint,ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare e entries; o entries; adm boolean; begin
 select * into e from entries where id=eid and status='pend' for update;
 if not found then raise exception 'Entry not pending'; end if;
 if e.kind='rev' then select * into o from entries where id=e.ref; end if;
 adm:=e.kind='wd' or (e.kind='rev' and o.kind='wd');
 if not has_role('admin','treasurer') or (adm and not has_role('admin')) then raise exception 'Not allowed (withdrawals are approved by the Admin only)'; end if;
 if e.made_by=auth.uid() then raise exception 'Maker-checker: you cannot approve your own entry'; end if;
 update entries set status=case when ok then 'ok' else 'rej' end,checked_by=auth.uid(),receipt=case when ok then 'RCT-'||lpad(nextval('rct')::text,5,'0') end where id=eid;
 if ok and e.kind='rev' then update entries set reversed=true where id=e.ref; end if;
 perform log_a(case when ok then 'Approved' else 'Rejected' end||' entry for '||(select acct from members where id=e.member_id)); end$$;

create function request_group_withdrawal(a int,meth text,why text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_role('treasurer') then raise exception 'Only the Treasurer records withdrawals'; end if;
 if a<=0 or a>fund()-coalesce((select sum(amt) from gwds where status='pend'),0) then raise exception 'Amount is more than the group fund available'; end if;
 if coalesce(trim(why),'')='' then raise exception 'Reason required'; end if;
 insert into gwds(amt,method,reason,made_by) values(a,meth,why,auth.uid()); perform log_a('Requested general withdrawal of '||a||': '||why); end$$;

create function decide_gwd(gid bigint,ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare g gwds; begin
 if not has_role('admin') then raise exception 'Only the Admin approves withdrawals'; end if;
 select * into g from gwds where id=gid and status='pend' for update; if not found then raise exception 'Not pending'; end if;
 if g.made_by=auth.uid() then raise exception 'Maker-checker: you cannot approve your own entry'; end if;
 update gwds set status=case when ok then 'ok' else 'rej' end,voucher=case when ok then 'WV-'||lpad(nextval('wv')::text,4,'0') end where id=gid;
 perform log_a(case when ok then 'Approved' else 'Rejected' end||' general withdrawal of '||g.amt); end$$;

create function set_status(mid uuid,st text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_role('admin') or st not in ('Active','Inactive') then raise exception 'Not allowed'; end if;
 update members set status=st where id=mid; perform log_a((case st when 'Inactive' then 'Deactivated ' else 'Reactivated ' end)||(select acct from members where id=mid)); end$$;

create view member_summary with (security_invoker=true) as
select m.*,s.sav,s.paid,x.exp,
 case when m.status='Inactive' then 0 else greatest(0,x.exp-s.paid) end as arrears,
 case when m.status='Inactive' then 0 else greatest(0,s.paid-x.exp) end as advance
from members m
cross join lateral (select 5000*greatest(0,((extract(year from current_date)-extract(year from m.joined))*12+extract(month from current_date)-extract(month from m.joined)+1)::int) as exp) x
cross join lateral (select coalesce(sum(e.amt),0)::bigint as sav,
  coalesce(sum(e.amt) filter(where e.kind='pay' or (e.kind='rev' and exists(select 1 from entries p where p.id=e.ref and p.kind='pay'))),0)::bigint as paid
  from entries e where e.member_id=m.id and e.status='ok') s;
grant select on member_summary to authenticated;
revoke execute on all functions in schema public from public, anon;
grant execute on function avail,request_withdrawal,request_reversal,decide_entry,request_group_withdrawal,decide_gwd,set_status to authenticated;
