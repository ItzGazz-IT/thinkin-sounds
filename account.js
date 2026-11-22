import { projectUrl, publishableKey } from './account-config.js';

const get = id => document.getElementById(id);
const status = get('account-status');
const signIn = get('sign-in-panel');
const recovery = get('reset-panel');
const bookings = get('booking-panel');
const date = get('session-date');
const hours = get('session-hours');
const slots = get('session-slot');
const book = get('request-booking');
const availabilityStatus = get('availability-status');
const bookingList = get('booking-list');
const redirectTo = new URL('account.html', location.href).href;
const timeZone = 'Africa/Johannesburg';
const timeFormat = new Intl.DateTimeFormat('en-ZA', { timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dateTimeFormat = new Intl.DateTimeFormat('en-ZA', { timeZone, dateStyle: 'medium', timeStyle: 'short' });
let client;
let session;
let recovering = false;
let availabilityRequest = 0;
let bookingRequest = 0;

const say = message => { status.textContent = message; };

function studioDate(daysAhead) {
  const format = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' });
  const parts = Object.fromEntries(format.formatToParts(new Date()).map(part => [part.type, part.value]));
  const day = new Date(Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day) + daysAhead));
  return day.toISOString().slice(0, 10);
}

async function loadAvailability() {
  const request = ++availabilityRequest;
  slots.replaceChildren(new Option('Choose an available time', ''));
  slots.disabled = book.disabled = true;
  availabilityStatus.textContent = '';
  if (!session || !date.value || !date.validity.valid) return;
  availabilityStatus.textContent = 'Checking available times…';

  const { data, error } = await client.rpc('studio_availability', {
    booking_date: date.value,
    booking_hours: Number(hours.value)
  });
  if (request !== availabilityRequest) return;
  if (error) {
    availabilityStatus.textContent = 'Could not load times. Change the date or duration to try again.';
    return;
  }
  for (const slot of data) {
    const option = new Option(`${timeFormat.format(new Date(slot.starts_at))} · ${slot.room_name}`, slot.starts_at);
    option.dataset.roomId = slot.room_id;
    slots.append(option);
  }
  slots.disabled = data.length === 0;
  availabilityStatus.textContent = data.length ? '' : 'No matching times. Try another date or a shorter session.';
}

async function loadBookings() {
  const request = ++bookingRequest;
  if (!session) return;
  const { data, error } = await client.from('studio_bookings')
    .select('id, starts_at, hours, headcount, status').order('starts_at', { ascending: false }).limit(100);
  if (request !== bookingRequest) return;

  bookingList.replaceChildren();
  if (error || !data.length) {
    const message = document.createElement('li');
    message.textContent = error ? 'Bookings could not be loaded.' : 'You have no studio bookings yet.';
    bookingList.append(message);
    return;
  }
  for (const booking of data) {
    const item = document.createElement('li');
    const details = document.createElement('span');
    const status = booking.status === 'requested' ? 'Awaiting studio confirmation' : booking.status;
    details.textContent = `${dateTimeFormat.format(new Date(booking.starts_at))} · ${booking.hours}h · ${booking.headcount} attending · ${status}`;
    item.append(details);
    if (booking.status === 'requested' && new Date(booking.starts_at) > new Date()) {
      const cancel = document.createElement('button');
      cancel.type = 'button';
      cancel.className = 'account-text-button';
      cancel.textContent = 'Cancel request';
      cancel.addEventListener('click', async () => {
        cancel.disabled = true;
        const { data: cancelled, error } = await client.rpc('cancel_studio_request', { booking_id: booking.id });
        if (error) {
          say('The request could not be cancelled. Try again.');
          cancel.disabled = false;
          return;
        }
        say(cancelled ? 'Booking request cancelled.' : 'This request is no longer pending. Contact the studio for changes.');
        await loadBookings();
      });
      item.append(cancel);
    }
    bookingList.append(item);
  }
}

