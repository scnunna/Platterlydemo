# Platterly Catering

Catering and lead capture for local franchise kitchens. Clients: **Panago** (Gerrard St W and Bremner Blvd, Toronto) and
**Wetzel's Pretzels** (CF Toronto Eaton Centre).

| What | Where |
|---|---|
| Panago Spin & Win (the page every QR code opens) | https://godsmustb.github.io/platterlycatering/panago/ |
| Wetzel's Spin & Win (Eaton Centre) | https://godsmustb.github.io/platterlycatering/wetzels/ |
| Platterly ordering (with a PL- code) | https://godsmustb.github.io/platterlycatering/order/ |
| Leads portal: super admin, client admin, customer | https://godsmustb.github.io/platterlycatering/admin/ |
| Panago TV screens, six pages, window loop | https://godsmustb.github.io/platterlycatering/panago/tv/?s=g#tv (Gerrard) · `?s=b#tv` (Bremner) |
| Platterly catering app (demo mode) | https://godsmustb.github.io/platterlycatering/ |
| Android app (Obtainium) | GitHub Releases of this repo |

## Install on Android with Obtainium
Obtainium → **Add app** → paste `https://github.com/godsmustb/platterlycatering` → **Add**. Every push to `main`
that changes the app or the pages builds a signed APK and publishes a release; Obtainium picks it up.
The app opens on a start screen: Platterly, Spin & Win, or the TV loop for one store. On a store TV box, tick
"Open the TV screens automatically" once and it boots straight into the loop.

## How a lead is captured (Platterly codes and points)
Platterly is the platform: Panago Ontario and Wetzel's Toronto Eaton Centre partner with Platterly for marketing.
Codes (`PL-XXXXXX`) and credit points are Platterly's, not the stores'.
1. A customer scans the code on the TV (each code carries the store and the page, e.g. `?s=g&c=2`).
2. They spin free on their phone. Every spin wins a menu item that unlocks with a purchase.
3. They join with a first name and choose how we reach them: **email, text, or both** (both makes a fuller profile;
   one is enough). Marketing consent is a separate, unticked box naming Platterly and the partner store (CASL).
   A second box (on by default) asks for **one reminder** when the 2-hour bonus window ends. That one is a service
   message about their code, not marketing.
4. One quiz question: a right answer upsizes the prize. Anyone who spun with Platterly on an earlier day, at any
   partner, is upsized automatically.
5. The database issues a single-use Platterly code, valid **until the store closes** that day. The first **2 hours**
   are the fast-claim window: using the code in time earns **+100 Platterly points**. When the 2 hours end, the page
   switches to a countdown to closing time and the reminder goes out.
6. From the prize screen they can **order now through Platterly** (`web/order/`): pickup, or delivery where the store
   offers it, at the same price as the counter, no delivery fee. The prize applies automatically when the order
   qualifies; points pay part or all of it (100 points = $1). Payment is not taken online: pay at the store or the
   driver (a card form is shown as a demo only). The order appears in the store's **Orders** tab in the portal.
7. Points: 5 per $1 of food on a completed order or a counter redemption with the order total entered, plus the
   fast-claim bonus. One Platterly member per person across partners (matched by email or phone).

## Reminders
`server/lead-proxy.mjs` sends due reminders every minute. Without a sender configured, emails go to the local test
inbox (Mailpit, http://127.0.0.1:56324) and are marked `test_inbox`: **they do not reach customers**. To send for
real, create `%LOCALAPPDATA%\platterly\mail.env` (never commit it) and restart with `server\start.ps1 -RestartProxy`:
```
PLATTERLY_MAIL=resend
RESEND_API_KEY=re_...
PLATTERLY_MAIL_FROM=Platterly <codes@your-domain>
TWILIO_ACCOUNT_SID=AC...
TWILIO_AUTH_TOKEN=...
TWILIO_FROM=+1...
```

## Lead database (runs on the store laptop)
`supabase/` is a self-hosted Supabase CLI stack (`project_id = platterly`, ports 563xx) in Docker Desktop.
Tables are locked; the public can only call `submit_claim` (and the older `submit_lead`), `request_catering`, `customer_history`, `code_info`, `menu_for`, `quote_order`, `place_order` and `order_status`. Prices are always computed in the database. Staff redemption
(`redeem_code`) is service-role only. Tests: `supabase/tests/leads_test.sql`, `staff_test.sql`, `onboarding_test.sql`, `orders_test.sql`.

```
docker exec -i supabase_db_platterly psql -U postgres -v ON_ERROR_STOP=1 -q < supabase/tests/leads_test.sql
```

`server/lead-proxy.mjs` is the only thing exposed to the internet: a fixed list of POST routes, an origin allow-list,
an 8 KB body cap and per-IP limits. It adds the database key itself, so no key is in this repo.
`server/start.ps1` starts Docker, the database, the proxy and a Cloudflare tunnel, then publishes the tunnel
address to `web/panago/api.json` (a commit) so the QR page can find it. Safe to re-run; it exits when healthy.

```powershell
powershell -ExecutionPolicy Bypass -File server\start.ps1          # start or repair now
```

To run it automatically at logon and every 30 minutes, register a scheduled task named `Platterly-Leads`
that runs the line above (Task Scheduler, or `Register-ScheduledTask` in an elevated PowerShell).

If the laptop is off, the QR page still works: the prize is held on the phone and the sign-up is sent the
next time the customer opens the page. Leads are only captured live while the laptop is on.

Owner views: Supabase Studio at http://127.0.0.1:56323 (local only) → `lead_summary`, `spins`, `catering_requests`.

## Brand
Panago tokens and assets: `web/panago/brand.json`, `web/panago/assets/` (mirrors the Content Studio client `panago`).
Prices: Panago Ontario menu PL4, regular pricing as of October 2026.

## Onboarding a new client
The portal's **Onboarding** tab (super admin only; the database refuses anyone else) is a Kanban board of every
client's journey: 7 stages, 25 steps (`supabase/migrations/20261015000200_onboarding.sql`). A client's card sits in the
first stage with an open step. Open a card for its checklist: tick steps, keep notes, and see live facts
(leads, redemptions, whether the owner has signed in).

To add a client: insert it into `clients` (id, name, two-letter `code_prefix`, `brand_color`), its `stores` and six
`offers` whose odds add up to 100 (see `supabase/seed.sql`), copy a lead page (`web/wetzels/` is the template),
then create the owner's account:
```
docker exec supabase_db_platterly psql -U postgres -c "select staff_upsert('owner@example.com', 'Owner name', 'client_admin', '<client id>', '<12+ char password>')"
```
Research and brand for each client live next to its page: `web/<client>/menu.json`, `web/<client>/brand.json`.
