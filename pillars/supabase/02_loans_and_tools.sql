-- Run after schema.sql. Loans (24% p.a. added upfront, 75% of savings limit, 2 guarantors) + member editing.
create function has_role(variadic r text[]) returns boolean language sql stable security definer set search_path=public as $$select coalesce(my_role()::text=any(r),false)$$;
create sequence lno;
create table loans(id bigserial primary key, member_id uuid not null references members, mname text, acct text, amt int not null, term int not null, purpose text not null,
 status text not null default 'gua' check (status in ('gua','tre','pend','ok','rej')), why text, no text, made_by uuid, approved_by uuid, approved_on date, created timestamptz default now());
create table loan_guarantors(loan_id bigint references loans on delete cascade, member_id uuid references members, gname text, s text not null default 'wait' check (s in ('wait','ok','no')), primary key(loan_id,member_id));
create table loan_entries(id bigserial primary key, loan_id bigint not null references loans on delete cascade, k text not null check (k in ('disb','int','rep')), amt int not null, on_date date not null default current_date, method text, by_name text, receipt text);
alter table loans enable row level security; alter table loan_guarantors enable row level security; alter table loan_entries enable row level security;
create function loan_owner(lid bigint) returns uuid language sql stable security definer set search_path=public as $$select member_id from loans where id=lid$$;
create function is_guarantor(lid bigint) returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from loan_guarantors where loan_id=lid and member_id=my_member())$$;
create policy r_loans on loans for select using (has_role('admin','treasurer','auditor') or member_id=my_member() or is_guarantor(id));
create policy r_lg on loan_guarantors for select using (has_role('admin','treasurer','auditor') or member_id=my_member() or loan_owner(loan_id)=my_member());
create policy r_le on loan_entries for select using (has_role('admin','treasurer','auditor') or loan_owner(loan_id)=my_member());

create function sav(m uuid) returns bigint language sql stable security definer set search_path=public as $$select coalesce(sum(amt),0) from entries where member_id=m and kind='pay' and status='ok'$$;
create function lprin(lid bigint) returns bigint language sql stable security definer set search_path=public as $$
 select coalesce(sum(amt) filter(where k='disb'),0)-greatest(0,coalesce(sum(amt) filter(where k='rep'),0)-coalesce(sum(amt) filter(where k='int'),0)) from loan_entries where loan_id=lid$$;
create function lbal(lid bigint) returns bigint language sql stable security definer set search_path=public as $$select coalesce(sum(case k when 'rep' then -amt else amt end),0) from loan_entries where loan_id=lid$$;
create function fund() returns bigint language sql stable security definer set search_path=public as $$
 select (select coalesce(sum(amt),0) from entries where kind='pay' and status='ok')-(select coalesce(sum(case k when 'disb' then amt when 'rep' then -amt else 0 end),0) from loan_entries)$$;
create function member_directory() returns table(id uuid,acct text,name text) language sql stable security definer set search_path=public as $$select id,acct,name from members where status='Active' order by seq$$;

create function request_loan(a int,t int,p text,g1 uuid,g2 uuid) returns void language plpgsql security definer set search_path=public as $$
declare m members; l bigint; lim bigint; begin
 if my_member() is null then raise exception 'No member account'; end if;
 select * into m from members where id=my_member();
 if m.status<>'Active' or a<=0 or t<1 or coalesce(trim(p),'')='' then raise exception 'Check the amount, term and purpose'; end if;
 if g1 is null or g2 is null or g1=g2 or m.id in (g1,g2) then raise exception 'Choose two different guarantors'; end if;
 lim:=floor(sav(m.id)*0.75)-(select coalesce(sum(case status when 'rej' then 0 when 'ok' then lprin(id) else amt end),0) from loans where member_id=m.id);
 if a>lim then raise exception 'You can borrow up to USh %',greatest(lim,0); end if;
 insert into loans(member_id,mname,acct,amt,term,purpose) values(m.id,m.name,m.acct,a,t,trim(p)) returning id into l;
 insert into loan_guarantors(loan_id,member_id,gname) select l,id,name from members where id in (g1,g2) and status='Active';
 if (select count(*) from loan_guarantors where loan_id=l)<2 then raise exception 'Guarantors must be active members'; end if;
 perform log_a('Requested loan of '||a||' ('||m.acct||'), awaiting guarantors'); end$$;

