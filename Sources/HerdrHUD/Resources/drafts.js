/* Exact-identity draft snapshots. No transport operation is performed here. */
(function(root){
  'use strict';
  const limits={count:128,text:60000,totalText:1048576,images:3,imageBytes:4194304,totalImages:25165824,queuePerSession:16,queueCount:128};
  const bytes=s=>new TextEncoder().encode(s).length;
  const fail=()=>{throw new Error('Draft storage limit or invalid draft data. Copy your current draft before restarting.');};
  function image(value,key){
    if(!value||typeof value.data!=='string'||typeof value.name!=='string'||!value.name||value.name.length>120||/[\\/\0]/.test(value.name))fail();
    const data=value.data;
    if(!data.length||data.length>Math.ceil(limits.imageBytes/3)*4||data.length%4||!/^[A-Za-z0-9+/]*={0,2}$/.test(data))fail();
    const size=data.length/4*3-(data.endsWith('==')?2:data.endsWith('=')?1:0);
    if(!size||size>limits.imageBytes)fail();
    const head=atob(data.slice(0,Math.min(24,data.length)));
    const mime=head.startsWith('\x89PNG\r\n\x1a\n')?'image/png':head.startsWith('\xff\xd8\xff')?'image/jpeg':/^GIF8[79]a/.test(head)?'image/gif':head.startsWith('RIFF')&&head.slice(8,12)==='WEBP'?'image/webp':null;
    if(!mime)fail();
    return {key,bytes:size,name:value.name,data,url:'data:'+mime+';base64,'+data};
  }
  function restore(value){
    if(!value||![1,2].includes(value.version)||!Array.isArray(value.drafts)||value.drafts.length>limits.count)fail();
    const state={drafts:new Map(),attachments:new Map(),uncertain:new Set(),keyUncertain:new Set(),labels:new Map(),queues:new Map()};
    const ids=new Set(),tokens=new Set();let textTotal=0,imageTotal=0,key=0,queueCount=0;
    for(const row of value.drafts){
      if(!row||typeof row.id!=='string'||!row.id||bytes(row.id)>8192||row.id.includes('\0')||ids.has(row.id)||typeof row.text!=='string'||bytes(row.text)>limits.text||!Array.isArray(row.images)||row.images.length>limits.images||typeof row.uncertain!=='boolean'||typeof row.keyUncertain!=='boolean')fail();
      const label=row.label===undefined?'Recovered draft':row.label;
      if(typeof label!=='string'||[...label].length>200||bytes(label)>800)fail();
      ids.add(row.id);textTotal+=bytes(row.text);if(textTotal>limits.totalText)fail();
      const images=row.images.map(item=>image(item,++key));imageTotal+=images.reduce((n,item)=>n+item.bytes,0);if(imageTotal>limits.totalImages)fail();
      state.drafts.set(row.id,row.text);state.attachments.set(row.id,images);state.labels.set(row.id,label);
      if(row.uncertain)state.uncertain.add(row.id);if(row.keyUncertain)state.keyUncertain.add(row.id);
      const queued=row.queue===undefined?[]:row.queue;
      if(!Array.isArray(queued)||queued.length>limits.queuePerSession)fail();
      const items=queued.map(item=>{
        if(!item||typeof item.token!=='string'||!item.token||bytes(item.token)>128||/[\x00-\x1f\x7f]/.test(item.token)||tokens.has(item.token)||typeof item.text!=='string'||bytes(item.text)>limits.text||item.text.includes('\0')||!Array.isArray(item.images)||item.images.length>limits.images||!['queued','pending','uncertain'].includes(item.status))fail();
        tokens.add(item.token);queueCount++;if(queueCount>limits.queueCount)fail();
        const images=item.images.map(value=>image(value,++key));
        if(!item.text.trim()&&!images.length)fail();
        textTotal+=bytes(item.text);imageTotal+=images.reduce((n,value)=>n+value.bytes,0);
        if(textTotal>limits.totalText||imageTotal>limits.totalImages)fail();
        return {token:item.token,text:item.text,images,status:item.status==='pending'?'uncertain':item.status};
      });
      if(items.length)state.queues.set(row.id,items);
    }
    return state;
  }
  function snapshot(state){
    const ids=new Set([...state.drafts.keys(),...state.attachments.keys(),...state.uncertain,...state.keyUncertain,...(state.pendingPromptIDs||[]),...(state.pendingKeyIDs||[]),...(state.queues||new Map()).keys()]);
    const pending=new Set(state.pendingPromptIDs||[]),pendingKeys=new Set(state.pendingKeyIDs||[]),rows=[];
    for(const id of ids){
      const text=state.drafts.get(id)||'',images=(state.attachments.get(id)||[]).map(({data,name})=>({data,name})),uncertain=state.uncertain.has(id)||pending.has(id),keyUncertain=state.keyUncertain.has(id)||pendingKeys.has(id);
      const queue=(state.queues?.get(id)||[]).map(item=>({token:item.token,text:item.text,images:item.images.map(({data,name})=>({data,name})),status:item.status==='pending'?'uncertain':item.status}));
      if(!text&&!images.length&&!uncertain&&!keyUncertain&&!queue.length)continue;
      const row={id,label:state.labels?.get(id)||'Recovered draft',text,images,uncertain,keyUncertain};
      if(queue.length)row.queue=queue;rows.push(row);
    }
    const value={version:2,drafts:rows};restore(value);return value;
  }
  function mergeRestored(saved,current,touched=new Set()){
    const merged=restore(saved);
    for(const id of touched){
      const before=merged.drafts.get(id)||'',live=current.drafts.get(id)||'';
      merged.drafts.set(id,before&&live&&before!==live?before+'\n\n'+live:live||before);
      const images=[...(merged.attachments.get(id)||[])];
      for(const item of current.attachments.get(id)||[])if(!images.some(old=>old.data===item.data&&old.name===item.name))images.push(item);
      merged.attachments.set(id,images);
      if(current.labels?.has(id))merged.labels.set(id,current.labels.get(id));
    }
    // Queue identities never follow replacement agents. During startup, merge
    // saved FIFO first and append only distinct live tokens for that exact id.
    const allTokens=new Map();for(const [id,items] of merged.queues)for(const item of items)allTokens.set(item.token,{id,item});
    for(const [id,items] of current.queues||[]){
      const queue=merged.queues.get(id)||[];
      for(const item of items){
        const existing=allTokens.get(item.token);
        if(existing){
          if(existing.id!==id||existing.item.text!==item.text||JSON.stringify(existing.item.images.map(({name,data})=>({name,data})))!==JSON.stringify(item.images.map(({name,data})=>({name,data}))))fail();
          if(item.status==='pending'||item.status==='uncertain')existing.item.status='uncertain';
        }else{const copy={...item,images:item.images.map(image=>({...image})),status:item.status==='pending'?'uncertain':item.status};queue.push(copy);allTokens.set(item.token,{id,item:copy});}
      }
      if(queue.length)merged.queues.set(id,queue);
    }
    // A concurrently started mutation must never lose its uncertain-delivery guard.
    for(const id of current.uncertain)merged.uncertain.add(id);
    for(const id of current.keyUncertain)merged.keyUncertain.add(id);
    for(const id of current.pendingPromptIDs||[])merged.uncertain.add(id);
    for(const id of current.pendingKeyIDs||[])merged.keyUncertain.add(id);
    return restore(snapshot(merged));
  }
  // Persistence is disabled until startup restore has been merged. flush() is an
  // explicit acknowledgement barrier for callers BEFORE starting a send/key.
  // save(value) must resolve only after the native host's atomic write succeeds.
  function persistence({capture,save,delay=150,setTimer=setTimeout,clearTimer=clearTimeout}){
    let ready=false,timer=null,tail=Promise.resolve();
    function flush(){
      if(!ready)return Promise.reject(new Error('Drafts have not finished restoring.'));
      if(timer!==null){clearTimer(timer);timer=null;}
      let value;try{value=capture();}catch(error){return Promise.reject(error);}
      const job=tail.catch(()=>{}).then(()=>save(value));tail=job;return job;
    }
    return {start(){ready=true;},flush,changed(onError=()=>{}){if(!ready)return;if(timer!==null)clearTimer(timer);timer=setTimer(()=>{timer=null;flush().catch(onError);},delay);},stop(){ready=false;if(timer!==null)clearTimer(timer);timer=null;}};
  }
  const api={limits,snapshot,restore,mergeRestored,persistence};
  if(typeof module!=='undefined')module.exports=api;else root.HUDDrafts=api;
})(typeof window!=='undefined'?window:globalThis);
