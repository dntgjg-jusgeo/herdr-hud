/* Exact-identity draft snapshots. No transport operation is performed here. */
(function(root){
  'use strict';
  const limits={count:128,text:60000,totalText:1048576,images:3,imageBytes:4194304,totalImages:25165824,queuePerSession:16,queueCount:128,videoBytes:104857600,totalVideoBytes:536870912,videoTokens:128,posterLength:350000,totalPosters:2097152};
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
  function serializeAttachment(value){
    if(value?.kind==='video')return {kind:'video',token:value.token,name:value.name,bytes:value.bytes,poster:value.poster,duration:value.duration,width:value.width,height:value.height};
    return {data:value?.data,name:value?.name};
  }
  function attachment(value,key,version,videoRefs,posterBudget){
    if(value?.kind!=='video')return image(value,key);
    const v=serializeAttachment(value),prefix='data:image/jpeg;base64,';
    if(version!==3||typeof v.token!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(v.token)||typeof v.name!=='string'||!v.name||v.name.length>120||/[\\/\x00-\x1f\x7f]/.test(v.name)||!/\.mp4$/i.test(v.name)||!Number.isSafeInteger(v.bytes)||v.bytes<=0||v.bytes>limits.videoBytes||typeof v.poster!=='string'||v.poster.length>limits.posterLength||!v.poster.startsWith(prefix)||typeof v.duration!=='number'||!Number.isFinite(v.duration)||v.duration<=0||v.duration>86400||![v.width,v.height].every(n=>Number.isInteger(n)&&n>0&&n<=16384)||v.width*v.height>40000000)fail();
    posterBudget.total+=v.poster.length;if(posterBudget.total>limits.totalPosters)fail();
    const data=v.poster.slice(prefix.length);
    if(!data.length||data.length%4||!/^[A-Za-z0-9+/]*={0,2}$/.test(data))fail();
    let head;try{head=atob(data.slice(0,Math.min(24,data.length)));}catch(_){fail();}
    if(!head.startsWith('\xff\xd8\xff'))fail();
    const prior=videoRefs.get(v.token),serialized=JSON.stringify(v);
    if(prior&&prior.serialized!==serialized)fail();
    if(!prior){videoRefs.set(v.token,{serialized,bytes:v.bytes});if(videoRefs.size>limits.videoTokens||[...videoRefs.values()].reduce((n,x)=>n+x.bytes,0)>limits.totalVideoBytes)fail();}
    return {...v,key,url:v.poster};
  }
  function restore(value){
    if(!value||![1,2,3].includes(value.version)||!Array.isArray(value.drafts)||value.drafts.length>limits.count)fail();
    const state={drafts:new Map(),attachments:new Map(),uncertain:new Set(),keyUncertain:new Set(),labels:new Map(),queues:new Map()};
    const ids=new Set(),tokens=new Set(),videoRefs=new Map(),posterBudget={total:0};let textTotal=0,imageTotal=0,key=0,queueCount=0;
    for(const row of value.drafts){
      if(!row||typeof row.id!=='string'||!row.id||bytes(row.id)>8192||row.id.includes('\0')||ids.has(row.id)||typeof row.text!=='string'||bytes(row.text)>limits.text||!Array.isArray(row.images)||row.images.length>limits.images||typeof row.uncertain!=='boolean'||typeof row.keyUncertain!=='boolean')fail();
      const label=row.label===undefined?'Recovered draft':row.label;
      if(typeof label!=='string'||[...label].length>200||bytes(label)>800)fail();
      ids.add(row.id);textTotal+=bytes(row.text);if(textTotal>limits.totalText)fail();
      const images=row.images.map(item=>attachment(item,++key,value.version,videoRefs,posterBudget));imageTotal+=images.reduce((n,item)=>n+(item.kind==='video'?0:item.bytes),0);if(imageTotal>limits.totalImages)fail();
      state.drafts.set(row.id,row.text);state.attachments.set(row.id,images);state.labels.set(row.id,label);
      if(row.uncertain)state.uncertain.add(row.id);if(row.keyUncertain)state.keyUncertain.add(row.id);
      const queued=row.queue===undefined?[]:row.queue;
      if(!Array.isArray(queued)||queued.length>limits.queuePerSession)fail();
      const items=queued.map(item=>{
        if(!item||typeof item.token!=='string'||!item.token||bytes(item.token)>128||/[\x00-\x1f\x7f]/.test(item.token)||tokens.has(item.token)||typeof item.text!=='string'||bytes(item.text)>limits.text||item.text.includes('\0')||!Array.isArray(item.images)||item.images.length>limits.images||!['queued','pending','uncertain'].includes(item.status))fail();
        tokens.add(item.token);queueCount++;if(queueCount>limits.queueCount)fail();
        const images=item.images.map(attachmentValue=>attachment(attachmentValue,++key,value.version,videoRefs,posterBudget));
        if(!item.text.trim()&&!images.length)fail();
        textTotal+=bytes(item.text);imageTotal+=images.reduce((n,value)=>n+(value.kind==='video'?0:value.bytes),0);
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
      const text=state.drafts.get(id)||'',images=(state.attachments.get(id)||[]).map(serializeAttachment),uncertain=state.uncertain.has(id)||pending.has(id),keyUncertain=state.keyUncertain.has(id)||pendingKeys.has(id);
      const queue=(state.queues?.get(id)||[]).map(item=>({token:item.token,text:item.text,images:item.images.map(serializeAttachment),status:item.status==='pending'?'uncertain':item.status}));
      if(!text&&!images.length&&!uncertain&&!keyUncertain&&!queue.length)continue;
      const row={id,label:state.labels?.get(id)||'Recovered draft',text,images,uncertain,keyUncertain};
      if(queue.length)row.queue=queue;rows.push(row);
    }
    const hasVideo=rows.some(row=>row.images.some(item=>item.kind==='video')||(row.queue||[]).some(item=>item.images.some(image=>image.kind==='video')));
    const value={version:hasVideo?3:2,drafts:rows};restore(value);return value;
  }
  function mergeRestored(saved,current,touched=new Set()){
    const merged=restore(saved);
    for(const id of touched){
      const before=merged.drafts.get(id)||'',live=current.drafts.get(id)||'';
      merged.drafts.set(id,before&&live&&before!==live?before+'\n\n'+live:live||before);
      const images=[...(merged.attachments.get(id)||[])];
      for(const item of current.attachments.get(id)||[])if(!images.some(old=>JSON.stringify(serializeAttachment(old))===JSON.stringify(serializeAttachment(item))))images.push(item);
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
          if(existing.id!==id||existing.item.text!==item.text||JSON.stringify(existing.item.images.map(serializeAttachment))!==JSON.stringify(item.images.map(serializeAttachment)))fail();
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
  const api={limits,snapshot,restore,mergeRestored,persistence,serializeAttachment};
  if(typeof module!=='undefined')module.exports=api;else root.HUDDrafts=api;
})(typeof window!=='undefined'?window:globalThis);
