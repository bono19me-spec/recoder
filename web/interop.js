(function(){
  const DB='song-pocket', VERSION=2, STORE='recordings', PLAYLISTS='playlists';
  let dbPromise;
  function db(){return dbPromise||=(new Promise((resolve,reject)=>{const r=indexedDB.open(DB,VERSION);r.onupgradeneeded=()=>{const d=r.result;if(!d.objectStoreNames.contains(STORE))d.createObjectStore(STORE,{keyPath:'id'});if(!d.objectStoreNames.contains(PLAYLISTS))d.createObjectStore(PLAYLISTS,{keyPath:'id'});};r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);}));}
  function req(r){return new Promise((resolve,reject)=>{r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
  function tx(mode,fn){return db().then(d=>new Promise((resolve,reject)=>{const t=d.transaction(STORE,mode);let value;try{value=fn(t.objectStore(STORE));}catch(e){reject(e);return}t.oncomplete=()=>resolve(value);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error);}));}
  async function opfsRoot(){if(!navigator.storage||!navigator.storage.getDirectory)return null;try{const root=await navigator.storage.getDirectory();return await root.getDirectoryHandle('recordings',{create:true});}catch(_){return null}}
  async function writeOpfs(key,blob){const dir=await opfsRoot();if(!dir)return false;const h=await dir.getFileHandle(key,{create:true});const w=await h.createWritable();await w.write(blob);await w.close();return true}
  async function readOpfs(key){const dir=await opfsRoot();if(!dir)throw new Error('OPFSを利用できません。');return (await dir.getFileHandle(key)).getFile()}
  async function deleteOpfs(key){const dir=await opfsRoot();if(dir)try{await dir.removeEntry(key)}catch(_){}}
  function clean(row){const x={...row};delete x.blob;return x}
  window.PocketBridge={
    supported:()=>JSON.stringify({secure:window.isSecureContext,media:!!(navigator.mediaDevices&&navigator.mediaDevices.getUserMedia),recorder:'MediaRecorder'in window,indexedDb:'indexedDB'in window,opfs:!!(navigator.storage&&navigator.storage.getDirectory),mediaSession:'mediaSession'in navigator,share:'share'in navigator}),
    list:async()=>JSON.stringify((await req((await db()).transaction(STORE).objectStore(STORE).getAll())).map(clean)),
    save:async(meta,blob)=>{const row=JSON.parse(meta);let opfs=false;try{opfs=await writeOpfs(row.storageKey,blob)}catch(_){}row.storageType=opfs?'opfs':'indexeddb';if(!opfs)row.blob=blob;await tx('readwrite',s=>s.put(row));return JSON.stringify(clean(row));},
    getBlob:async id=>{const row=await req((await db()).transaction(STORE).objectStore(STORE).get(id));if(!row)throw new Error('ファイル情報が見つかりません。');return row.storageType==='opfs'?readOpfs(row.storageKey):row.blob;},
    update:async(id,patch)=>{const d=await db(),t=d.transaction(STORE,'readwrite'),s=t.objectStore(STORE),row=await req(s.get(id));Object.assign(row,JSON.parse(patch),{updatedAt:new Date().toISOString()});s.put(row);await new Promise((res,rej)=>{t.oncomplete=res;t.onerror=()=>rej(t.error)});return JSON.stringify(clean(row));},
    remove:async id=>{const d=await db(),t=d.transaction(STORE,'readwrite'),s=t.objectStore(STORE),row=await req(s.get(id));if(row&&row.storageType==='opfs')await deleteOpfs(row.storageKey);await tx('readwrite',x=>x.delete(id));},
    clear:async()=>{const rows=JSON.parse(await PocketBridge.list());for(const r of rows)if(r.storageType==='opfs')await deleteOpfs(r.storageKey);const d=await db();await new Promise((resolve,reject)=>{const t=d.transaction([STORE,PLAYLISTS],'readwrite');t.objectStore(STORE).clear();t.objectStore(PLAYLISTS).clear();t.oncomplete=resolve;t.onerror=()=>reject(t.error)})},
    estimate:async()=>{const e=navigator.storage&&navigator.storage.estimate?await navigator.storage.estimate():{};const persisted=navigator.storage&&navigator.storage.persisted?await navigator.storage.persisted():false;return JSON.stringify({usage:e.usage||0,quota:e.quota||0,persisted});},
    persist:async()=>!!(navigator.storage&&navigator.storage.persist)&&await navigator.storage.persist(),
    listPlaylists:async()=>JSON.stringify(await req((await db()).transaction(PLAYLISTS).objectStore(PLAYLISTS).getAll())),
    savePlaylist:async value=>{const row=JSON.parse(value),d=await db();await new Promise((resolve,reject)=>{const t=d.transaction(PLAYLISTS,'readwrite');t.objectStore(PLAYLISTS).put(row);t.oncomplete=resolve;t.onerror=()=>reject(t.error)});return JSON.stringify(row)},
    removePlaylist:async id=>{const d=await db();await new Promise((resolve,reject)=>{const t=d.transaction(PLAYLISTS,'readwrite');t.objectStore(PLAYLISTS).delete(id);t.oncomplete=resolve;t.onerror=()=>reject(t.error)})},
    download:(blob,name)=>{const u=URL.createObjectURL(blob),a=document.createElement('a');a.href=u;a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(u),3000)},
    share:async(blob,name,title)=>{const f=new File([blob],name,{type:blob.type});if(navigator.canShare&&navigator.canShare({files:[f]})){await navigator.share({files:[f],title});return true}return false},
    registerSw:()=>{if('serviceWorker'in navigator)navigator.serviceWorker.register('service_worker.js').catch(()=>{})}
  };
})();
