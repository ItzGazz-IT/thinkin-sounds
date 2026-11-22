import { projectUrl, publishableKey } from './account-config.js';

const get = id => document.getElementById(id);
const status = get('admin-status');
const section = get('admin-bookings');
const list = get('admin-booking-list');
const previous = get('previous-bookings');
const next = get('next-bookings');
const refresh = get('refresh-bookings');
const formatter = new Intl.DateTimeFormat('en-ZA', {
  timeZone: 'Africa/Johannesburg', dateStyle: 'full', timeStyle: 'short'
});
const limit = 50;
let client;
let offset = 0;
let loadId = 0;
let busy = false;

function action(label, decide) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = label === 'Confirm booking' ? 'button' : 'account-text-button';
  button.textContent = label;
  button.addEventListener('click', decide);
  return button;
}

function renderBooking(booking) {
  const item = document.createElement('li');
  const details = document.createElement('div');
  details.className = 'admin-booking-details';
  const when = document.createElement('strong');
  when.textContent = formatter.format(new Date(booking.starts_at)) + ' SAST';
  const clientDetails = document.createElement('p');
  clientDetails.textContent = `${booking.client_email} · ${booking.hours}h · ${booking.headcount} attending`;
  const state = document.createElement('p');
  const labels = { requested: 'Pending', confirmed: 'Confirmed', declined: 'Declined', cancelled: 'Cancelled' };
  state.textContent = labels[booking.status];
  if (booking.confirmation_email) state.textContent += ` · Confirmation email: ${booking.confirmation_email.toLowerCase()}`;
  details.append(when, clientDetails, state);
  item.append(details);

  if (booking.status === 'requested') {
    const actions = document.createElement('div');
    actions.className = 'account-actions';
    const decide = async decision => {
      if (busy) return;
      if (!window.confirm(decision === 'confirmed' ? 'Confirm this booking and email the customer?' : 'Decline this booking request?')) return;
      busy = true;
      list.querySelectorAll('button').forEach(button => { button.disabled = true; });
      try {
        const { error } = await client.rpc('admin_decide_studio_booking', { booking_id: booking.id, decision });
        if (error) {
          status.textContent = error.message;
          return;
        }
        await loadBookings(decision === 'confirmed' ? 'Booking confirmed. Customer email queued.' : 'Booking declined.');
      } catch {
        status.textContent = 'Could not update the booking. Refresh to check its status.';
      } finally {
        busy = false;
        list.querySelectorAll('button').forEach(button => { button.disabled = false; });
      }
    };
    actions.append(action('Confirm booking', () => decide('confirmed')), action('Decline', () => decide('declined')));
    item.append(actions);
  }
  return item;
}

async function loadBookings(message = '') {
  const id = ++loadId;
  status.textContent = 'Loading bookings…';
  previous.disabled = next.disabled = refresh.disabled = true;
  const { data, error } = await client.rpc('admin_studio_bookings', { page_offset: offset });
  if (id !== loadId) return;
  refresh.disabled = false;
  if (error) {
    if (error.code === '42501') {
      section.hidden = true;
      list.replaceChildren();
      status.textContent = 'This studio account does not have staff access.';
    } else {
      status.textContent = 'Could not load bookings. Try refreshing.';
    }
    return;
  }
  section.hidden = false;
  const visible = data.slice(0, limit);
  list.replaceChildren(...visible.map(renderBooking));
  if (!visible.length) {
    const item = document.createElement('li');
    item.textContent = 'No bookings on this page.';
    list.append(item);
  }
  previous.disabled = offset === 0;
  next.disabled = data.length <= limit;
  status.textContent = message;
}

previous.addEventListener('click', () => { offset -= limit; void loadBookings(); });
next.addEventListener('click', () => { offset += limit; void loadBookings(); });
refresh.addEventListener('click', () => { void loadBookings(); });

try {
  const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.2/+esm');
  client = createClient(projectUrl, publishableKey);
  client.auth.onAuthStateChange((event, session) => {
    if (!session) {
      loadId++;
      section.hidden = true;
      list.replaceChildren();
      get('admin-login').hidden = false;
      status.textContent = 'Sign in with your studio staff account.';
    } else if (event === 'INITIAL_SESSION' || event === 'SIGNED_IN') {
      get('admin-login').hidden = true;
      setTimeout(() => { void loadBookings(); }, 0);
    }
  });
} catch {
  status.textContent = 'The booking dashboard could not load. Try refreshing.';
}
