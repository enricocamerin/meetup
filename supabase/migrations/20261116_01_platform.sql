-- Written 2026-11-16 (migration "platform"). NOT APPLIED YET: the confirmation request timed out.
-- From a single approval calendar to a Meetup-style platform:
--   profiles (keyed by the Supabase user id, no emails in public tables), groups with
--   per-group roles, membership requests, events v2 (time, map point, route data, fees,
--   recurring series, cancellation), sign-ups with capacity + automatic waiting list,
--   carpooling, private sign-up details (emergency contact, payment), comments, files,
--   and an email outbox (sent by the edge function "api", driven by pg_cron).
-- Only test data existed: the administrators and their events move to the group
-- "meetup-hiking". Nothing personal is written here: the data is copied in the database.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------- park the old schema
-- The old tables move to schema "legacy" (not exposed by the API, indexes move with them);
-- 20261116_02_drop_legacy.sql deletes it. Old functions become inert.
create schema if not exists legacy;
revoke all on schema legacy from public, anon, authenticated;
alter table public.event_files set schema legacy;
alter table public.events set schema legacy;
alter table public.organizers set schema legacy;
revoke all on function public.ensure_me(), public.set_my_name(text) from public, anon, authenticated;

-- ---------------------------------------------------------------- tables
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '' check (length(name) <= 80),
  bio text not null default '' check (length(bio) <= 1000),
  is_admin boolean not null default false,
  email_new_events boolean not null default true,
  email_reminders boolean not null default true,
  email_comments boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'),
  name text not null check (length(name) between 2 and 80),
  description text not null default '' check (length(description) <= 5000),
  area text not null default '' check (length(area) <= 120),
  visibility text not null default 'public' check (visibility in ('public', 'private')),
  join_policy text not null default 'open' check (join_policy in ('open', 'approval')),
  members_can_propose boolean not null default true,
  status text not null default 'pending' check (status in ('pending', 'active', 'rejected')),
  admin_note text not null default '' check (length(admin_note) <= 1000),
  member_count int not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.memberships (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'organizer', 'member')),
  status text not null default 'active' check (status in ('active', 'pending', 'banned')),
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index memberships_user on public.memberships (user_id);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  series_id uuid,
  title text not null check (length(title) between 1 and 200),
  description text not null default '' check (length(description) <= 10000),
  starts_on date not null,
  ends_on date not null,
  meet_time time,
  meeting_point text not null default '' check (length(meeting_point) <= 300),
  lat double precision check (lat between -90 and 90),
  lon double precision check (lon between -180 and 180),
  difficulty text not null default '' check (difficulty in ('', 'T', 'E', 'EE', 'EEA')),
  distance_km numeric(6,1) check (distance_km >= 0),
  ascent_m int check (ascent_m >= 0),
  duration_h numeric(4,1) check (duration_h >= 0),
  gear text not null default '' check (length(gear) <= 2000),
  max_people int check (max_people is null or max_people > 0),
  rsvp_closes_at timestamptz,
  fee_cents int check (fee_cents is null or fee_cents >= 0),
  currency text not null default 'EUR' check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  admin_note text not null default '' check (length(admin_note) <= 1000),
  cancel_reason text not null default '' check (length(cancel_reason) <= 1000),
  organizer_id uuid references auth.users(id) on delete set null,
  organizer_name text not null default '',
  going_count int not null default 0,
  waitlist_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  check (ends_on >= starts_on)
);
create index events_group_dates on public.events (group_id, starts_on);
create index events_dates on public.events (starts_on);
create index events_series on public.events (series_id) where series_id is not null;
create index events_organizer on public.events (organizer_id);
create index events_decided_by on public.events (decided_by);

-- Visible only to the people signed up and to the hosts.
create table public.event_private (
  event_id uuid primary key references public.events(id) on delete cascade,
  payment_info text not null default '' check (length(payment_info) <= 2000),
  attendee_info text not null default '' check (length(attendee_info) <= 2000)
);

create table public.rsvps (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('going', 'waitlist')),
  car_seats int not null default 0 check (car_seats between 0 and 8),
  needs_ride boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index rsvps_user on public.rsvps (user_id);

