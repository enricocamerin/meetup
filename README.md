# Meetup Hiking · event requests

A public portal to request hiking events. Anyone signs in with their email (a
sign-in link, no password), sees the calendar of approved events, requests an event
and uploads files (GPX, PDF, posters). The administrator gets an email, approves or
rejects, and the requester gets an email with the answer
(function `supabase/functions/notify-decision`, Gmail SMTP, secrets SMTP_USER / SMTP_PASS).

- `index.html`: the whole app (HTML, CSS, JS, no build step). Libraries from jsdelivr,
  pinned: supabase-js 2.45.4 (MIT), FullCalendar 6.1.15 (MIT).
- Data, sign-in and files: Supabase project `meetup` (eu-west-1). Schema and
  permissions in `supabase/migrations/`. The key in the page is the public one: the
  data is protected by Row Level Security rules.
- Site: GitHub Pages, https://enricocamerin.github.io/meetup/ (public repository;
  `.github/workflows/pages.yml` publishes only `index.html` and `robots.txt` on every
  push to `main`). Since 2026-11-10; before that it was on Netlify (`meetup-hiking`,
  stopped when the account ran out of credits). `_headers` and `_redirects` are for
  Netlify and are not used on Pages.

## Who can do what

| | Anyone signed in | Admin |
|---|---|---|
| See approved events and their files | ✓ | ✓ |
| See other people's requests | | ✓ |
| Request an event (starts as "pending") | ✓ | ✓ |
| Edit / delete their own event | only while pending | always |
| Upload files to an event | only their own | all |
| Approve / reject / set back to pending | | ✓ |
| Make others admin, remove people | | ✓ |

The first time someone signs in they are added to the `organizers` table
automatically (`ensure_me`) and asked for their name, which is shown on events
instead of their email.
