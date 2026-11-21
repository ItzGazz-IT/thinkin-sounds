const toggle=document.querySelector('.nav-toggle');
const nav=document.querySelector('#site-nav');
toggle.addEventListener('click',()=>{const open=toggle.getAttribute('aria-expanded')==='true';toggle.setAttribute('aria-expanded',String(!open));nav.classList.toggle('open',!open)});
nav.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{nav.classList.remove('open');toggle.setAttribute('aria-expanded','false')}));
document.querySelector('#year').textContent = new Date().getFullYear();
const enquiryForm = document.querySelector('#enquiry-form');
if (enquiryForm) {
  const serviceField = document.querySelector('#service');
  const beatField = document.querySelector('#enquiry-beat');
  const setEnquiryBeat = title => {
    beatField.value = title;
    beatField.disabled = !title;
    beatField.parentElement.hidden = !title;
  };
  document.querySelectorAll('[data-service]').forEach(link => {
    link.addEventListener('click', () => {
      serviceField.value = link.dataset.service;
      setEnquiryBeat('');
      setTimeout(() => serviceField.focus(), 250);
    });
  });
  serviceField.addEventListener('change', () => {
    if (serviceField.value !== 'Beat enquiry') setEnquiryBeat('');
  });
  const enquiryParams = new URLSearchParams(location.search);
  const selectedBeat = enquiryParams.get('beat')?.trim().slice(0, 100);
  if (selectedBeat) {
    serviceField.value = 'Beat enquiry';
    setEnquiryBeat(selectedBeat);
  } else if (enquiryParams.get('service') === 'custom-beat') {
    serviceField.value = 'Custom beat';
  }
  enquiryForm.addEventListener('submit',event=>{
    event.preventDefault();
    const form=event.currentTarget;
    const data=new FormData(form);
    const value=name=>String(data.get(name)||'').trim();
    const lines=[
      'Hi Thinkin’ Sounds, I’d like to make an enquiry.',
      '',
      `Name / artist: ${value('name')}`,
      `Contact: ${value('contact')}`,
      `Service: ${value('service')}`,
      ...(value('beat') ? [`Beat: ${value('beat')} by ItzGazz`] : []),
      `Track count: ${value('tracks')||'Not specified'}`,
      `Preferred date: ${value('preferred_date')||'Flexible'}`,
      `Target release: ${value('release_date')||'Not specified'}`,
      `Private demo: ${value('demo')||'None yet'}`,
      '',
      `Project notes: ${value('notes')}`
    ];
    const recipient=value('recipient')||'27826535019';
    const status=form.querySelector('.form-status');
    status.hidden=false;
    status.textContent='Opening WhatsApp with your enquiry. You can review the message before sending.';
    window.location.assign(`https://wa.me/${recipient}?text=${encodeURIComponent(lines.join('\n'))}`);
  });
}
const musicScrollNote=document.querySelector('.music-scroll-note');
const backToTop=document.querySelector('.back-to-top');
const musicScroll=document.querySelector('.music-scroll');
const updateScrollUI=()=>{const maxScroll=document.documentElement.scrollHeight-window.innerHeight;const progress=maxScroll>0?window.scrollY/maxScroll:0;const railTravel=Math.max(0,musicScroll.clientHeight-musicScrollNote.offsetHeight);musicScrollNote.style.transform=`translate(-50%, ${Math.round(progress*railTravel)}px)`;musicScroll.setAttribute('aria-valuenow',String(Math.round(progress*100)));backToTop.classList.toggle('is-visible',window.scrollY>500)};
window.addEventListener('scroll',updateScrollUI,{passive:true});
window.addEventListener('resize',updateScrollUI);
backToTop.addEventListener('click',()=>window.scrollTo({top:0,behavior:window.matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'}));
const scrollFromPointer=clientY=>{const rect=musicScroll.getBoundingClientRect();const travel=Math.max(1,rect.height-musicScrollNote.offsetHeight);const progress=Math.min(1,Math.max(0,(clientY-rect.top-musicScrollNote.offsetHeight/2)/travel));window.scrollTo({top:progress*(document.documentElement.scrollHeight-window.innerHeight),behavior:'auto'})};
let draggingScroll=false;
musicScroll.addEventListener('pointerdown',event=>{draggingScroll=true;musicScroll.classList.add('is-dragging');musicScroll.setPointerCapture(event.pointerId);scrollFromPointer(event.clientY)});
musicScroll.addEventListener('pointermove',event=>{if(draggingScroll)scrollFromPointer(event.clientY)});
const stopScrollDrag=event=>{draggingScroll=false;musicScroll.classList.remove('is-dragging');if(musicScroll.hasPointerCapture(event.pointerId))musicScroll.releasePointerCapture(event.pointerId)};
musicScroll.addEventListener('pointerup',stopScrollDrag);
musicScroll.addEventListener('pointercancel',stopScrollDrag);
musicScroll.addEventListener('keydown',event=>{const max=document.documentElement.scrollHeight-window.innerHeight;const keys={ArrowDown:80,ArrowUp:-80,PageDown:window.innerHeight*.8,PageUp:-window.innerHeight*.8,Home:-window.scrollY,End:max-window.scrollY};if(keys[event.key]!==undefined){event.preventDefault();window.scrollBy({top:keys[event.key],behavior:'auto'})}});
const heroPrice=document.querySelector('.hero-price');
if (heroPrice) {
  const priceOptions=[{price:'R150',duration:'1 hour'},{price:'R250',duration:'2 hours'},{price:'R400',duration:'4 hours'}];
  let priceIndex=0;
  heroPrice.addEventListener('click',()=>{priceIndex=(priceIndex+1)%priceOptions.length;const option=priceOptions[priceIndex];heroPrice.classList.remove('is-changing');void heroPrice.offsetWidth;heroPrice.querySelector('strong').textContent=option.price;heroPrice.querySelector('.price-duration').textContent=option.duration;heroPrice.classList.add('is-changing');heroPrice.setAttribute('aria-label',`Recording session price ${option.price} for ${option.duration}. Activate to compare the next option.`)});
}
updateScrollUI();

const beatList = document.querySelector('[data-beat-list]');
if (beatList) {
  const tracks = [
    ["blacktop", "Blacktop", 141, "F♯ minor"],
    ["cold-intentions", "Cold Intentions", 82, "B♭ minor"],
    ["dead-of-night", "Dead of Night", 70, "A♭ major"],
    ["keep-your-head-low", "Keep Your Head Low (Drill)", 68, "F♯ minor"],
    ["night-shift", "Night Shift", 92, "E♭ minor"],
    ["no-witness", "No Witness", 70, "F major / F minor"],
    ["silent-cuts", "Silent Cuts", 68, "C minor"],
    ["soul-dust", "Soul Dust", 75, "F major"],
    ["trust-nobody", "Trust Nobody", 70, "F minor / F major"],
    ["niche", "Niche", 70, "F minor"],
    ["sippin-on-the-beach", "Sippin on the Beach", 113, "C minor"],
    ["for-you", "For You", 98, "C♯ minor"],
    ["tippy", "Tippy", 70, "E♭ minor"],
    ["stay-with-me", "Stay With Me", 75, "F minor"],
    ["racecar", "RaceCar", 79, "E♭ minor"],
    ["back-it-up", "Back It Up", 68, "F minor"],
    ["dues", "Dues", 75, "B minor / B major"],
    ["hills", "Hills", 120, "F♯ minor / A major"],
    ["mainz", "MaInZ", 91, "B minor / B major"],
    ["night-time", "Night Time", 68, "G minor / G major"],
    ["on-a-cloud", "ON a ClOUD", 120, "F♯ major / E♭ minor"],
    ["scarlet-reign", "SCARLET REIGN", 112, "B♭ minor"],
    ["tight", "Tight", 78, "D minor"],
    ["tough-times", "Tough Times", 69, "G major / B minor"],
    ["udeee", "UDEEE", 70, "F major / F minor"]
  ];
  let lineup = tracks;
  if (beatList.dataset.beatList === 'featured') {
    const rotationKey = 'thinkin-sounds-featured-beats';
    let previousSelection;
    try {
      previousSelection = sessionStorage.getItem(rotationKey);
    } catch {
      // Rotation also works when browser storage is unavailable.
    }

    for (let index = tracks.length - 1; index > 0; index--) {
      const other = Math.floor(Math.random() * (index + 1));
      [tracks[index], tracks[other]] = [tracks[other], tracks[index]];
    }
    lineup = tracks.slice(0, 3);
    const selectionKey = () => lineup.map(([slug]) => slug).sort().join(',');
    if (selectionKey() === previousSelection) lineup[2] = tracks[3];
    try {
      sessionStorage.setItem(rotationKey, selectionKey());
    } catch {
      // Remembering the previous lineup is optional.
    }
  }

  beatList.innerHTML = lineup.map(([slug, title, bpm, key]) => `
    <li class="beat-card">
      <img src="assets/beats/${slug}.webp" alt="" width="400" height="400" loading="lazy" decoding="async">
      <div class="beat-card-details">
        <h3 class="beat-title">${title}</h3>
        <p>ItzGazz · ≈ ${bpm} BPM · ${key}</p>
        <audio preload="none" src="assets/beats/${slug}.mp3"></audio>
        <div class="beat-player">
          <button class="beat-play" type="button" aria-label="Play ${title}">Play</button>
          <input class="beat-seek" type="range" min="0" max="90" step="0.1" value="0" aria-label="Seek in ${title}" disabled>
          <span class="beat-time" aria-hidden="true">1:30</span>
        </div>
        <p class="beat-error" role="status" hidden></p>
        <a class="beat-enquire" href="index.html?beat=${encodeURIComponent(title)}#contact" aria-label="Talk beats about ${title}">Talk beats</a>
      </div>
    </li>`).join('');
}

let activeBeatPreview;
document.querySelectorAll('.beat-card').forEach(card => {
  const preview = card.querySelector('audio');
  const button = card.querySelector('.beat-play');
  const seek = card.querySelector('.beat-seek');
  const status = card.querySelector('.beat-error');
  const title = card.querySelector('.beat-title').textContent;
  const updateButton = () => {
    const action = preview.paused ? 'Play' : 'Pause';
    button.textContent = action;
    button.setAttribute('aria-label', `${action} ${title}`);
  };
  const showError = () => {
    status.textContent = 'Preview unavailable. Try again in a moment.';
    status.hidden = false;
    updateButton();
  };

  button.addEventListener('click', () => {
    if (!preview.paused) {
      preview.pause();
      return;
    }

    status.hidden = true;
    if (activeBeatPreview && activeBeatPreview !== preview) activeBeatPreview.pause();
    activeBeatPreview = preview;
    preview.play().catch(error => {
      if (error.name !== 'AbortError') showError();
    });
  });
  preview.addEventListener('play', updateButton);
  preview.addEventListener('pause', updateButton);
  preview.addEventListener('ended', updateButton);
  preview.addEventListener('loadedmetadata', () => {
    seek.max = preview.duration;
    seek.disabled = false;
  });
  preview.addEventListener('timeupdate', () => {
    seek.value = preview.currentTime;
  });
  seek.addEventListener('input', () => {
    preview.currentTime = seek.valueAsNumber;
  });
});