-- Seen only by the person and the hosts.
create table public.rsvp_private (
  event_id uuid not null,
  user_id uuid not null,
  emergency_contact text not null default '' check (length(emergency_contact) <= 200),
  note text not null default '' check (length(note) <= 500),
  paid boolean not null default false,
  paid_at timestamptz,
  primary key (event_id, user_id),
  foreign key (event_id, user_id) references public.rsvps(event_id, user_id) on delete cascade
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index comments_event on public.comments (event_id, created_at);
create index comments_user on public.comments (user_id);

create table public.event_files (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  path text not null unique,
  name text not null check (length(name) <= 255),
  size bigint,
  mime text,
  uploaded_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index event_files_event on public.event_files (event_id);
create index event_files_uploader on public.event_files (uploaded_by);

-- Emails waiting to be sent by the edge function "api" (service role only).
create table public.outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  event_id uuid references public.events(id) on delete cascade,
  group_id uuid references public.groups(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  extra jsonb not null default '{}',
  created_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  attempts int not null default 0,
  error text
);
create index outbox_pending on public.outbox (id) where sent_at is null;
create index outbox_user on public.outbox (user_id);
create index outbox_event on public.outbox (event_id);
create index outbox_group on public.outbox (group_id);
create index outbox_actor on public.outbox (actor_id);

-- ---------------------------------------------------------------- permission helpers (schema private)
create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false)
$$;
create or replace function private.is_member(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships m where m.group_id = gid and m.user_id = auth.uid() and m.status = 'active')
$$;
create or replace function private.is_organizer(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin() or exists (select 1 from public.memberships m where m.group_id = gid and m.user_id = auth.uid()
    and m.status = 'active' and m.role in ('owner', 'organizer'))
$$;
create or replace function private.is_owner(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin() or exists (select 1 from public.memberships m where m.group_id = gid and m.user_id = auth.uid()
    and m.status = 'active' and m.role = 'owner')
$$;
-- Can see the group's events: public active group, or a member, or an organizer.
create or replace function private.can_see_group_content(gid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.groups g where g.id = gid and g.status = 'active'
    and (g.visibility = 'public' or private.is_member(gid))) or private.is_organizer(gid)
$$;
create or replace function private.can_see_event(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e where e.id = eid and (
    (e.status in ('approved', 'cancelled') and private.can_see_group_content(e.group_id))
    or (auth.uid() is not null and e.organizer_id = auth.uid())
    or private.is_organizer(e.group_id)))
$$;
-- Hosts: the person who created the event and the group's organizers.
create or replace function private.can_host(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e where e.id = eid and (
    (auth.uid() is not null and e.organizer_id = auth.uid()) or private.is_organizer(e.group_id)))
$$;
-- Attendee names, comments: hosts and active members of the group.
create or replace function private.can_see_attendees(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.can_host(eid) or exists (select 1 from public.events e where e.id = eid
    and e.status in ('approved', 'cancelled') and private.is_member(e.group_id))
$$;
create or replace function private.shares_group(uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships a join public.memberships b on b.group_id = a.group_id
    where a.user_id = auth.uid() and a.status = 'active' and b.user_id = uid and b.status = 'active')
$$;
create or replace function private.is_going(eid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.rsvps r where r.event_id = eid and r.user_id = auth.uid() and r.status = 'going')
$$;

-- ---------------------------------------------------------------- internal helpers
create or replace function private.enqueue(_uid uuid, _kind text, _eid uuid, _gid uuid, _extra jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare p public.profiles;
begin
  if _uid is null or _uid = auth.uid() then return; end if;
  select * into p from public.profiles where id = _uid;
  if _kind = 'event_new' and not coalesce(p.email_new_events, true) then return; end if;
  if _kind = 'reminder' and not coalesce(p.email_reminders, true) then return; end if;
  if _kind = 'comment' and not coalesce(p.email_comments, true) then return; end if;
  insert into public.outbox (user_id, kind, event_id, group_id, actor_id, extra)
  values (_uid, _kind, _eid, _gid, auth.uid(), coalesce(_extra, '{}'));
end $$;

create or replace function private.recount(eid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('app.sys', '1', true);
  update public.events e set
    going_count = (select count(*) from public.rsvps r where r.event_id = eid and r.status = 'going'),
    waitlist_count = (select count(*) from public.rsvps r where r.event_id = eid and r.status = 'waitlist')
  where e.id = eid;
  perform set_config('app.sys', '0', true);
end $$;

-- Move people from the waiting list to "going" while there is room.
create or replace function private.fill_from_waitlist(eid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.events; r record; room bigint;
begin
  select * into e from public.events where id = eid;
  if not found then return; end if;
  if e.status = 'approved' then
    room := case when e.max_people is null then 100000
      else greatest(e.max_people - (select count(*) from public.rsvps x where x.event_id = eid and x.status = 'going'), 0) end;
    for r in select x.user_id from public.rsvps x where x.event_id = eid and x.status = 'waitlist' order by x.created_at limit room loop
      update public.rsvps set status = 'going' where event_id = eid and user_id = r.user_id;
      perform private.enqueue(r.user_id, 'waitlist_promoted', eid, e.group_id);
    end loop;
  end if;
  perform private.recount(eid);
end $$;

-- When someone leaves or is removed from a group: drop their future sign-ups there.
create or replace function private.drop_future_rsvps(gid uuid, uid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select x.event_id from public.rsvps x join public.events e on e.id = x.event_id
    where e.group_id = gid and x.user_id = uid and e.ends_on >= (now() at time zone 'Europe/Rome')::date loop
    delete from public.rsvps where event_id = r.event_id and user_id = uid;
    perform private.fill_from_waitlist(r.event_id);
  end loop;
end $$;

create or replace function private.on_approved(e public.events) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if e.organizer_id is not null then  -- the host goes to their own event
    insert into public.rsvps (event_id, user_id, status) values (e.id, e.organizer_id, 'going') on conflict do nothing;
  end if;
  perform private.fill_from_waitlist(e.id);
  -- Tell the members (for a series, only about its first date).
  if e.series_id is null or not exists (select 1 from public.events x where x.series_id = e.series_id
      and x.id <> e.id and x.starts_on < e.starts_on) then
    for r in select m.user_id from public.memberships m where m.group_id = e.group_id and m.status = 'active'
      and m.user_id is distinct from e.organizer_id loop
      perform private.enqueue(r.user_id, 'event_new', e.id, e.group_id);
    end loop;
  end if;
end $$;

-- ---------------------------------------------------------------- triggers: profiles
create or replace function private.new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.new_user();

create or replace function private.profiles_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.id := old.id; new.created_at := old.created_at;
  if not private.is_admin() then new.is_admin := old.is_admin; end if;
  new.name := trim(new.name);
  if new.name is distinct from old.name then
    perform set_config('app.sys', '1', true);
    update public.events set organizer_name = new.name where organizer_id = new.id;
    perform set_config('app.sys', '0', true);
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles for each row execute function private.profiles_guard();

-- ---------------------------------------------------------------- triggers: groups
create or replace function private.groups_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('app.sys', true) = '1' then return new; end if;
  new.slug := lower(new.slug);
  if tg_op = 'INSERT' then
    if auth.uid() is null then raise exception 'Please sign in first'; end if;
    new.created_by := auth.uid(); new.created_at := now(); new.member_count := 0; new.admin_note := '';
    new.status := case when private.is_admin() then 'active' else 'pending' end;
    return new;
  end if;
  new.id := old.id; new.created_by := old.created_by; new.created_at := old.created_at; new.member_count := old.member_count;
  if not private.is_admin() then new.status := old.status; new.admin_note := old.admin_note; end if;
  return new;
end $$;
create trigger groups_guard before insert or update on public.groups for each row execute function private.groups_guard();

create or replace function private.groups_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if current_setting('app.sys', true) = '1' then return null; end if;
  if tg_op = 'INSERT' then
    insert into public.memberships (group_id, user_id, role, status) values (new.id, new.created_by, 'owner', 'active');
    if new.status = 'pending' then
      for r in select p.id from public.profiles p where p.is_admin loop
        perform private.enqueue(r.id, 'group_pending', null, new.id);
      end loop;
    end if;
  elsif new.status is distinct from old.status and new.status in ('active', 'rejected') then
    perform private.enqueue(new.created_by, 'group_decided', null, new.id, jsonb_build_object('status', new.status, 'note', new.admin_note));
  end if;
  return null;
end $$;
create trigger groups_after after insert or update on public.groups for each row execute function private.groups_after();

-- ---------------------------------------------------------------- triggers: memberships
create or replace function private.memberships_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare gid uuid := coalesce(new.group_id, old.group_id); r record;
begin
  perform set_config('app.sys', '1', true);
  update public.groups g set member_count = (select count(*) from public.memberships m where m.group_id = gid and m.status = 'active') where g.id = gid;
  perform set_config('app.sys', '0', true);
  if tg_op = 'INSERT' and new.status = 'pending' then
    for r in select m.user_id from public.memberships m where m.group_id = gid and m.status = 'active' and m.role in ('owner', 'organizer') loop
      perform private.enqueue(r.user_id, 'member_request', null, gid, jsonb_build_object('member', new.user_id));
    end loop;
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'active' then
    perform private.enqueue(new.user_id, 'member_approved', null, gid);
  end if;
  return null;
end $$;
create trigger memberships_after after insert or update or delete on public.memberships for each row execute function private.memberships_after();

-- ---------------------------------------------------------------- triggers: events
create or replace function private.events_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); org boolean; reason text;
begin
  if current_setting('app.sys', true) = '1' then return new; end if;
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if me is null then raise exception 'Please sign in first'; end if;
    org := private.is_organizer(new.group_id);
    new.organizer_id := me;
    new.organizer_name := coalesce((select p.name from public.profiles p where p.id = me), '');
    new.going_count := 0; new.waitlist_count := 0; new.admin_note := ''; new.cancel_reason := ''; new.created_at := now();
    if org then new.status := 'approved'; new.decided_at := now(); new.decided_by := me;
    else new.status := 'pending'; new.decided_at := null; new.decided_by := null; end if;
    return new;
  end if;
  new.id := old.id; new.group_id := old.group_id; new.series_id := old.series_id; new.organizer_id := old.organizer_id;
  new.organizer_name := old.organizer_name; new.going_count := old.going_count; new.waitlist_count := old.waitlist_count;
  new.created_at := old.created_at;
  if not private.is_organizer(old.group_id) then
    if me is null or old.organizer_id is distinct from me then raise exception 'Not allowed'; end if;
    if old.status = 'pending' then
      new.status := 'pending'; new.admin_note := old.admin_note; new.cancel_reason := old.cancel_reason;
    elsif old.status = 'approved' and new.status = 'cancelled' then
      reason := new.cancel_reason;          -- the host may only cancel an approved event
      new := old; new.status := 'cancelled'; new.cancel_reason := coalesce(reason, ''); new.updated_at := now();
    else
      raise exception 'This event has already been approved: only a group organizer can change it (you can still cancel it)';
    end if;
  end if;
  if new.status is distinct from old.status then
    new.decided_at := case when new.status = 'pending' then null else now() end;
    new.decided_by := case when new.status = 'pending' then null else me end;
  else
    new.decided_at := old.decided_at; new.decided_by := old.decided_by;
  end if;
  return new;
end $$;
create trigger events_guard before insert or update on public.events for each row execute function private.events_guard();

create or replace function private.events_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if current_setting('app.sys', true) = '1' then return null; end if;
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      for r in select m.user_id from public.memberships m where m.group_id = new.group_id and m.status = 'active' and m.role in ('owner', 'organizer') loop
        perform private.enqueue(r.user_id, 'event_pending', new.id, new.group_id);
      end loop;
    elsif new.status = 'approved' then
      perform private.on_approved(new);
    end if;
    return null;
  end if;
  if new.status is distinct from old.status then
    if old.status = 'pending' and new.status in ('approved', 'rejected') then
      perform private.enqueue(new.organizer_id, 'event_decided', new.id, new.group_id,
        jsonb_build_object('status', new.status, 'note', new.admin_note));
    end if;
    if new.status = 'approved' then perform private.on_approved(new); end if;
    if new.status = 'cancelled' then
      for r in select x.user_id from public.rsvps x where x.event_id = new.id loop
        perform private.enqueue(r.user_id, 'event_cancelled', new.id, new.group_id, jsonb_build_object('reason', new.cancel_reason));
      end loop;
    end if;
  elsif new.status = 'approved' then
    if (new.starts_on, new.ends_on, new.meet_time, new.meeting_point) is distinct from (old.starts_on, old.ends_on, old.meet_time, old.meeting_point) then
      for r in select x.user_id from public.rsvps x where x.event_id = new.id loop
        perform private.enqueue(r.user_id, 'event_changed', new.id, new.group_id);
      end loop;
    end if;
    if new.max_people is distinct from old.max_people then perform private.fill_from_waitlist(new.id); end if;
  end if;
  return null;
end $$;
create trigger events_after after insert or update on public.events for each row execute function private.events_after();

-- ---------------------------------------------------------------- triggers: comments
create or replace function private.comments_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = new.event_id;
  perform private.enqueue(e.organizer_id, 'comment', e.id, e.group_id, jsonb_build_object('body', left(new.body, 500)));
  return null;
end $$;
create trigger comments_after after insert on public.comments for each row execute function private.comments_after();

-- ---------------------------------------------------------------- RPCs (called by the page)
create or replace function public.join_group(gid uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); g public.groups; m public.memberships;
begin
  if me is null then raise exception 'Please sign in first'; end if;
  select * into g from public.groups where id = gid;
  if not found or (g.status <> 'active' and not private.is_admin()) then raise exception 'Group not found'; end if;
  select * into m from public.memberships where group_id = gid and user_id = me;
  if found then
    if m.status = 'banned' then raise exception 'You cannot join this group'; end if;
    return m.status;
  end if;
  insert into public.memberships (group_id, user_id, status)
  values (gid, me, case when g.join_policy = 'open' or private.is_admin() then 'active' else 'pending' end);
  return case when g.join_policy = 'open' or private.is_admin() then 'active' else 'pending' end;
end $$;

create or replace function public.leave_group(gid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); m public.memberships;
begin
  select * into m from public.memberships where group_id = gid and user_id = me;
  if not found then return; end if;
  if m.status = 'banned' then raise exception 'Not allowed'; end if;
  if m.role = 'owner' and not exists (select 1 from public.memberships x where x.group_id = gid and x.role = 'owner'
      and x.status = 'active' and x.user_id <> me) then
    raise exception 'You are the only owner: make someone else owner first';
  end if;
  perform private.drop_future_rsvps(gid, me);
  delete from public.memberships where group_id = gid and user_id = me;
end $$;

-- action: approve | remove | ban | unban | make_member | make_organizer | make_owner
create or replace function public.manage_member(gid uuid, uid uuid, action text) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.memberships;
begin
  if not private.is_organizer(gid) then raise exception 'Not allowed'; end if;
  select * into m from public.memberships where group_id = gid and user_id = uid;
  if not found then raise exception 'Member not found'; end if;
  if (m.role in ('owner', 'organizer') or action in ('make_organizer', 'make_owner', 'make_member')) and not private.is_owner(gid) then
    raise exception 'Only an owner can change organizers';
  end if;
  if m.role = 'owner' and action in ('remove', 'ban', 'make_member', 'make_organizer')
     and not exists (select 1 from public.memberships x where x.group_id = gid and x.role = 'owner' and x.status = 'active' and x.user_id <> uid) then
    raise exception 'A group needs at least one owner';
  end if;
  if action = 'approve' then update public.memberships set status = 'active' where group_id = gid and user_id = uid and status = 'pending';
  elsif action = 'remove' then perform private.drop_future_rsvps(gid, uid); delete from public.memberships where group_id = gid and user_id = uid;
  elsif action = 'ban' then perform private.drop_future_rsvps(gid, uid);
    update public.memberships set status = 'banned', role = 'member' where group_id = gid and user_id = uid;
  elsif action = 'unban' then delete from public.memberships where group_id = gid and user_id = uid and status = 'banned';
  elsif action = 'make_member' then update public.memberships set role = 'member' where group_id = gid and user_id = uid;
  elsif action = 'make_organizer' then update public.memberships set role = 'organizer' where group_id = gid and user_id = uid and status = 'active';
  elsif action = 'make_owner' then update public.memberships set role = 'owner' where group_id = gid and user_id = uid and status = 'active';
  else raise exception 'Unknown action'; end if;
end $$;

-- Sign up (going = true) or cancel (going = false). Returns 'going', 'waitlist' or 'none'.
create or replace function public.rsvp_set(eid uuid, going boolean, seats int default 0, ride boolean default false,
  emergency text default '', note text default '') returns text
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); e public.events; g public.groups; m public.memberships; cur public.rsvps; had boolean; st text;
begin
  if me is null then raise exception 'Please sign in first'; end if;
  select * into e from public.events where id = eid for update;
  if not found or not private.can_see_event(eid) then raise exception 'Event not found'; end if;
  select * into cur from public.rsvps where event_id = eid and user_id = me;
  had := found;
  if not going then
    if not had then return 'none'; end if;
    delete from public.rsvps where event_id = eid and user_id = me;
    perform private.fill_from_waitlist(eid);
    return 'none';
  end if;
  if e.status <> 'approved' then raise exception 'This event is not open for sign-ups'; end if;
  if e.ends_on < (now() at time zone 'Europe/Rome')::date then raise exception 'This event is over'; end if;
  if not had and e.rsvp_closes_at is not null and now() > e.rsvp_closes_at then raise exception 'Sign-ups are closed'; end if;
  select * into m from public.memberships where group_id = e.group_id and user_id = me;
  if not found then
    select * into g from public.groups where id = e.group_id;
    if g.join_policy = 'open' then insert into public.memberships (group_id, user_id) values (e.group_id, me);
    else raise exception 'This group approves new members: ask to join the group first'; end if;
  elsif m.status <> 'active' then raise exception 'Your membership of this group is not active yet';
  end if;
  if had then st := cur.status;
  else st := case when e.max_people is null or (select count(*) from public.rsvps x where x.event_id = eid and x.status = 'going') < e.max_people
    then 'going' else 'waitlist' end;
  end if;
  insert into public.rsvps (event_id, user_id, status, car_seats, needs_ride)
  values (eid, me, st, greatest(0, least(coalesce(seats, 0), 8)), coalesce(ride, false))
  on conflict (event_id, user_id) do update set car_seats = excluded.car_seats, needs_ride = excluded.needs_ride;
  insert into public.rsvp_private (event_id, user_id, emergency_contact, note)
  values (eid, me, left(trim(coalesce(emergency, '')), 200), left(trim(coalesce(note, '')), 500))
  on conflict (event_id, user_id) do update set emergency_contact = excluded.emergency_contact, note = excluded.note;
  perform private.recount(eid);
  return st;
end $$;

-- Hosts: action remove | paid | unpaid | promote
create or replace function public.rsvp_manage(eid uuid, uid uuid, action text) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if not private.can_host(eid) then raise exception 'Not allowed'; end if;
  select * into e from public.events where id = eid for update;
  if not exists (select 1 from public.rsvps where event_id = eid and user_id = uid) then raise exception 'Not signed up'; end if;
  if action = 'remove' then
    delete from public.rsvps where event_id = eid and user_id = uid;
    perform private.fill_from_waitlist(eid);
  elsif action in ('paid', 'unpaid') then
    insert into public.rsvp_private (event_id, user_id, paid, paid_at) values (eid, uid, action = 'paid', case when action = 'paid' then now() end)
    on conflict (event_id, user_id) do update set paid = excluded.paid, paid_at = excluded.paid_at;
  elsif action = 'promote' then
    update public.rsvps set status = 'going' where event_id = eid and user_id = uid and status = 'waitlist';
    if found then perform private.enqueue(uid, 'waitlist_promoted', eid, e.group_id); end if;
    perform private.recount(eid);
  else raise exception 'Unknown action'; end if;
end $$;

-- Platform administrators: everyone with their email.
create or replace function public.admin_people() returns table (id uuid, email text, name text, is_admin boolean,
  created_at timestamptz, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  return query select u.id, u.email::text, coalesce(p.name, ''), coalesce(p.is_admin, false), u.created_at, u.last_sign_in_at
    from auth.users u left join public.profiles p on p.id = u.id order by lower(coalesce(p.name, '')), u.email;
end $$;

create or replace function public.admin_set_admin(uid uuid, val boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Not allowed'; end if;
  if not val and uid = auth.uid() then raise exception 'You cannot remove yourself'; end if;
  update public.profiles set is_admin = val where id = uid;
end $$;

-- "Download my data" (GDPR right of access).
create or replace function public.my_data() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'exported_at', now(),
    'email', (select u.email from auth.users u where u.id = auth.uid()),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'memberships', coalesce((select jsonb_agg(jsonb_build_object('group', g.name, 'role', m.role, 'status', m.status, 'since', m.created_at))
      from public.memberships m join public.groups g on g.id = m.group_id where m.user_id = auth.uid()), '[]'),
    'events_created', coalesce((select jsonb_agg(to_jsonb(e)) from public.events e where e.organizer_id = auth.uid()), '[]'),
    'sign_ups', coalesce((select jsonb_agg(jsonb_build_object('event', e.title, 'date', e.starts_on, 'status', r.status,
      'car_seats', r.car_seats, 'needs_ride', r.needs_ride, 'emergency_contact', rp.emergency_contact, 'note', rp.note, 'paid', rp.paid))
      from public.rsvps r join public.events e on e.id = r.event_id
      left join public.rsvp_private rp on rp.event_id = r.event_id and rp.user_id = r.user_id where r.user_id = auth.uid()), '[]'),
    'comments', coalesce((select jsonb_agg(jsonb_build_object('event', e.title, 'body', c.body, 'at', c.created_at))
      from public.comments c join public.events e on e.id = c.event_id where c.user_id = auth.uid()), '[]')
  )
$$;

-- Used by the edge function only: claim emails to send.
create or replace function public.outbox_claim(n int default 25) returns table (id bigint, kind text, email text, name text,
  event_id uuid, group_id uuid, actor_name text, extra jsonb)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with c as (
    update public.outbox o set locked_at = now(), attempts = o.attempts + 1
    where o.id in (select x.id from public.outbox x where x.sent_at is null and x.attempts < 5
      and (x.locked_at is null or x.locked_at < now() - interval '5 minutes') order by x.id limit n for update skip locked)
    returning o.*)
  select c.id, c.kind, u.email::text, coalesce(p.name, ''), c.event_id, c.group_id, coalesce(ap.name, ''), c.extra
  from c join auth.users u on u.id = c.user_id
  left join public.profiles p on p.id = c.user_id left join public.profiles ap on ap.id = c.actor_id;
end $$;

-- Daily: reminders for tomorrow's events, cleanup of old emails.
create or replace function private.queue_reminders() returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.outbox (user_id, kind, event_id, group_id)
  select r.user_id, 'reminder', e.id, e.group_id from public.events e
  join public.rsvps r on r.event_id = e.id and r.status = 'going'
  join public.profiles p on p.id = r.user_id and p.email_reminders
  where e.status = 'approved' and e.starts_on = (now() at time zone 'Europe/Rome')::date + 1
    and not exists (select 1 from public.outbox o where o.kind = 'reminder' and o.event_id = e.id and o.user_id = r.user_id);
  delete from public.outbox where created_at < now() - interval '60 days' and (sent_at is not null or attempts >= 5);
end $$;

-- ---------------------------------------------------------------- privileges
revoke all on all functions in schema private from public, anon, authenticated;
grant usage on schema private to anon, authenticated;
grant execute on function private.is_admin(), private.is_member(uuid), private.is_organizer(uuid), private.is_owner(uuid),
  private.can_see_group_content(uuid), private.can_see_event(uuid), private.can_host(uuid), private.can_see_attendees(uuid),
  private.shares_group(uuid), private.is_going(uuid) to anon, authenticated;

revoke all on function public.join_group(uuid), public.leave_group(uuid), public.manage_member(uuid, uuid, text),
  public.rsvp_set(uuid, boolean, int, boolean, text, text), public.rsvp_manage(uuid, uuid, text),
  public.admin_people(), public.admin_set_admin(uuid, boolean), public.my_data(), public.outbox_claim(int) from public, anon;
grant execute on function public.join_group(uuid), public.leave_group(uuid), public.manage_member(uuid, uuid, text),
  public.rsvp_set(uuid, boolean, int, boolean, text, text), public.rsvp_manage(uuid, uuid, text),
  public.admin_people(), public.admin_set_admin(uuid, boolean), public.my_data() to authenticated;
revoke all on function public.outbox_claim(int) from authenticated;
grant execute on function public.outbox_claim(int) to service_role;

revoke all on public.outbox from anon, authenticated;
revoke insert, update, delete on public.memberships, public.rsvps, public.rsvp_private from anon, authenticated;
revoke insert, update, delete on public.profiles, public.groups, public.events, public.event_private, public.comments, public.event_files from anon;
revoke insert, delete on public.profiles from authenticated;

-- ---------------------------------------------------------------- row level security
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.memberships enable row level security;
alter table public.events enable row level security;
alter table public.event_private enable row level security;
alter table public.rsvps enable row level security;
alter table public.rsvp_private enable row level security;
alter table public.comments enable row level security;
alter table public.event_files enable row level security;
alter table public.outbox enable row level security;

create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.is_admin() or private.shares_group(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid()) or private.is_admin()) with check (id = (select auth.uid()) or private.is_admin());

create policy groups_read on public.groups for select to anon, authenticated
  using (status = 'active' or created_by = (select auth.uid()) or private.is_admin());
create policy groups_insert on public.groups for insert to authenticated with check ((select auth.uid()) is not null);
create policy groups_update on public.groups for update to authenticated using (private.is_owner(id)) with check (private.is_owner(id));
create policy groups_delete on public.groups for delete to authenticated using (private.is_owner(id));

create policy memberships_read on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or (status = 'active' and private.is_member(group_id)) or private.is_organizer(group_id));

create policy events_read on public.events for select to anon, authenticated
  using ((status in ('approved', 'cancelled') and private.can_see_group_content(group_id))
    or organizer_id = (select auth.uid()) or private.is_organizer(group_id));
create policy events_insert on public.events for insert to authenticated
  with check (private.is_organizer(group_id) or (private.is_member(group_id)
    and exists (select 1 from public.groups g where g.id = group_id and g.status = 'active' and g.members_can_propose)));
create policy events_update on public.events for update to authenticated
  using (private.is_organizer(group_id) or organizer_id = (select auth.uid()))
  with check (private.is_organizer(group_id) or organizer_id = (select auth.uid()));
create policy events_delete on public.events for delete to authenticated
  using (private.is_organizer(group_id) or (organizer_id = (select auth.uid()) and status = 'pending'));

create policy event_private_read on public.event_private for select to authenticated
  using (private.can_host(event_id) or private.is_going(event_id));
create policy event_private_insert on public.event_private for insert to authenticated with check (private.can_host(event_id));
create policy event_private_update on public.event_private for update to authenticated
  using (private.can_host(event_id)) with check (private.can_host(event_id));

create policy rsvps_read on public.rsvps for select to authenticated
  using (user_id = (select auth.uid()) or private.can_see_attendees(event_id));
create policy rsvp_private_read on public.rsvp_private for select to authenticated
  using (user_id = (select auth.uid()) or private.can_host(event_id));

create policy comments_read on public.comments for select to authenticated using (private.can_see_attendees(event_id));
create policy comments_insert on public.comments for insert to authenticated
  with check (user_id = (select auth.uid()) and private.can_see_attendees(event_id));
create policy comments_delete on public.comments for delete to authenticated
  using (user_id = (select auth.uid()) or private.can_host(event_id));

create policy files_read on public.event_files for select to anon, authenticated using (private.can_see_event(event_id));
create policy files_insert on public.event_files for insert to authenticated
  with check (private.can_host(event_id) and uploaded_by = (select auth.uid()));
create policy files_delete on public.event_files for delete to authenticated using (private.can_host(event_id));

alter policy "event files read" on storage.objects to anon, authenticated
  using (bucket_id = 'event-files' and private.can_see_event(((storage.foldername(name))[1])::uuid));
alter policy "event files upload" on storage.objects to authenticated
  with check (bucket_id = 'event-files' and private.can_host(((storage.foldername(name))[1])::uuid));
alter policy "event files delete" on storage.objects to authenticated
  using (bucket_id = 'event-files' and private.can_host(((storage.foldername(name))[1])::uuid));

-- ---------------------------------------------------------------- move the old data
select set_config('app.sys', '1', false);
insert into public.profiles (id) select id from auth.users on conflict do nothing;
update public.profiles p set name = o.name, is_admin = true
  from legacy.organizers o join auth.users u on lower(u.email) = o.email where o.role = 'admin' and u.id = p.id;
insert into public.groups (slug, name, description, area, status, created_by)
select 'meetup-hiking', 'Meetup Hiking',
  'Hikes in the mountains for everyone: from easy walks to equipped routes. Join the group, sign up for the next outing and meet new people on the trail.',
  '', 'active', (select u.id from legacy.organizers o join auth.users u on lower(u.email) = o.email where o.role = 'admin' order by o.created_at limit 1);
insert into public.memberships (group_id, user_id, role)
select g.id, u.id, 'owner' from legacy.organizers o join auth.users u on lower(u.email) = o.email
  cross join public.groups g where o.role = 'admin' and g.slug = 'meetup-hiking';
insert into public.events (id, group_id, title, description, starts_on, ends_on, meeting_point, max_people, status, admin_note,
  organizer_id, organizer_name, created_at, updated_at, decided_at)
select e.id, g.id, e.title, e.description, e.starts_on, e.ends_on, e.meeting_point, e.max_people, e.status, e.admin_note,
  u.id, coalesce(e.organizer_name, ''), e.created_at, e.updated_at, e.decided_at
from legacy.events e left join auth.users u on lower(u.email) = e.organizer_email cross join public.groups g where g.slug = 'meetup-hiking';
update public.groups g set member_count = (select count(*) from public.memberships m where m.group_id = g.id and m.status = 'active');
select set_config('app.sys', '0', false);

-- ---------------------------------------------------------------- schedules
select cron.schedule('meetup-flush-outbox', '* * * * *', $cron$
  select net.http_post(url := 'https://quzothoggtwvuvglyeph.supabase.co/functions/v1/api?a=flush',
    body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb)
  where exists (select 1 from public.outbox where sent_at is null and attempts < 5)
$cron$);
select cron.schedule('meetup-reminders', '7 15 * * *', $cron$ select private.queue_reminders() $cron$);
