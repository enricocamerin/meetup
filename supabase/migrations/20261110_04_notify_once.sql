-- Applied 2026-11-10 (migrations "notify_once" and "notify_once_guard").
-- Remember which emails were already sent, so a double click never sends twice.
alter table public.events add column if not exists notified_new boolean not null default false;
alter table public.events add column if not exists notified_status text not null default '';
-- private.events_guard() was replaced with the version in 20261110_03_public_requests.sql
-- plus these lines right after "new.updated_at := now();" (users cannot touch the marks):
--   if tg_op = 'INSERT' then
--     new.notified_new := false; new.notified_status := '';
--   else
--     new.notified_new := old.notified_new; new.notified_status := old.notified_status;
--   end if;
