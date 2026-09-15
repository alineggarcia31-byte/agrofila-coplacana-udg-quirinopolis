
-- AGROFILA — banco compartilhado (Supabase/PostgreSQL)
create extension if not exists pgcrypto;

create table if not exists public.queue_entries (
  id uuid primary key default gen_random_uuid(),
  unit_code text not null default 'COPLACANA-UDG-QUIRINOPOLIS',
  name text not null,
  phone text not null,
  plate text not null,
  vehicle_type text not null check (vehicle_type in ('Carreta','Truck','Bitrem','Rodotrem','Outro')),
  operation text not null check (operation in ('CARGA','DESCARGA')),
  product text not null check (product in ('Soja','Milho','Outro')),
  status text not null default 'AGUARDANDO'
    check (status in ('AGUARDANDO','CHAMADO','EM_ATENDIMENTO','FINALIZADO','CANCELADO')),
  access_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  called_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
);

create index if not exists queue_entries_unit_status_created_idx
  on public.queue_entries(unit_code, status, created_at);
create index if not exists queue_entries_access_token_idx
  on public.queue_entries(access_token);

alter table public.queue_entries enable row level security;

grant usage on schema public to anon, authenticated;
grant insert on public.queue_entries to anon, authenticated;
grant select on public.queue_entries to authenticated;
grant update on public.queue_entries to authenticated;

drop policy if exists "motorista pode entrar na fila" on public.queue_entries;
create policy "motorista pode entrar na fila"
on public.queue_entries for insert to anon, authenticated
with check (unit_code='COPLACANA-UDG-QUIRINOPOLIS' and status='AGUARDANDO');

drop policy if exists "balanca consulta fila" on public.queue_entries;
create policy "balanca consulta fila"
on public.queue_entries for select to authenticated
using (unit_code='COPLACANA-UDG-QUIRINOPOLIS');

drop policy if exists "balanca atualiza fila" on public.queue_entries;
create policy "balanca atualiza fila"
on public.queue_entries for update to authenticated
using (unit_code='COPLACANA-UDG-QUIRINOPOLIS')
with check (unit_code='COPLACANA-UDG-QUIRINOPOLIS');

-- RPC segura para o motorista consultar somente sua própria senha.
create or replace function public.join_agrofila_queue(
  p_name text,
  p_phone text,
  p_plate text,
  p_vehicle_type text,
  p_operation text,
  p_product text
)
returns table (id uuid, access_token uuid)
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_vehicle_type not in ('Carreta','Truck','Bitrem','Rodotrem','Outro') then
    raise exception 'Tipo de veículo inválido';
  end if;
  if p_operation not in ('CARGA','DESCARGA') then
    raise exception 'Operação inválida';
  end if;
  if p_product not in ('Soja','Milho','Outro') then
    raise exception 'Produto inválido';
  end if;
  if coalesce(trim(p_name),'')='' or coalesce(trim(p_phone),'')='' or coalesce(trim(p_plate),'')='' then
    raise exception 'Preencha nome, celular e placa';
  end if;

  return query
  insert into public.queue_entries(unit_code,name,phone,plate,vehicle_type,operation,product,status)
  values ('COPLACANA-UDG-QUIRINOPOLIS',trim(p_name),trim(p_phone),upper(trim(p_plate)),p_vehicle_type,p_operation,p_product,'AGUARDANDO')
  returning queue_entries.id, queue_entries.access_token;
end;
$$;

revoke all on function public.join_agrofila_queue(text,text,text,text,text,text) from public;
grant execute on function public.join_agrofila_queue(text,text,text,text,text,text) to anon, authenticated;

create or replace function public.get_agrofila_ticket(p_access_token uuid)
returns table (
  id uuid, name text, plate text, operation text, product text,
  vehicle_type text, status text, created_at timestamptz, position bigint
)
language sql
security definer
set search_path = public
as $$
  select q.id,q.name,q.plate,q.operation,q.product,q.vehicle_type,q.status,q.created_at,
    (select count(*) from public.queue_entries q2
      where q2.unit_code=q.unit_code
        and q2.operation=q.operation
        and q2.status in ('AGUARDANDO','CHAMADO','EM_ATENDIMENTO')
        and q2.created_at <= q.created_at) as position
  from public.queue_entries q
  where q.access_token=p_access_token
  limit 1;
$$;

revoke all on function public.get_agrofila_ticket(uuid) from public;
grant execute on function public.get_agrofila_ticket(uuid) to anon, authenticated;

-- Realtime para a tela autenticada da balança.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='queue_entries'
  ) then
    alter publication supabase_realtime add table public.queue_entries;
  end if;
exception when undefined_object then
  null;
end $$;
