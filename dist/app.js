const toggle=document.querySelector('.nav-toggle');
const nav=document.querySelector('#site-nav');
toggle.addEventListener('click',()=>{const open=toggle.getAttribute('aria-expanded')==='true';toggle.setAttribute('aria-expanded',String(!open));nav.classList.toggle('open',!open)});
nav.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{nav.classList.remove('open');toggle.setAttribute('aria-expanded','false')}));
document.querySelectorAll('[data-service]').forEach(link=>link.addEventListener('click',()=>{const service=document.querySelector('#service');service.value=link.dataset.service;setTimeout(()=>service.focus(),250)}));
document.querySelector('#year').textContent=new Date().getFullYear();
document.querySelector('#enquiry-form').addEventListener('submit',event=>{event.preventDefault();const status=event.currentTarget.querySelector('.form-status');status.hidden=false;status.textContent='Enquiry form ready — inbox delivery will be connected before launch.'});
