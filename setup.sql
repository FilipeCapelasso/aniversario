-- ==============================================================
-- SETUP COMPLETO (rode UMA vez no Supabase: SQL Editor > New query > Run)
-- Antes de rodar, edite <REF> e o segredo no bloco final (TELEGRAM).
-- ==============================================================
-- Rode no Supabase: SQL Editor > New query > Run
create extension if not exists unaccent with schema extensions;

create table guests(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  normalized_name text not null unique,
  note text, is_active boolean not null default true,
  created_at timestamptz not null default now());
create table attendance(
  id uuid primary key default gen_random_uuid(),
  guest_id uuid not null unique references guests(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  confirmed_at timestamptz not null default now(),
  approved_at timestamptz, rejected_at timestamptz,
  created_at timestamptz not null default now());
create table admin_users(user_id uuid primary key references auth.users(id) on delete cascade);
create table event_settings(
  id int primary key default 1 check (id=1),
  event_title text, event_date timestamptz, location text, description text);
insert into event_settings values (1,'Aniversário de Capelasso & Anne','2026-10-10T20:00:00-05:00','Estância','Amigos e pessoas especiais');
create table audit_log(id bigint generated always as identity primary key, action text not null, created_at timestamptz default now());
create table rate_limits(key text, at timestamptz default now());

create function norm(t text) returns text language sql immutable as
$$ select regexp_replace(lower(extensions.unaccent(trim(t))),'\s+',' ','g') $$;
create function set_norm() returns trigger language plpgsql as
$$ begin new.normalized_name:=norm(new.name); return new; end $$;
create trigger t_norm before insert or update of name on guests for each row execute function set_norm();

create function is_admin() returns boolean language sql security definer set search_path=public stable as
$$ select exists(select 1 from admin_users where user_id=auth.uid()) $$;

-- RLS: visitantes NÃO têm acesso direto às tabelas (só às funções abaixo)
alter table guests enable row level security;
alter table attendance enable row level security;
alter table admin_users enable row level security;
alter table event_settings enable row level security;
alter table audit_log enable row level security;
alter table rate_limits enable row level security;
create policy g_admin on guests for all using (is_admin()) with check (is_admin());
create policy a_admin on attendance for all using (is_admin()) with check (is_admin());
create policy au_self on admin_users for select using (user_id=auth.uid());
create policy es_read on event_settings for select using (true);
create policy es_admin on event_settings for update using (is_admin()) with check (is_admin());
create policy log_admin on audit_log for select using (is_admin());

-- Log automático de ações
create function audit() returns trigger language plpgsql security definer set search_path=public as $$
declare n text; s text;
begin
  if tg_table_name='guests' then
    insert into audit_log(action) values (case tg_op when 'INSERT' then new.name||' foi cadastrado' else old.name||' foi excluído da lista' end);
  else
    select name into n from guests where id=coalesce(new.guest_id,old.guest_id);
    if tg_op='DELETE' then s:='teve a confirmação removida';
    elsif tg_op='INSERT' then s:='pediu confirmação';
    elsif new.status is distinct from old.status then s:='foi '||case new.status when 'approved' then 'aprovado' when 'rejected' then 'recusado' else 'reaberto' end;
    end if;
    if s is not null then insert into audit_log(action) values (n||' '||s); end if;
  end if;
  return null;
end $$;
create trigger t_a1 after insert or delete on guests for each row execute function audit();
create trigger t_a2 after insert or update or delete on attendance for each row execute function audit();

-- Rate limit por IP (10 tentativas / 10 min)
create function rl() returns void language plpgsql security definer set search_path=public as $$
declare k text:=coalesce(split_part(current_setting('request.headers',true)::json->>'x-forwarded-for',',',1),'x');
begin
  delete from rate_limits where at<now()-interval '10 minutes';
  if (select count(*) from rate_limits where key=k)>=10 then raise exception 'rate_limited'; end if;
  insert into rate_limits(key) values (k);
end $$;
revoke all on function rl() from public, anon, authenticated;

create function verify_guest(p_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare g guests; a text;
begin
  perform rl();
  if p_name is null or char_length(p_name) not between 3 and 80 then return '{"found":false}'; end if;
  select * into g from guests where normalized_name=norm(p_name) and is_active;
  if not found then return '{"found":false}'; end if;
  select status into a from attendance where guest_id=g.id;
  return jsonb_build_object('found',true,'name',g.name,'already',a is not null);
end $$;

create function confirm_attendance(p_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare g guests;
begin
  perform rl();
  select * into g from guests where normalized_name=norm(p_name) and is_active;
  if not found then return '{"ok":false}'; end if;
  insert into attendance(guest_id) values (g.id) on conflict (guest_id) do nothing;
  return '{"ok":true}';
end $$;

create function public_confirmed() returns table(name text) language sql security definer set search_path=public as
$$ select g.name from attendance a join guests g on g.id=a.guest_id where a.status='approved' order by a.approved_at nulls last $$;

grant execute on function verify_guest(text), confirm_attendance(text), public_confirmed() to anon, authenticated;

-- Depois de criar seu usuário em Authentication > Users, torne-o admin:
-- insert into admin_users select id from auth.users where email='SEU@EMAIL.COM';
-- Convidados de exemplo: insert into guests(name) values ('João Silva'),('Maria Silva');

-- ================= TELEGRAM (EDITE <REF> e o segredo) =================
create extension if not exists pg_net with schema extensions;
alter table attendance add column if not exists approved_by text, add column if not exists rejected_by text;

create table private_config(key text primary key, value text not null);
alter table private_config enable row level security;  -- sem policies: invisível para o site
revoke all on private_config from anon, authenticated;
insert into private_config values
  ('notify_url','https://<REF>.supabase.co/functions/v1/telegram'),
  ('notify_secret','TROQUE-POR-UM-SEGREDO-LONGO');

create function notify_telegram() returns trigger language plpgsql security definer set search_path=public,extensions as $$
begin
  perform net.http_post(
    url := (select value from private_config where key='notify_url'),
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret',(select value from private_config where key='notify_secret')),
    body := jsonb_build_object('attendance_id', new.id));
  return null;
exception when others then return null;  -- falha no Telegram nunca bloqueia a confirmação
end $$;
create trigger t_notify after insert on attendance for each row execute function notify_telegram();
