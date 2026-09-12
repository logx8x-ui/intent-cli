import {kitForRelease} from './release.mjs';
const form=document.querySelector('#download-form'),button=document.querySelector('#download'),status=document.querySelector('#status'),retry=document.querySelector('#retry');let release=null;
function selected(){return new FormData(form).get('browser')}
function render(){const kit=kitForRelease(release,selected());button.disabled=!kit;button.textContent='Download Intent';status.textContent=kit?`${kit.version} · One kit with Intent and your browser setup.`:'The new installer is being prepared. Check back here once Logan shares the ready-to-test build.';retry.hidden=!!kit;}
async function refresh(){button.disabled=true;button.textContent='Checking download…';retry.hidden=true;status.textContent='Finding the latest setup kit.';
 try{const response=await fetch('https://api.github.com/repos/logx8x-ui/intent-cli/releases/latest',{headers:{Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(12000)});if(!response.ok)throw new Error('unavailable');release=await response.json();render();}
 catch{release=null;button.disabled=true;button.textContent='Download Intent';status.textContent='We couldn’t check the download. Try again in a moment.';retry.hidden=false;}}
form.addEventListener('change',render);retry.addEventListener('click',refresh);
form.addEventListener('submit',event=>{event.preventDefault();const kit=kitForRelease(release,selected());if(!kit)return;const link=document.createElement('a');link.href=kit.url;link.download='';document.body.append(link);link.click();link.remove();document.querySelector('#next').hidden=false;status.textContent='Your download is starting. If it doesn’t start, press Download Intent again.';});refresh();