function showSession(event, nextSession) {
  const previousUser = session?.user.id;
  session = nextSession;
  if (event === 'PASSWORD_RECOVERY') recovering = true;
  if (!session) recovering = false;
  signIn.hidden = Boolean(session);
  recovery.hidden = !recovering;
  bookings.hidden = !session || recovering;
  if (bookings.hidden) {
    availabilityRequest++;
    bookingRequest++;
    slots.replaceChildren();
    bookingList.replaceChildren();
    return;
  }
  get('signed-in-email').textContent = session.user.email;
  if (previousUser !== session.user.id || event === 'PASSWORD_UPDATED') {
    date.min = studioDate(0);
    date.max = studioDate(90);
    date.value = date.min;
    void loadAvailability();
    void loadBookings();
  }
}

async function withButtons(form, action) {
  const buttons = [...form.querySelectorAll('button')];
  buttons.forEach(button => { button.disabled = true; });
  try {
    await action();
  } catch {
    say('The request could not be completed. Try again.');
  } finally {
    buttons.forEach(button => { button.disabled = false; });
  }
}

get('auth-form').addEventListener('submit', event => {
  event.preventDefault();
  const email = get('email');
  if (!email.reportValidity()) return;
  const password = get('password');
  const intent = event.submitter?.value || 'sign-in';
  if (intent === 'sign-up' && password.value.length < 8) {
    say('Choose a password with at least eight characters.');
    password.focus();
    return;
  }
  void withButtons(event.currentTarget, async () => {
    say('');
    const credentials = { email: email.value.trim(), password: password.value };
    if (intent === 'reset') {
      const { error } = await client.auth.resetPasswordForEmail(credentials.email, { redirectTo });
      say(error ? 'Could not request a reset link. Try again.' : 'Check your email for a password reset link.');
    } else if (intent === 'sign-up') {
      const { data, error } = await client.auth.signUp({ ...credentials, options: { emailRedirectTo: redirectTo } });
      say(error ? error.message : data.session ? 'Your studio account is ready.' : 'Check your email to confirm your account.');
      if (!error) password.value = '';
    } else {
      const { error } = await client.auth.signInWithPassword(credentials);
      say(error ? 'Could not sign in. Check your details and confirm your email first.' : '');
      if (!error) password.value = '';
    }
  });
});

get('reset-form').addEventListener('submit', event => {
  event.preventDefault();
  void withButtons(event.currentTarget, async () => {
    const password = get('new-password');
    const { data, error } = await client.auth.updateUser({ password: password.value });
    if (error) { say(error.message); return; }
    password.value = '';
    recovering = false;
    if (data.user && session) showSession('PASSWORD_UPDATED', session);
    say('Password updated.');
  });
});

get('sign-out').addEventListener('click', async () => {
  const { error } = await client.auth.signOut();
  say(error ? 'Could not sign out. Try again.' : 'Signed out.');
});

date.addEventListener('change', loadAvailability);
hours.addEventListener('change', loadAvailability);
slots.addEventListener('change', () => { book.disabled = !slots.value; });
get('booking-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (!slots.value || book.disabled) return;
  book.disabled = true;
  const { error } = await client.rpc('request_studio_booking', {
    requested_room: Number(slots.selectedOptions[0].dataset.roomId),
    requested_start: slots.value,
    requested_hours: Number(hours.value),
    requested_headcount: Number(get('session-headcount').value)
  });
  say(error ? error.message : 'Request received. The studio will confirm availability and deposit details.');
  await Promise.all([loadAvailability(), loadBookings()]);
});

if (!projectUrl || !publishableKey) {
  say('Online accounts and bookings are being set up. Contact the studio to book a session.');
} else {
  say('Loading your studio account…');
  try {
    const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.2/+esm');
    client = createClient(projectUrl, publishableKey);
    client.auth.onAuthStateChange((event, nextSession) => {
      setTimeout(() => {
        if (event === 'INITIAL_SESSION') say('');
        showSession(event, nextSession);
      }, 0);
    });
  } catch {
    say('Studio accounts are temporarily unavailable. Please try again later.');
  }
}
