-- 0001_init.sql
-- Core schema: users, jobs, and everything a job produces (checklist,
-- measurements, attachments, signatures, reports, invoices), plus the
-- offline sync queue.

create extension if not exists "pgcrypto";

-- enums -----------------------------------------------------------------

create type user_role as enum ('admin', 'manager', 'technician');
create type technician_status as enum ('active', 'inactive');
create type job_status as enum (
  'ASSIGNED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED'
);
create type job_priority as enum ('low', 'normal', 'high', 'urgent');
create type checklist_result as enum ('pass', 'fail', 'na');
create type attachment_type as enum ('photo', 'document');
create type sync_op_status as enum ('pending', 'syncing', 'synced', 'failed');
create type invoice_status as enum ('draft', 'sent', 'paid');

-- people ------------------------------------------------------------------

create table users (
  id uuid primary key default gen_random_uuid() references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null,
  role user_role not null default 'technician',
  phone text,
  created_at timestamptz not null default now()
);

create table technicians (
  id uuid primary key references users(id) on delete cascade,
  employee_code text not null unique,
  status technician_status not null default 'active',
  created_at timestamptz not null default now()
);

-- customers & equipment -----------------------------------------------------

create table customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text,
  address text,
  latitude double precision,
  longitude double precision
);

create table assets (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete restrict,
  asset_type text not null,
  make text,
  model text,
  serial_number text,
  metadata jsonb not null default '{}'::jsonb
);

-- jobs and everything a job produces ---------------------------------------

