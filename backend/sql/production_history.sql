-- ============================================================================
-- Harvest record history: every add, edit and delete is kept, so no record
-- can be lost for good (by mistake, or by someone who copied the app's key).
--
-- Why not just block deleting? The app has no login (on purpose), so the
-- database cannot tell Mr. Arnel's phone apart from anyone else holding the
-- app's public key. Blocking deletes would also block his own Delete button.
-- Instead, every change is copied into a hidden history table that the app's
-- key can neither read nor change.
--
-- Run once in Supabase: SQL Editor > New query > paste > Run.
-- ============================================================================

create table if not exists public.production_logs_history (
  history_id  bigint generated always as identity primary key,
  changed_at  timestamptz not null default now(),
  action      text not null,      -- INSERT, UPDATE, DELETE or SNAPSHOT
  record_id   bigint,
  old_row     jsonb,              -- the record before the change
  new_row     jsonb               -- the record after the change
);

-- Row-level security ON with no policies: the app's public key cannot read,
-- add, change or delete history. Only the Supabase dashboard / service key can.
alter table public.production_logs_history enable row level security;

-- "security definer" lets the trigger write history even though the app's
-- key itself has no access to the history table.
create or replace function public.log_production_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.production_logs_history (action, record_id, old_row)
    values ('DELETE', old.id, to_jsonb(old));
    return old;
  elsif tg_op = 'UPDATE' then
    insert into public.production_logs_history (action, record_id, old_row, new_row)
    values ('UPDATE', new.id, to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into public.production_logs_history (action, record_id, new_row)
    values ('INSERT', new.id, to_jsonb(new));
    return new;
  end if;
end;
$$;

drop trigger if exists production_logs_history_trg on public.production_logs;
create trigger production_logs_history_trg
after insert or update or delete on public.production_logs
for each row execute function public.log_production_change();

-- A starting copy of every record that exists today
insert into public.production_logs_history (action, record_id, new_row)
select 'SNAPSHOT', p.id, to_jsonb(p)
from public.production_logs p
where not exists (
  select 1 from public.production_logs_history h where h.action = 'SNAPSHOT'
);


-- ============================================================================
-- HOW TO RESTORE (only when needed; run these by hand in the SQL Editor)
-- ============================================================================
-- See the latest changes:
--   select changed_at, action, record_id, old_row, new_row
--   from public.production_logs_history order by changed_at desc limit 50;
--
-- Bring back every record deleted since a given time (Manila time, +08),
-- with their original ids:
--   insert into public.production_logs overriding system value
--   select (jsonb_populate_record(null::public.production_logs, old_row)).*
--   from public.production_logs_history
--   where action = 'DELETE' and changed_at >= '2026-11-10 00:00+08'
--   on conflict (id) do nothing;
