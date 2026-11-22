import { projectUrl, publishableKey } from './account-config.js';

const get = id => document.getElementById(id);
const status = get('admin-status');
const section = get('admin-bookings');
const list = get('admin-booking-list');
const previous = get('previous-bookings');
const next = get('next-bookings');
const refresh = get('refresh-bookings');
const declineDialog = get('decline-dialog');
const declineReason = get('decline-reason');
let pendingDecline;
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
  if (booking.confirmation_email) state.textContent += ` · Customer email: ${booking.confirmation_email.toLowerCase()}`;
  details.append(when, clientDetails, state);
  item.append(details);

  if (booking.status === 'requested') {
    const actions = document.createElement('div');
    actions.className = 'account-actions';
    actions.append(action('Confirm booking', () => {
      if (!busy && window.confirm('Confirm this booking and email the customer?')) {
        void decideBooking(booking.id, 'confirmed');
      }
    }), action('Decline', () => {
      if (busy) return;
      pendingDecline = booking.id;
      declineReason.value = '';
      declineReason.setCustomValidity('');
      declineDialog.showModal();
    }));
    item.append(actions);
  }
  return item;
}

async function decideBooking(bookingId, decision, reason) {
  if (busy) return;
  busy = true;
  const buttons = [...list.querySelectorAll('button'), get('submit-decline'), get('cancel-decline')];
  buttons.forEach(button => { button.disabled = true; });
  try {
    const decline = decision === 'declined';
    const { error } = decline
      ? await client.rpc('admin_decline_studio_booking', { booking_id: bookingId, reason })
      : await client.rpc('admin_decide_studio_booking', { booking_id: bookingId, decision });
    if (decline) declineDialog.close();
    if (error) {
      status.textContent = error.message;
      return;
    }
    await loadBookings(decline ? 'Booking declined. Customer email queued.' : 'Booking confirmed. Customer email queued.');
  } catch {
    if (declineDialog.open) declineDialog.close();
    status.textContent = 'Could not update the booking. Refresh to check its status.';
  } finally {
    busy = false;
    buttons.forEach(button => { button.disabled = false; });
  }
}

declineReason.addEventListener('input', () => declineReason.setCustomValidity(''));
get('cancel-decline').addEventListener('click', () => declineDialog.close());
declineDialog.addEventListener('cancel', event => {
  if (busy) event.preventDefault();
});
get('decline-form').addEventListener('submit', event => {
  event.preventDefault();
  const reason = declineReason.value.trim();
  if (!reason) {
    declineReason.setCustomValidity('Enter a reason for declining this booking.');
    declineReason.reportValidity();
    return;
  }
  void decideBooking(pendingDecline, 'declined', reason);
});

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
