const monthLabel = new Intl.DateTimeFormat('en-ZA', { month: 'long', year: 'numeric', timeZone: 'UTC' });
const dayLabel = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'full', timeZone: 'UTC' });
const isoDate = date => date.toISOString().slice(0, 10);

export function createOpenDaysPicker(client) {
  const get = id => document.getElementById(id);
  const dialog = get('available-date-dialog');
  const grid = get('available-date-grid');
  const status = get('available-date-status');
  const prev = get('available-date-prev');
  const next = get('available-date-next');
  let field;
  let hours;
  let month;
  let version = 0;

  async function render() {
    const id = ++version;
    const first = isoDate(month);
    const following = isoDate(new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 1)));
    get('available-date-month').textContent = monthLabel.format(month);
    grid.replaceChildren();
    prev.disabled = first.slice(0, 7) <= field.min.slice(0, 7);
    next.disabled = following > field.max;
    status.textContent = 'Checking open dates…';
    try {
      const { data, error } = await client.rpc('studio_open_days', { month_start: first, session_hours: hours });
      if (id !== version || !dialog.open) return;
      if (error) throw error;
      const open = new Set(data.map(row => row.open_date));
      for (const day of ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
        const header = document.createElement('span');
        header.className = 'studio-weekday';
        header.textContent = day;
        grid.append(header);
      }
      for (let pad = (month.getUTCDay() + 6) % 7; pad > 0; pad--) grid.append(document.createElement('span'));
      const last = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + 1, 0)).getUTCDate();
      for (let day = 1; day <= last; day++) {
        const date = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth(), day));
        const key = isoDate(date);
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'studio-calendar-day';
        button.textContent = day;
        button.disabled = !open.has(key);
        button.setAttribute('aria-label', dayLabel.format(date) + (button.disabled ? ', unavailable' : ', available'));
        if (key === field.value) button.setAttribute('aria-pressed', 'true');
        button.addEventListener('click', () => {
          field.value = key;
          field.dispatchEvent(new Event('change', { bubbles: true }));
          dialog.close();
        });
        grid.append(button);
      }
      status.textContent = open.size ? `Highlighted days have a free ${hours}-hour slot.` : 'No matching days this month.';
    } catch {
      if (id === version) status.textContent = 'Could not load open dates. Use the date field to try a specific day.';
    }
  }

  function change(offset) {
    month = new Date(Date.UTC(month.getUTCFullYear(), month.getUTCMonth() + offset, 1));
    void render();
  }
  prev.addEventListener('click', () => change(-1));
  next.addEventListener('click', () => change(1));
  get('available-date-close').addEventListener('click', () => dialog.close());
  return {
    open(dateField, duration) {
      field = dateField;
      hours = duration;
      const selected = dateField.value || dateField.min;
      month = new Date(selected.slice(0, 7) + '-01T00:00:00Z');
      dialog.showModal();
      void render();
    }
  };
}
