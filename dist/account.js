import { projectUrl, publishableKey } from './account-config.js';
import { studioBundles, bundleSessionLabel } from './booking-bundles.js';
import { createOpenDaysPicker } from './open-days.js';
import { createProjectWorkspace } from './project-workspace.js';

const get = id => document.getElementById(id);
const status = get('account-status');
const signIn = get('sign-in-panel');
const recovery = get('reset-panel');
const bookings = get('booking-panel');
const date = get('session-date');
const hours = get('session-hours');
const slots = get('session-slot');
const packageField = get('booking-package');
const songCount = get('bundle-tracks');
const secondDate = get('second-session-date');
const secondSlots = get('second-session-slot');
const secondStatus = get('second-availability-status');
const selectedBundle = () => studioBundles[packageField.value];
const book = get('request-booking');
const availabilityStatus = get('availability-status');
const bookingList = get('booking-list');
const redirectTo = new URL('account.html', location.href).href;
const timeZone = 'Africa/Johannesburg';
const timeFormat = new Intl.DateTimeFormat('en-ZA', { timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dateTimeFormat = new Intl.DateTimeFormat('en-ZA', { timeZone, dateStyle: 'medium', timeStyle: 'short' });
let client;
let datePicker;
let workspace;
let session;
let recovering = false;
const slotRequests = new Map();
let submitting = false;
let bundleAttempt;
let bookingRequest = 0;

const say = message => { status.textContent = message; };

function studioDate(daysAhead) {
  const format = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' });
  const parts = Object.fromEntries(format.formatToParts(new Date()).map(part => [part.type, part.value]));
  const day = new Date(Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day) + daysAhead));
  return day.toISOString().slice(0, 10);
}

function syncSubmit() {
  book.disabled = submitting || !slots.value || Boolean(selectedBundle()?.sessions === 2 && !secondSlots.value);
}

function syncBundle() {
  const bundle = selectedBundle();
  const needsSecond = bundle?.sessions === 2;
  get('booking-bundle-summary').hidden = get('bundle-tracks-field').hidden = !bundle;
  songCount.disabled = !bundle;
  get('session-hours-field').hidden = hours.disabled = Boolean(bundle);
  get('bundle-second-date').hidden = get('bundle-second-slot').hidden = secondStatus.hidden = !needsSecond;
  secondDate.disabled = !needsSecond;
  if (!needsSecond) secondSlots.disabled = true;
  get('session-slot-label').textContent = needsSecond ? 'First session time' : 'Available times';
  book.textContent = bundle ? 'Request this bundle' : 'Request this session';
  if (bundle) {
    songCount.max = bundle.tracks;
    if (!songCount.value || Number(songCount.value) > bundle.tracks) songCount.value = bundle.tracks;
    const recording = needsSecond ? 'Two 4-hour sessions' : 'One 4-hour session';
    get('booking-bundle-includes').textContent = `${bundle.price} · Up to ${bundle.tracks} songs · ${recording}`;
    get('booking-bundle-deposit').textContent = `${bundle.deposit} deposit after scope and dates are agreed. Each date remains pending until the studio confirms it.`;
  }
}

async function loadAvailability(second = false) {
  const dateField = second ? secondDate : date;
  const slotField = second ? secondSlots : slots;
  const message = second ? secondStatus : availabilityStatus;
  const request = (slotRequests.get(slotField) || 0) + 1;
  slotRequests.set(slotField, request);
  slotField.replaceChildren(new Option('Choose an available time', ''));
  slotField.disabled = true;
  syncSubmit();
  message.textContent = '';
  if (!session || dateField.disabled || !dateField.value || !dateField.validity.valid) return;
  message.textContent = 'Checking available times…';
  const bundle = selectedBundle();
  try {
    const { data, error } = await client.rpc('studio_availability', {
      booking_date: dateField.value,
      booking_hours: bundle ? 4 : Number(hours.value)
    });
    if (request !== slotRequests.get(slotField)) return;
    if (error) throw error;
    for (const slot of data) {
      const option = new Option(`${timeFormat.format(new Date(slot.starts_at))} · ${slot.room_name}`, slot.starts_at);
      option.dataset.roomId = slot.room_id;
      slotField.append(option);
    }
    slotField.disabled = data.length === 0;
    message.textContent = data.length ? '' : bundle ? 'No 4-hour slots on this date. Try another day.' : 'No matching times. Try another date or a shorter session.';
  } catch {
    if (request === slotRequests.get(slotField)) message.textContent = 'Could not load times. Change the date to try again.';
  }
}

