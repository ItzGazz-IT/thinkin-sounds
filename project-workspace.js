const milestones = [
  ['files_received_at', 'Files received'],
  ['first_mix_at', 'First mix ready'],
  ['masters_ready_at', 'Final masters ready']
];
const dates = new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeZone: 'Africa/Johannesburg' });

function field(parent, labelText, options = {}) {
  const label = document.createElement('label');
  label.className = 'field';
  const title = document.createElement('span');
  title.textContent = labelText;
  const input = document.createElement(options.tag || 'input');
  for (const [name, value] of Object.entries(options.attributes || {})) input[name] = value;
  label.append(title, input);
  parent.append(label);
  return input;
}

function button(label, className = 'button') {
  const node = document.createElement('button');
  node.className = className;
  node.type = 'button';
  node.textContent = label;
  return node;
}

function heading(text) {
  const h = document.createElement('h3');
  h.textContent = text;
  return h;
}

function appendLink(parent, label, address) {
  if (!address) return;
  try {
    const url = new URL(address);
    if (url.protocol !== 'https:') return;
    const link = document.createElement('a');
    link.textContent = label;
    link.href = url.href;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    const p = document.createElement('p');
    p.append(link);
    parent.append(p);
  } catch {
    // Invalid URLs cannot be offered as downloads.
  }
}

export function createProjectWorkspace(client, staff = false) {
  const dialog = document.getElementById('project-workspace-dialog');
  const body = document.getElementById('project-workspace-body');
  const status = document.getElementById('project-workspace-status');
  let version = 0;
  let saving = false;
  document.getElementById('close-project-workspace').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { version++; body.replaceChildren(); });

  async function submit(control, action, renderAfterSave) {
    if (saving) return;
    saving = true;
    control.disabled = true;
    try {
      const { error } = await action();
      if (error) throw error;
      status.textContent = 'Saved.';
      if (renderAfterSave) await renderAfterSave();
    } catch (error) {
      status.textContent = error.message || 'Could not save. Try again.';
    } finally {
      saving = false;
      control.disabled = false;
    }
  }

  function renderPrep(data, booking) {
    body.append(heading('Before the session'));
    const checklist = document.createElement('ul');
    for (const text of ['Rehearse your songs and decide the track order.', 'Check that you have permission to use each beat.', 'Share reference tracks and bring any files you need for the session.']) {
      const item = document.createElement('li');
      item.textContent = text;
      checklist.append(item);
    }
    body.append(checklist);
    const form = document.createElement('form');
    const editable = !staff && ['requested', 'confirmed'].includes(booking.status);
    const tracks = field(form, 'Tracklist (one song per line)', { tag: 'textarea', attributes: { maxLength: 2500, rows: 3, value: data.tracklist || '', readOnly: !editable } });
    const beats = field(form, 'Beat links', { tag: 'textarea', attributes: { maxLength: 2500, rows: 2, value: data.beat_links || '', readOnly: !editable } });
    const refs = field(form, 'References and notes', { tag: 'textarea', attributes: { maxLength: 2500, rows: 2, value: data.reference_links || '', readOnly: !editable } });
    if (editable) {
      const save = button('Save session prep');
      save.type = 'submit';
      form.append(save);
      form.addEventListener('submit', event => {
        event.preventDefault();
        void submit(save, () => client.rpc('save_studio_prep', { booking_id: booking.id, tracks: tracks.value, beats: beats.value, refs: refs.value }));
      });
    }
    body.append(form);
  }

  function renderTimeline(data, booking) {
    if (!data.bundle_code) return;
    body.append(heading('Project timeline'));
    const timeline = document.createElement('ol');
    for (const [key, title] of milestones) {
      const step = document.createElement('li');
      step.textContent = data[key] ? `${title} · ${dates.format(new Date(data[key]))}` : `${title} · Pending`;
      timeline.append(step);
    }
    body.append(timeline);
    appendLink(body, 'Open first mix', data.first_mix_url);
    appendLink(body, 'Download final masters', data.master_url);
    const songs = (data.tracklist || '').split('\n').map(line => line.trim()).filter(Boolean);
    const revisions = Array.from({ length: data.song_count }, (_, index) => data.revisions_used?.[index] || 0);
    const songLabel = index => songs[index] || `Song ${index + 1}`;
    body.append(heading('Revision rounds'));
    if (!staff) {
      const list = document.createElement('ul');
      revisions.forEach((used, index) => {
        const row = document.createElement('li');
        row.textContent = `${songLabel(index)} · ${2 - used} of 2 rounds remaining`;
        list.append(row);
      });
      body.append(list);
      return;
    }

    const form = document.createElement('form');
    const stage = field(form, 'Project stage', { tag: 'select' });
    stage.append(new Option('Awaiting files', '0'), ...milestones.map(([, label], index) => new Option(label, String(index + 1))));
    stage.value = data.masters_ready_at ? '3' : data.first_mix_at ? '2' : data.files_received_at ? '1' : '0';
    const mix = field(form, 'First mix HTTPS link (optional)', { attributes: { type: 'url', maxLength: 2000, value: data.first_mix_url || '' } });
    const masters = field(form, 'Final masters HTTPS link', { attributes: { type: 'url', maxLength: 2000, value: data.master_url || '' } });
    const revisionFields = revisions.map((used, index) => {
      const select = field(form, `${songLabel(index)} · rounds used`, { tag: 'select' });
      select.append(new Option('0 of 2', '0'), new Option('1 of 2', '1'), new Option('2 of 2', '2'));
      select.value = String(used);
      return select;
    });
    const updateLinks = () => {
      mix.disabled = Number(stage.value) < 2;
      masters.disabled = stage.value !== '3';
      masters.required = !masters.disabled;
    };
    stage.addEventListener('change', updateLinks);
    updateLinks();
    const save = button('Save project timeline');
    save.type = 'submit';
    form.append(save);
    form.addEventListener('submit', event => {
      event.preventDefault();
      void submit(save, () => client.rpc('admin_save_project_timeline', {
        booking_id: booking.id, timeline_stage: Number(stage.value),
        mix_link: mix.value, masters_link: masters.value,
        used_rounds: revisionFields.map(input => Number(input.value))
      }), () => load(booking, 'Project timeline updated.'));
    });
    body.append(form);
  }

  async function load(booking, success = '') {
    const id = ++version;
    body.replaceChildren();
    status.textContent = 'Loading project…';
    try {
      const { data, error } = await client.rpc('studio_project_workspace', { booking_id: booking.id });
      if (id !== version || !dialog.open) return;
      if (error) throw error;
      renderPrep(data, booking);
      renderTimeline(data, booking);
      status.textContent = success;
    } catch {
      if (id === version) status.textContent = 'Could not load the project. Close and try again.';
    }
  }

  return {
    open(booking) {
      document.getElementById('project-workspace-title').textContent = booking.bundle_code ? 'Project workspace' : 'Session prep';
      dialog.showModal();
      void load(booking);
    },
    close() { if (dialog.open) dialog.close(); }
  };
}
