# Meetup Hiking

Read the README first. The owner writes in Italian; everything in the repository and
the interface is in English (owner's request, 2026-11-10).

- One page, `index.html`, no build step. Change `const BUILD` on every change.
- Supabase project id `quzothoggtwvuvglyeph` (org Ensei). Every schema change: a new
  migration in `supabase/migrations/` + `apply_migration`, then `get_advisors`.
- The permission helper functions live in schema `private` (not exposed by the API).
- Never personal data (emails, names) in the repository: the first admin was added by hand.
- Publishing: push to `main` → GitHub Pages (workflow `pages.yml`). The repository is
  public: no secrets, no personal data.
- User text always goes through `esc()` before `innerHTML`.
- Must work on a phone (390 px, no sideways scroll).
