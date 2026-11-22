import { projectUrl, publishableKey } from './account-config.js';
import { createStudioCalendar } from './admin-calendar.js';

const get = id => document.getElementById(id);
const status = get('admin-status');
const section = get('admin-bookings');
const list = get('admin-booking-list');
const previous = get('previous-bookings');
const next = get('next-bookings');
const refresh = get('refresh-bookings');
const declineDialog = get('decline-dialog');
const declineReason = get('decline-reason');
let reasonAction;
const rescheduleDialog = get('reschedule-dialog');
const rescheduleDate = get('reschedule-date');
const rescheduleSlot = get('reschedule-slot');
const rescheduleStatus = get('reschedule-status');
const rescheduleSubmit = get('submit-reschedule');
const studioTimeZone = 'Africa/Johannesburg';
const studioTime = new Intl.DateTimeFormat('en-ZA', {
  timeZone: studioTimeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
});
let bookingToMove;
let rescheduleLoadId = 0;
const formatter = new Intl.DateTimeFormat('en-ZA', {
  timeZone: 'Africa/Johannesburg', dateStyle: 'full', timeStyle: 'short'
});
const limit = 50;
let client;
let calendar;
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
      showReasonDialog(booking.id, 'declined');
    }));
    item.append(actions);
  } else if (booking.status === 'confirmed' && new Date(booking.starts_at) > new Date()) {
    item.append(action('Reschedule', () => {
      if (busy) return;
      bookingToMove = booking;
      get('reschedule-current').textContent = `Current session: ${formatter.format(new Date(booking.starts_at))} SAST · ${booking.hours}h`;
      const parts = new Intl.DateTimeFormat('en-CA', {
        timeZone: studioTimeZone, year: 'numeric', month: '2-digit', day: '2-digit'
      }).formatToParts(new Date(booking.starts_at));
      const date = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
      rescheduleDate.value = `${date.year}-${date.month}-${date.day}`;
      rescheduleDialog.showModal();
      void loadRescheduleSlots();
    }), action('Cancel booking', () => {
      if (!busy) showReasonDialog(booking.id, 'cancelled');
    }));
  }
  return item;
}

async function decideBooking(bookingId, decision, reason) {
  if (busy) return;
  busy = true;
  const buttons = [...list.querySelectorAll('button'), get('submit-decline'), get('cancel-decline')];
  buttons.forEach(button => { button.disabled = true; });
  try {
    let result;
    if (decision === 'confirmed') {
      result = await client.rpc('admin_decide_studio_booking', { booking_id: bookingId, decision });
    } else {
      const rpc = decision === 'declined' ? 'admin_decline_studio_booking' : 'admin_cancel_studio_booking';
      result = await client.rpc(rpc, { booking_id: bookingId, reason });
      declineDialog.close();
    }
    const { error } = result;
    if (error) {
      status.textContent = error.message;
      return;
    }
    await loadBookings(`Booking ${decision}. Customer email queued.`);
  } catch {
    if (declineDialog.open) declineDialog.close();
    status.textContent = 'Could not update the booking. Refresh to check its status.';
  } finally {
    busy = false;
    buttons.forEach(button => { button.disabled = false; });
  }
}

function showReasonDialog(bookingId, decision) {
  const action = decision === 'cancelled' ? 'Cancel' : 'Decline';
  reasonAction = { bookingId, decision };
  get('decline-heading').textContent = decision === 'cancelled' ? 'Cancel confirmed booking' : 'Decline booking request';
  get('submit-decline').textContent = `${action} and email customer`;
  get('cancel-decline').textContent = 'Go back';
  declineReason.value = '';
  declineReason.setCustomValidity('');
  declineDialog.showModal();
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
    declineReason.setCustomValidity('Enter a reason for the customer.');
    declineReason.reportValidity();
    return;
  }
  void decideBooking(reasonAction.bookingId, reasonAction.decision, reason);
});

async function loadRescheduleSlots() {
  const id = ++rescheduleLoadId;
  rescheduleSlot.replaceChildren(new Option('Choose an available time', ''));
  rescheduleSlot.disabled = rescheduleSubmit.disabled = true;
  rescheduleStatus.textContent = '';
  if (!rescheduleDate.value) return;
  rescheduleStatus.textContent = 'Checking available times…';
  try {
    const { data, error } = await client.rpc('admin_reschedule_availability', {
      booking_id: bookingToMove.id, booking_date: rescheduleDate.value
    });
    if (id !== rescheduleLoadId || !rescheduleDialog.open) return;
    if (error) throw error;
    for (const slot of data) {
      const option = new Option(`${studioTime.format(new Date(slot.starts_at))} · ${slot.room_name}`, slot.starts_at);
      option.dataset.roomId = slot.room_id;
      rescheduleSlot.append(option);
    }
    rescheduleSlot.disabled = !data.length;
    rescheduleStatus.textContent = data.length ? '' : 'No alternative times on this date. Choose another day.';
  } catch {
    if (id === rescheduleLoadId) rescheduleStatus.textContent = 'Could not load times. Change the date to try again.';
  }
}

rescheduleDate.addEventListener('change', loadRescheduleSlots);
rescheduleSlot.addEventListener('change', () => { rescheduleSubmit.disabled = !rescheduleSlot.value; });
get('cancel-reschedule').addEventListener('click', () => rescheduleDialog.close());
rescheduleDialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
get('reschedule-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (busy || !rescheduleSlot.value) return;
  busy = true;
  const request = {
    booking_id: bookingToMove.id,
    requested_room: Number(rescheduleSlot.selectedOptions[0].dataset.roomId),
    requested_start: rescheduleSlot.value
  };
  const cancel = get('cancel-reschedule');
  rescheduleSubmit.disabled = rescheduleDate.disabled = rescheduleSlot.disabled = cancel.disabled = true;
  try {
    const { error } = await client.rpc('admin_reschedule_studio_booking', request);
    if (error) {
      await loadRescheduleSlots();
      rescheduleStatus.textContent = error.message;
    } else {
      rescheduleDialog.close();
      await loadBookings('Booking rescheduled. Customer email queued.');
    }
  } catch {
    rescheduleStatus.textContent = 'Could not reschedule the booking. Refresh the list to check its status.';
  } finally {
    busy = false;
    rescheduleDate.disabled = cancel.disabled = false;
    rescheduleSlot.disabled = rescheduleSlot.options.length < 2;
    rescheduleSubmit.disabled = !rescheduleSlot.value;
  }
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
      calendar.hide();
      list.replaceChildren();
      status.textContent = 'This studio account does not have staff access.';
    } else {
      status.textContent = 'Could not load bookings. Try refreshing.';
    }
    return;
  }
  section.hidden = false;
  void calendar.load();
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
  calendar = createStudioCalendar(client);
  client.auth.onAuthStateChange((event, session) => {
    if (!session) {
      loadId++;
      section.hidden = true;
      calendar.hide();
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
