# Meetup Hiking · calendario organizzatori

Portale pubblico per richiedere escursioni (interfaccia in inglese): chiunque entra
con la sua email (link senza password), vede il calendario degli eventi approvati,
chiede un evento e carica i file (GPX, PDF, locandine). L'amministratore riceve
un'email, approva o rifiuta, e chi ha chiesto riceve l'email con la risposta
(funzione `supabase/functions/notify-decision`, Gmail SMTP, segreti SMTP_USER / SMTP_PASS).

- `index.html`: tutta l'app (HTML, CSS, JS, nessun build). Librerie da jsdelivr con
  versione fissa: supabase-js 2.45.4 (MIT), FullCalendar 6.1.15 (MIT).
- Dati, login e file: Supabase, progetto `meetup` (eu-west-1). Schema e permessi in
  `supabase/migrations/`. La chiave nella pagina è quella pubblica: i dati sono
  protetti dalle regole Row Level Security.
- Sito: GitHub Pages, https://enricocamerin.github.io/meetup/ (repository pubblico; `.github/workflows/pages.yml` pubblica solo `index.html` e `robots.txt` a ogni push su `main`). Dal 2026-11-10, prima era su Netlify (`meetup-hiking`, fermo per crediti esauriti). `_headers` e `_redirects` restano per Netlify e non servono su Pages.

## Chi può fare cosa

| | Chi si iscrive | Admin |
|---|---|---|
| Vede gli eventi approvati e i loro file | ✓ | ✓ |
| Vede le richieste degli altri | | ✓ |
| Propone un evento (nasce "in attesa") | ✓ | ✓ |
| Modifica / elimina il suo evento | solo finché è in attesa | sempre |
| Carica file su un evento | solo sui suoi | su tutti |
| Approva / rifiuta / rimette in attesa | | ✓ |
| Nomina altri admin, toglie persone | | ✓ |

Chi entra per la prima volta viene aggiunto da solo alla tabella `organizers`
(`ensure_me`) e gli si chiede il nome, che compare sugli eventi al posto dell'email.