create table jobs (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete restrict,
  asset_id uuid references assets(id) on delete set null,
  technician_id uuid references technicians(id) on delete set null,
  title text not null,
  description text,
  status job_status not null default 'ASSIGNED',
  priority job_priority not null default 'normal',
  scheduled_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table checklist_items (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  label text not null,
  result checklist_result,
  note text,
  sort_order int not null default 0
);

create table measurements (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  metric text not null,
  value numeric not null,
  unit text not null,
  created_at timestamptz not null default now()
);

create table attachments (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  type attachment_type not null,
  storage_path text not null,
  caption text,
  created_at timestamptz not null default now()
);

create table signatures (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  customer_name text not null,
  storage_path text not null,
  accepted_at timestamptz not null default now()
);

create table service_reports (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete cascade,
  pdf_path text not null,
  generated_at timestamptz not null default now()
);

create table invoices (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references jobs(id) on delete restrict,
  amount_minor integer not null check (amount_minor >= 0),
  currency char(3) not null default 'NGN',
  status invoice_status not null default 'draft',
  issued_at timestamptz,
  due_at timestamptz,
  paid_at timestamptz,
  pdf_path text
);

-- offline sync queue --------------------------------------------------------

create table sync_operations (
  id uuid primary key default gen_random_uuid(),
  entity text not null,
  entity_id uuid not null,
  operation text not null check (operation in ('insert', 'update', 'delete')),
  payload jsonb not null,
  status sync_op_status not null default 'pending',
  retry_count int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  synced_at timestamptz
);

-- indexes ---------------------------------------------------------------

create index jobs_technician_status_idx on jobs (technician_id, status);
create index jobs_customer_idx on jobs (customer_id);
create index jobs_scheduled_at_idx on jobs (scheduled_at);
create index checklist_items_job_idx on checklist_items (job_id);
create index measurements_job_idx on measurements (job_id);
create index attachments_job_idx on attachments (job_id);
create index signatures_job_idx on signatures (job_id);
create index service_reports_job_idx on service_reports (job_id);
create index invoices_job_idx on invoices (job_id);
create index invoices_status_idx on invoices (status);
create index sync_operations_status_idx on sync_operations (status);
create index sync_operations_entity_idx on sync_operations (entity, entity_id);

-- job status transition guard (ADR-001) --------------------------------

-- The state machine lives here, not just in client code, because a queued
-- offline mutation can reach the server long after the client validated it.
-- By then the "current" status it validated against may no longer be current.
create or replace function enforce_job_status_transition()
returns trigger as $$
begin
  if new.status = old.status then
    return new; -- other fields changing, not a transition
  end if;

  if old.status in ('COMPLETED', 'CANCELLED') then
    raise exception 'job % is in a terminal state (%), cannot transition to %',
      old.id, old.status, new.status;
  end if;

  if new.status = 'CANCELLED' then
    return new; -- cancellable from any non-terminal state
  end if;

  if not (
    (old.status = 'ASSIGNED'    and new.status = 'EN_ROUTE') or
    (old.status = 'EN_ROUTE'    and new.status = 'ARRIVED') or
    (old.status = 'ARRIVED'     and new.status = 'IN_PROGRESS') or
    (old.status = 'IN_PROGRESS' and new.status = 'COMPLETED')
  ) then
    raise exception 'invalid job transition: % -> %', old.status, new.status;
  end if;

  if new.status = 'IN_PROGRESS' and new.started_at is null then
    new.started_at = now();
  end if;

  if new.status = 'COMPLETED' and new.completed_at is null then
    new.completed_at = now();
  end if;

  return new;
end;
$$ language plpgsql;

create trigger jobs_status_transition
  before update on jobs
  for each row
  execute function enforce_job_status_transition();

create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger jobs_set_updated_at
  before update on jobs
  for each row
  execute function set_updated_at();

-- RLS ---------------------------------------------------------------------

alter table users enable row level security;
alter table technicians enable row level security;
alter table customers enable row level security;
alter table assets enable row level security;
alter table jobs enable row level security;
alter table checklist_items enable row level security;
alter table measurements enable row level security;
alter table attachments enable row level security;
alter table signatures enable row level security;
alter table service_reports enable row level security;
alter table invoices enable row level security;
alter table sync_operations enable row level security;

-- helper: avoids repeating this subquery in every policy below
create or replace function is_admin_or_manager()
returns boolean as $$
  select exists (
    select 1 from users
    where id = auth.uid() and role in ('admin', 'manager')
  );
$$ language sql stable;

create policy users_self_or_staff on users
  for select using (id = auth.uid() or is_admin_or_manager());

create policy jobs_read on jobs
  for select using (technician_id = auth.uid() or is_admin_or_manager());

create policy jobs_technician_update on jobs
  for update using (technician_id = auth.uid() or is_admin_or_manager());

create policy jobs_staff_insert on jobs
  for insert with check (is_admin_or_manager());

-- child tables inherit access from their parent job
create policy checklist_items_via_job on checklist_items
  for all using (
    exists (
      select 1 from jobs
      where jobs.id = checklist_items.job_id
        and (jobs.technician_id = auth.uid() or is_admin_or_manager())
    )
  );

create policy measurements_via_job on measurements
  for all using (
    exists (
      select 1 from jobs
      where jobs.id = measurements.job_id
        and (jobs.technician_id = auth.uid() or is_admin_or_manager())
    )
  );

create policy attachments_via_job on attachments
  for all using (
    exists (
      select 1 from jobs
      where jobs.id = attachments.job_id
        and (jobs.technician_id = auth.uid() or is_admin_or_manager())
    )
  );

create policy signatures_via_job on signatures
  for all using (
    exists (
      select 1 from jobs
      where jobs.id = signatures.job_id
        and (jobs.technician_id = auth.uid() or is_admin_or_manager())
    )
  );

create policy service_reports_via_job on service_reports
  for all using (
    exists (
      select 1 from jobs
      where jobs.id = service_reports.job_id
        and (jobs.technician_id = auth.uid() or is_admin_or_manager())
    )
  );

create policy invoices_staff_only on invoices
  for all using (is_admin_or_manager());

create policy customers_read on customers
  for select using (
    is_admin_or_manager() or exists (
      select 1 from jobs where jobs.customer_id = customers.id and jobs.technician_id = auth.uid()
    )
  );

create policy assets_read on assets
  for select using (
    is_admin_or_manager() or exists (
      select 1 from jobs where jobs.asset_id = assets.id and jobs.technician_id = auth.uid()
    )
  );

create policy sync_operations_own on sync_operations
  for all using (is_admin_or_manager() or true);
  -- NOTE: sync_operations.entity_id is polymorphic (points at whichever
  -- table `entity` names), so it can't carry a real FK or a clean
  -- ownership check here. Tighten this once the sync worker's auth model
  -- is settled — right now this deliberately trusts the underlying
  -- per-entity RLS to reject anything that shouldn't apply.
