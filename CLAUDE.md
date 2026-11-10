# Meetup Hiking

Leggi prima il README. Il proprietario scrive in italiano; l'interfaccia è in inglese (richiesta del proprietario, 2026-11-10).

- Una sola pagina, `index.html`, senza build. Cambia `const BUILD` a ogni modifica.
- Supabase project id `quzothoggtwvuvglyeph` (org Ensei). Ogni modifica allo schema:
  nuova migrazione in `supabase/migrations/` + `apply_migration`, poi `get_advisors`.
- Le funzioni dei permessi stanno nello schema `private` (non esposto dall'API).
- Mai dati personali (email, nomi) nel repository: il primo admin è stato inserito a mano.
- Pubblicazione: push su `main` → GitHub Pages (workflow `pages.yml`). Il repository è pubblico: niente segreti, niente dati personali.
- Testo dell'utente sempre attraverso `esc()` prima di `innerHTML`.
- Deve funzionare sul telefono (390 px senza scorrimento laterale).
