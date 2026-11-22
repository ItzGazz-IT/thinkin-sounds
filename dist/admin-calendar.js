const zone = 'Africa/Johannesburg';
const dayFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' });
const calendarMonth = new Intl.DateTimeFormat('en-ZA', { timeZone: 'UTC', month: 'long', year: 'numeric' });
const calendarDay = new Intl.DateTimeFormat('en-ZA', { timeZone: 'UTC', dateStyle: 'full' });
const eventTime = new Intl.DateTimeFormat('en-ZA', { timeZone: zone, dateStyle: 'medium', timeStyle: 'short' });
const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const today = () => {
  const parts = Object.fromEntries(dayFormatter.formatToParts(new Date()).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
};
const iso = value => value.toISOString().slice(0, 10);
const dayAfter = date => {
  const value = new Date(date + 'T00:00:00Z');
  value.setUTCDate(value.getUTCDate() + 1);
  return iso(value);
};
const studioInstant = (day, time) => `${day}T${time}:00+02:00`;

export function createStudioCalendar(client) {
  const get = id => document.getElementById(id);
  const section = get('studio-calendar');
  const grid = get('calendar-grid');
  const details = get('calendar-events');
  const status = get('calendar-status');
  const startDate = get('block-date');
  const endDate = get('block-end-date');
  const allDay = get('block-all-day');
  const startTime = get('block-start-time');
  const endTime = get('block-end-time');
  const submit = get('submit-block');
  let day = today();
  let month = new Date(day.slice(0, 7) + '-01T00:00:00Z');
  let events = [];
  let loadId = 0;
  let saving = false;

  function eventsFor(date) {
    const start = Date.parse(studioInstant(date, '00:00'));
    const end = Date.parse(studioInstant(dayAfter(date), '00:00'));
    return events.filter(event => Date.parse(event.starts_at) < end && Date.parse(event.ends_at) > start);
  }

  function selectDay(value) {
    day = value;
    startDate.value = endDate.value = value;
    render();
  }

  function render() {
    const title = calendarMonth.format(month);
    get('calendar-month').textContent = title;
    grid.replaceChildren();
    weekdays.forEach(name => {
      const cell = document.createElement('span');
      cell.className = 'studio-weekday';
      cell.textContent = name;
      grid.append(cell);
    });
    const padding = (month.getUTCDay() + 6) % 7;
    for (let i = 0; i < padding; i++) grid.append(document.createElement('span'));
    const total = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0)).getUTCDate();
    for (let number = 1; number <= total; number++) {
      const date = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), number));
      const dateId = iso(date);
      const items = eventsFor(dateId);
      const bookings = items.filter(event => event.event_kind === 'booking').length;
      const blocks = items.length - bookings;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'studio-calendar-day';
      button.dataset.date = dateId;
      button.textContent = number;
      button.setAttribute('aria-pressed', String(dateId === day));
      button.setAttribute('aria-label', `${calendarDay.format(date)}, ${bookings} confirmed, ${blocks} blocked`);
      if (items.length) {
        const markers = document.createElement('span');
        markers.className = 'studio-calendar-markers';
        markers.setAttribute('aria-hidden', 'true');
        if (bookings) markers.append(Object.assign(document.createElement('i'), { className: 'studio-confirmed' }));
        if (blocks) markers.append(Object.assign(document.createElement('i'), { className: 'studio-blocked' }));
        button.append(markers);
      }
      button.addEventListener('click', () => {
        selectDay(dateId);
        grid.querySelector(`[data-date="${dateId}"]`)?.focus();
      });
      grid.append(button);
    }

    get('calendar-day').textContent = calendarDay.format(new Date(day + 'T00:00:00Z'));
    const selected = eventsFor(day);
    details.replaceChildren();
    for (const event of selected) {
      const row = document.createElement('li');
      const text = document.createElement('span');
      const label = event.event_kind === 'booking' ? 'Confirmed' : 'Blocked';
      text.textContent = `${label} · ${event.event_label} · ${eventTime.format(new Date(event.starts_at))} to ${eventTime.format(new Date(event.ends_at))}`;
      row.append(text);
      if (event.event_kind === 'block') {
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'account-text-button';
        remove.textContent = 'Remove block';
        remove.addEventListener('click', async () => {
          if (saving || !window.confirm('Remove this block and release its times?')) return;
          saving = true;
          remove.disabled = true;
          try {
            const { error } = await client.rpc('admin_remove_studio_block', { block_id: event.event_id });
            if (error) throw error;
            await load('Block removed.');
          } catch {
            status.textContent = 'Could not remove the block. Refresh and try again.';
          } finally {
            saving = false;
            remove.disabled = false;
          }
        });
        row.append(remove);
      }
      details.append(row);
    }
    if (!selected.length) {
      const row = document.createElement('li');
      row.textContent = 'No confirmed bookings or blocks on this date.';
      details.append(row);
    }
  }

  async function load(message = '') {
    section.hidden = false;
    const id = ++loadId;
    status.textContent = 'Loading calendar…';
    try {
      const { data, error } = await client.rpc('admin_studio_calendar', { month_start: iso(month) });
      if (id !== loadId) return;
      if (error) throw error;
      events = data;
      render();
      status.textContent = message;
    } catch {
      if (id === loadId) status.textContent = 'Could not load the calendar. Refresh to try again.';
    }
  }

  function changeMonth(offset) {
    month = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + offset, 1));
    events = [];
    selectDay(iso(month));
    void load();
  }

  get('calendar-previous').addEventListener('click', () => changeMonth(-1));
  get('calendar-next').addEventListener('click', () => changeMonth(1));
  startDate.addEventListener('change', () => {
    if (endDate.value < startDate.value) endDate.value = startDate.value;
  });
  allDay.addEventListener('change', () => {
    get('block-start-field').hidden = get('block-end-field').hidden = allDay.checked;
    startTime.disabled = endTime.disabled = allDay.checked;
  });
  get('block-form').addEventListener('submit', async event => {
    event.preventDefault();
    if (saving) return;
    saving = true;
    submit.disabled = true;
    try {
      const { error } = await client.rpc('admin_block_studio', {
        block_start: studioInstant(startDate.value, allDay.checked ? '00:00' : startTime.value),
        block_end: allDay.checked ? studioInstant(dayAfter(endDate.value), '00:00') : studioInstant(endDate.value, endTime.value),
        block_label: get('block-label').value.trim() || null
      });
      if (error) {
        status.textContent = error.message;
        return;
      }
      month = new Date(startDate.value.slice(0, 7) + '-01T00:00:00Z');
      day = startDate.value;
      get('block-label').value = '';
      await load('Studio time blocked.');
    } catch {
      status.textContent = 'Could not block time. Refresh to check the calendar.';
    } finally {
      saving = false;
      submit.disabled = false;
    }
  });
  startDate.value = endDate.value = day;
  return {
    load,
    hide() { loadId++; events = []; section.hidden = true; grid.replaceChildren(); details.replaceChildren(); }
  };
}
