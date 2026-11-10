# Meetup Hiking · calendario organizzatori

Portale per gli organizzatori di escursioni: ognuno entra con la sua email (link
senza password), vede il calendario, propone un evento nei giorni liberi e carica i
file (GPX, PDF, locandine). L'amministratore approva o rifiuta.

- `index.html`: tutta l'app (HTML, CSS, JS, nessun build). Librerie da jsdelivr con
  versione fissa: supabase-js 2.45.4 (MIT), FullCalendar 6.1.15 (MIT).
- Dati, login e file: Supabase, progetto `meetup` (eu-west-1). Schema e permessi in
  `supabase/migrations/`. La chiave nella pagina è quella pubblica: i dati sono
  protetti dalle regole Row Level Security.
- Sito: Netlify (statico, pubblica la radice del repository).

## Chi può fare cosa

| | Organizzatore | Admin |
|---|---|---|
| Vede il calendario e i file | ✓ | ✓ |
| Propone un evento (nasce "in attesa") | ✓ | ✓ |
| Modifica / elimina il suo evento | solo finché è in attesa | sempre |
| Carica file su un evento | solo sui suoi | su tutti |
| Approva / rifiuta / rimette in attesa | | ✓ |
| Aggiunge o toglie organizzatori | | ✓ |

Solo le email nella tabella `organizers` vedono qualcosa; chiunque altro, anche se
riceve il link, vede "Accesso non abilitato".