async function loadBookings() {
  const request = ++bookingRequest;
  if (!session) return;
  const { data, error } = await client.from('studio_bookings')
    .select('id, starts_at, hours, headcount, status, bundle_code, bundle_session, bundle_tracks').order('starts_at', { ascending: false }).limit(100);
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
    const bundle = bundleSessionLabel(booking);
    if (bundle) details.textContent = `${bundle} · ${booking.bundle_tracks} songs · ${details.textContent}`;
    item.append(details);
    const tools = document.createElement('div');
    tools.className = 'account-actions';
    if (bundle || ['requested', 'confirmed'].includes(booking.status)) {
      const project = document.createElement('button');
      project.type = 'button';
      project.className = 'account-text-button';
      project.textContent = bundle ? 'Project workspace' : 'Session prep';
      project.addEventListener('click', () => workspace.open(booking));
      tools.append(project);
    }
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
      tools.append(cancel);
    }
    if (tools.childElementCount) item.append(tools);
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
    for (const field of [slots, secondSlots]) {
      slotRequests.set(field, (slotRequests.get(field) || 0) + 1);
    }
    bundleAttempt = undefined;
    workspace.close();
    bookingRequest++;
    get('staff-bookings').hidden = true;
    slots.replaceChildren();
    secondSlots.replaceChildren();
    bookingList.replaceChildren();
    return;
  }
  get('signed-in-email').textContent = session.user.email;
  if (previousUser !== session.user.id || event === 'PASSWORD_UPDATED') {
    for (const field of [date, secondDate]) {
      field.min = studioDate(0);
      field.max = studioDate(90);
      field.value = field.min;
    }
    const linkedBundle = new URLSearchParams(location.search).get('bundle');
    packageField.value = Object.hasOwn(studioBundles, linkedBundle) ? linkedBundle : 'session';
    syncBundle();
    const userId = session.user.id;
    void client.rpc('is_studio_admin').then(({ data }) => {
      if (session?.user.id === userId) get('staff-bookings').hidden = data !== true;
    });
    void loadAvailability();
    void loadAvailability(true);
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

get('find-session-date').addEventListener('click', () => datePicker.open(date, selectedBundle() ? 4 : Number(hours.value)));
get('find-second-date').addEventListener('click', () => datePicker.open(secondDate, 4));
date.addEventListener('change', () => { void loadAvailability(); });
hours.addEventListener('change', () => { void loadAvailability(); });
secondDate.addEventListener('change', () => { void loadAvailability(true); });
for (const field of [slots, secondSlots]) field.addEventListener('change', syncSubmit);
packageField.addEventListener('change', () => {
  syncBundle();
  void loadAvailability();
  void loadAvailability(true);
});

function chosenSlot(field) {
  return { room_id: Number(field.selectedOptions[0].dataset.roomId), starts_at: field.value };
}

get('booking-form').addEventListener('submit', async event => {
  event.preventDefault();
  if (book.disabled || submitting) return;
  const bundle = selectedBundle();
  const headcount = Number(get('session-headcount').value);
  const first = chosenSlot(slots);
  const selected = bundle?.sessions === 2 ? [first, chosenSlot(secondSlots)] : [first];
  if (selected.length === 2 && Math.abs(Date.parse(first.starts_at) - Date.parse(selected[1].starts_at)) < 4 * 60 * 60 * 1000) {
    say('Choose two recording times that do not overlap.');
    return;
  }
  submitting = true;
  syncSubmit();
  try {
    let result;
    if (bundle) {
      const fields = {
        requested_bundle: packageField.value, requested_tracks: songCount.valueAsNumber,
        requested_headcount: headcount, requested_slots: selected
      };
      const signature = JSON.stringify(fields);
      if (bundleAttempt?.signature !== signature) bundleAttempt = { signature, id: crypto.randomUUID() };
      result = await client.rpc('request_studio_bundle', { ...fields, request_id: bundleAttempt.id });
    } else {
      result = await client.rpc('request_studio_booking', {
        requested_room: first.room_id,
        requested_start: first.starts_at,
        requested_hours: Number(hours.value),
        requested_headcount: headcount
      });
    }
    say(result.error ? result.error.message : bundle
      ? 'Bundle request received. Check the status of each session under Your bookings.'
      : 'Request received. The studio will confirm availability and deposit details.');
    if (!result.error) {
      await Promise.all([loadAvailability(), loadAvailability(true), loadBookings()]);
    }
  } catch {
    say('Could not verify the request. Check Your bookings before trying again.');
    await loadBookings();
  } finally {
    submitting = false;
    syncSubmit();
  }
});

if (!projectUrl || !publishableKey) {
  say('Online accounts and bookings are being set up. Contact the studio to book a session.');
} else {
  say('Loading your studio account…');
  try {
    const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.2/+esm');
    client = createClient(projectUrl, publishableKey);
    datePicker = createOpenDaysPicker(client);
    workspace = createProjectWorkspace(client);
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
