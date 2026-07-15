const CACHE='song-pocket-v13-auto-update';
const SHELL=['./','index.html','styles.css','main.dart.js','interop.js','manifest.webmanifest','icon.svg'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>Promise.all(SHELL.map(url=>fetch(new Request(url,{cache:'reload'})).then(response=>{if(response.ok)return c.put(url,response)})))).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return;const url=new URL(e.request.url);if(url.origin!==location.origin)return;e.respondWith(fetch(new Request(e.request,{cache:'no-store'})).then(response=>{if(response.ok){const copy=response.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));}return response;}).catch(async()=>await caches.match(e.request)||await caches.match('index.html')));});
