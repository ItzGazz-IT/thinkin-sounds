const toggle=document.querySelector('.nav-toggle');
const nav=document.querySelector('#site-nav');
toggle.addEventListener('click',()=>{const open=toggle.getAttribute('aria-expanded')==='true';toggle.setAttribute('aria-expanded',String(!open));nav.classList.toggle('open',!open)});
nav.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{nav.classList.remove('open');toggle.setAttribute('aria-expanded','false')}));
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
    setEnquiryBeat(link.dataset.beat || '');
    setTimeout(() => serviceField.focus(), 250);
  });
});
serviceField.addEventListener('change', () => {
  if (serviceField.value !== 'Beat enquiry') setEnquiryBeat('');
});
document.querySelector('#year').textContent=new Date().getFullYear();
document.querySelector('#enquiry-form').addEventListener('submit',event=>{
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
  status.textContent='WhatsApp opened with your enquiry. Review the message there before sending.';
  window.open(`https://wa.me/${recipient}?text=${encodeURIComponent(lines.join('\n'))}`,'_blank','noopener');
});
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
const priceOptions=[{price:'R150',duration:'1 hour'},{price:'R250',duration:'2 hours'},{price:'R400',duration:'4 hours'}];
let priceIndex=0;
heroPrice.addEventListener('click',()=>{priceIndex=(priceIndex+1)%priceOptions.length;const option=priceOptions[priceIndex];heroPrice.classList.remove('is-changing');void heroPrice.offsetWidth;heroPrice.querySelector('strong').textContent=option.price;heroPrice.querySelector('.price-duration').textContent=option.duration;heroPrice.classList.add('is-changing');heroPrice.setAttribute('aria-label',`Recording session price ${option.price} for ${option.duration}. Activate to compare the next option.`)});
updateScrollUI();

let activeBeatPreview;
document.querySelectorAll('.beat-card').forEach(card => {
  const preview = card.querySelector('audio');
  const button = card.querySelector('.beat-play');
  const icon = button.querySelector('span');
  const seek = card.querySelector('.beat-seek');
  const status = card.querySelector('.beat-error');
  const title = card.querySelector('h4').textContent;
  const updateButton = () => {
    icon.textContent = preview.paused ? '▶' : 'Ⅱ';
    button.setAttribute('aria-label', `${preview.paused ? 'Play' : 'Pause'} ${title}`);
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
