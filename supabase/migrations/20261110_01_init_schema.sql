-- Applied to Supabase project "meetup" (quzothoggtwvuvglyeph) on 2026-11-10.
-- Final state after 20261110_02 (helper functions live in schema "private").
-- The first admin is inserted by hand, not here (no personal data in the repo):
--   insert into public.organizers(email,name,role) values ('<email>','<name>','admin');

create table public.organizers (
  email text primary key check (email = lower(email)),
  name text not null default '',
  role text not null default 'organizer' check (role in ('organizer','admin')),
  created_at timestamptz not null default now()
);

create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.my_email() returns text
language sql stable set search_path = '' as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function private.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organizers where email = private.my_email())
$$;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organizers where email = private.my_email() and role = 'admin')
$$;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(title) between 1 and 200),
  description text not null default '',
  starts_on date not null,
  ends_on date not null,
  meeting_point text not null default '',
  difficulty text not null default '',
  max_people int check (max_people is null or max_people > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_note text not null default '',
  organizer_email text not null default private.my_email() references public.organizers(email) on update cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by text,
  check (ends_on >= starts_on)
);
create index events_dates on public.events (starts_on, ends_on);

create or replace function private.can_edit_event(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin() or exists (select 1 from public.events e where e.id = eid and e.organizer_email = private.my_email())
$$;

-- Organizers cannot approve their own events or change a decided one.
create or replace function private.events_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_at := now();
  if private.is_admin() then
    if tg_op = 'UPDATE' and new.status is distinct from old.status then
      new.decided_at := case when new.status = 'pending' then null else now() end;
      new.decided_by := case when new.status = 'pending' then null else private.my_email() end;
    end if;
    if tg_op = 'INSERT' and new.organizer_email is null then new.organizer_email := private.my_email(); end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.admin_note := ''; new.decided_at := null; new.decided_by := null;
    new.organizer_email := private.my_email();
    return new;
  end if;
  if old.status <> 'pending' then raise exception 'Evento già deciso: solo l''amministratore può modificarlo'; end if;
  new.status := old.status; new.admin_note := old.admin_note;
  new.organizer_email := old.organizer_email;
  new.decided_at := old.decided_at; new.decided_by := old.decided_by;
  return new;
end $$;
create trigger events_guard_ins before insert on public.events for each row execute function private.events_guard();
create trigger events_guard_upd before update on public.events for each row execute function private.events_guard();

create table public.event_files (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  path text not null unique,
  name text not null,
  size bigint,
  mime text,
  uploaded_by text not null default private.my_email(),
  created_at timestamptz not null default now()
);
create index event_files_event on public.event_files (event_id);

revoke all on all functions in schema private from public, anon;
grant execute on function private.my_email(), private.is_member(), private.is_admin(), private.can_edit_event(uuid) to authenticated;

alter table public.organizers enable row level security;
alter table public.events enable row level security;
alter table public.event_files enable row level security;

create policy org_read on public.organizers for select to authenticated using (private.is_member());
create policy org_admin_ins on public.organizers for insert to authenticated with check (private.is_admin());
create policy org_admin_upd on public.organizers for update to authenticated using (private.is_admin()) with check (private.is_admin());
create policy org_admin_del on public.organizers for delete to authenticated using (private.is_admin() and email <> private.my_email());

create policy ev_read on public.events for select to authenticated using (private.is_member());
create policy ev_ins on public.events for insert to authenticated with check (private.is_member());
create policy ev_upd on public.events for update to authenticated
  using (private.is_admin() or (organizer_email = private.my_email() and status = 'pending'))
  with check (private.is_admin() or organizer_email = private.my_email());
create policy ev_del on public.events for delete to authenticated
  using (private.is_admin() or (organizer_email = private.my_email() and status = 'pending'));

create policy f_read on public.event_files for select to authenticated using (private.is_member());
create policy f_ins on public.event_files for insert to authenticated with check (private.can_edit_event(event_id));
create policy f_del on public.event_files for delete to authenticated using (private.can_edit_event(event_id));

-- Private storage bucket: event-files/<event id>/<file>, 50 MB per file
insert into storage.buckets (id, name, public, file_size_limit)
values ('event-files', 'event-files', false, 52428800)
on conflict (id) do nothing;

create policy "event files read" on storage.objects for select to authenticated
  using (bucket_id = 'event-files' and private.is_member());
create policy "event files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'event-files' and private.can_edit_event(((storage.foldername(name))[1])::uuid));
create policy "event files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'event-files' and private.can_edit_event(((storage.foldername(name))[1])::uuid));
