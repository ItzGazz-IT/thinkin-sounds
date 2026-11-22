# Thinkin’ Sounds website

Static first-stage website for Thinkin’ Sounds Recording Studio, built from the supplied developer brief and brand asset kit.

## Preview locally

Serve the `dist` directory with any static HTTP server. The published build uses `dist` directly.

## Current scope

- Responsive brand-led landing page
- Service and proposed pricing overview
- Studio booking rules
- Provisional engineer profiles and portraits
- Full ItzGazz Beat Shop and three rotating homepage previews
- Validated enquiry form UI with service preselection
- Direct phone and location details

## Before public launch

- Confirm portrait assignments
- Confirm service prices, licence terms and booking terms
- Connect the enquiry form to the approved inbox or form service
- Add approved privacy and booking/legal pages
- Add catalogue, preview audio, checkout, verified-payment fulfilment and order management
- Test successful, pending and failed payment paths before enabling downloads

## Studio accounts and scheduling

The account page is available locally at `/account.html`. Keep the existing
public booking links in place until email confirmation and booking requests
have been tested with the production backend.

1. Create a Supabase project and apply `supabase/booking.sql` through its SQL
   Editor. Set the Authentication site URL to the published site and allow
   the exact published `account.html` URL for confirmation and reset links.
   Configure a production email sender and verify that both links arrive.
2. Add each independently bookable room to `studio_rooms`. Add its working
   hours to `studio_hours`, using 0 for Sunday and 6 for Saturday. Opening and
   closing times are Johannesburg time. Leave closed days out. Add holidays
   and maintenance as time ranges in `studio_blackouts`.
3. Set the project URL and publishable key in `dist/account-config.js`.
4. Sign up with a test email, confirm the account, submit a booking request
   and confirm it in the Supabase Table Editor. With a second test account,
   check that the time is unavailable and the first client's request is
   private. Verify that a password reset works before linking the page from
   the live site.

Studio staff review requests in `studio_bookings` and use `auth.users` to look
up client emails in the project dashboard. Set the status to `confirmed` only
after agreeing the scope and deposit. Requested slots remain available until
a request is confirmed. The database prevents overlapping confirmed bookings
in the same room. Use `declined` or `cancelled` to close other requests.
