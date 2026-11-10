-- Applied 2026-11-10 (migration "public_requests").
-- Anyone who signs in can request events (public.ensure_me adds them as 'organizer').
-- Non-admins see approved events and their own requests, and their files; only their own
-- organizers row. The requester's name is copied on the event so emails stay private.
alter table public.events add column if not exists organizer_name text not null default '';

-- Guard: system updates (no user email, or the app.sys flag set by set_my_name) only refresh the name.
create or replace function private.events_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if private.my_email() = '' or current_setting('app.sys', true) = '1' then
    if tg_op = 'UPDATE' and current_setting('app.sys', true) = '1' then
      new := old; new.organizer_name := coalesce((select o.name from public.organizers o where o.email = old.organizer_email), '');
      return new;
    end if;
    select o.name into new.organizer_name from public.organizers o where o.email = new.organizer_email;
    new.organizer_name := coalesce(new.organizer_name, '');
    return new;
  end if;
  new.updated_at := now();
  if private.is_admin() then
    if tg_op = 'UPDATE' and new.status is distinct from old.status then
      new.decided_at := case when new.status = 'pending' then null else now() end;
      new.decided_by := case when new.status = 'pending' then null else private.my_email() end;
    end if;
    if tg_op = 'INSERT' and new.organizer_email is null then new.organizer_email := private.my_email(); end if;
  elsif tg_op = 'INSERT' then
    new.status := 'pending'; new.admin_note := ''; new.decided_at := null; new.decided_by := null;
    new.organizer_email := private.my_email();
  else
    if old.status <> 'pending' then raise exception 'This event has already been decided: only the administrator can change it'; end if;
    new.status := old.status; new.admin_note := old.admin_note;
    new.organizer_email := old.organizer_email;
    new.decided_at := old.decided_at; new.decided_by := old.decided_by;
  end if;
  select o.name into new.organizer_name from public.organizers o where o.email = new.organizer_email;
  new.organizer_name := coalesce(new.organizer_name, '');
  return new;
end $$;

create or replace function public.ensure_me() returns public.organizers
language plpgsql security definer set search_path = '' as $$
declare r public.organizers; e text := private.my_email();
begin
  if e = '' then raise exception 'Not signed in'; end if;
  insert into public.organizers(email) values (e) on conflict (email) do nothing;
  select * into r from public.organizers where email = e;
  return r;
end $$;

create or replace function public.set_my_name(n text) returns void
language plpgsql security definer set search_path = '' as $$
declare e text := private.my_email(); v text := left(trim(coalesce(n,'')), 80);
begin
  if e = '' then raise exception 'Not signed in'; end if;
  update public.organizers set name = v where email = e;
  perform set_config('app.sys', '1', true);
  update public.events set organizer_name = v where organizer_email = e;
  perform set_config('app.sys', '0', true);
end $$;
revoke all on function public.ensure_me(), public.set_my_name(text) from public, anon;
grant execute on function public.ensure_me(), public.set_my_name(text) to authenticated;

create or replace function private.can_see_event(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin() or exists (select 1 from public.events e where e.id = eid
    and (e.status = 'approved' or e.organizer_email = private.my_email()))
$$;
revoke all on function private.can_see_event(uuid) from public, anon;
grant execute on function private.can_see_event(uuid) to authenticated;

drop policy org_read on public.organizers;
create policy org_read on public.organizers for select to authenticated
  using (private.is_admin() or email = private.my_email());

drop policy ev_read on public.events;
create policy ev_read on public.events for select to authenticated
  using (private.is_admin() or status = 'approved' or organizer_email = private.my_email());

drop policy f_read on public.event_files;
create policy f_read on public.event_files for select to authenticated using (private.can_see_event(event_id));

drop policy "event files read" on storage.objects;
create policy "event files read" on storage.objects for select to authenticated
  using (bucket_id = 'event-files' and private.can_see_event(((storage.foldername(name))[1])::uuid));

update public.events set organizer_name = organizer_name;  -- runs the guard (no user): fills names
