-- The organizer-facing error from the events guard, in English (UI is English).
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
  if old.status <> 'pending' then raise exception 'This event has already been decided: only the administrator can change it'; end if;
  new.status := old.status; new.admin_note := old.admin_note;
  new.organizer_email := old.organizer_email;
  new.decided_at := old.decided_at; new.decided_by := old.decided_by;
  return new;
end $$;