create function guarantee(lid bigint,agree boolean) returns void language plpgsql security definer set search_path=public as $$
begin
 perform 1 from loans where id=lid and status='gua' for update; if not found then raise exception 'Request is no longer open'; end if;
 update loan_guarantors set s=case when agree then 'ok' else 'no' end where loan_id=lid and member_id=my_member() and s='wait';
 if not found then raise exception 'Not your request'; end if;
 if not agree then update loans set status='rej',why=my_name()||' declined to guarantee' where id=lid;
 elsif not exists(select 1 from loan_guarantors where loan_id=lid and s<>'ok') then update loans set status='tre' where id=lid; end if;
 perform log_a(case when agree then 'Agreed' else 'Declined' end||' to guarantee loan '||lid); end$$;

create function advance_loan(lid bigint,ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare l loans; begin
 if not has_role('treasurer') then raise exception 'Only the Treasurer can advance loans'; end if;
 select * into l from loans where id=lid and status='tre' for update; if not found then raise exception 'Loan not awaiting the Treasurer'; end if;
 if ok and l.amt>fund() then raise exception 'Group fund is too low to advance this loan'; end if;
 if ok then update loans set status='pend',made_by=auth.uid() where id=lid; else update loans set status='rej',why='Declined by the Treasurer' where id=lid; end if;
 perform log_a(case when ok then 'Advanced to Admin: loan for ' else 'Rejected loan for ' end||l.acct); end$$;

create function approve_loan(lid bigint,ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare l loans; n text; begin
 if not has_role('admin') then raise exception 'Only the Admin can approve loans'; end if;
 select * into l from loans where id=lid and status='pend' for update; if not found then raise exception 'Loan not awaiting the Admin'; end if;
 if l.made_by=auth.uid() then raise exception 'Maker-checker: you cannot approve your own entry'; end if;
 if not ok then update loans set status='rej',why='Declined by the Admin' where id=lid; perform log_a('Rejected loan for '||l.acct); return; end if;
 if l.amt>fund() then raise exception 'Group fund is too low to advance this loan'; end if;
 n:='LN-'||lpad(nextval('lno')::text,4,'0');
 update loans set status='ok',no=n,approved_by=auth.uid(),approved_on=current_date where id=lid;
 insert into loan_entries(loan_id,k,amt,by_name,receipt) values(lid,'disb',l.amt,my_name(),n),(lid,'int',round(l.amt*24/1200.0*l.term),'System',null);
 perform log_a('Approved loan for '||l.acct||' ('||n||')'); end$$;

create function record_repayment(lid bigint,a int,meth text default 'Mobile Money',d date default current_date) returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_role('treasurer') then raise exception 'Only the Treasurer can record repayments'; end if;
 perform 1 from loans where id=lid and status='ok' for update; if not found then raise exception 'Loan is not active'; end if;
 if a<=0 or a>lbal(lid) then raise exception 'Amount must be between 1 and the balance (USh %)',lbal(lid); end if;
 insert into loan_entries(loan_id,k,amt,on_date,method,by_name,receipt) values(lid,'rep',a,d,meth,my_name(),'LR-'||lpad(nextval('rct')::text,5,'0'));
 perform log_a('Recorded repayment of '||a||' on loan '||lid); end$$;

create function delete_loan(lid bigint) returns void language plpgsql security definer set search_path=public as $$
declare l loans; begin
 if not has_role('admin') then raise exception 'Only the Super Admin can delete loan applications'; end if;
 select * into l from loans where id=lid for update; if not found then raise exception 'Not found'; end if;
 if l.status='ok' then raise exception 'Advanced loans cannot be deleted'; end if;
 delete from loans where id=lid; perform log_a('Deleted loan application of '||l.amt||' for '||l.acct||' ('||l.status||')'); end$$;

create function edit_member(mid uuid,n text,p text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_role('admin','secretary') then raise exception 'Not allowed'; end if;
 update members set name=trim(n),phone=nullif(p,'') where id=mid;
 perform log_a('Edited biodata of '||(select acct from members where id=mid)); end$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function my_role,my_member,my_name,has_role,loan_owner,is_guarantor,add_member,record_payment,decide_entry,member_directory,request_loan,guarantee,advance_loan,approve_loan,record_repayment,delete_loan,edit_member to authenticated;
