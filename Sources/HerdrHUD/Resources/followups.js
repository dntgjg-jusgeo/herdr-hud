/* Provider-neutral FIFO state. The host must flush enqueue before accepting it,
 * and flush begin()'s pending intent BEFORE sending exactly one idle-only prompt.
 * Restored queues require explicit Resume; uncertain items never begin again. */
(function(root){
  'use strict';
  const D=typeof module!=='undefined'?require('./drafts.js'):root.HUDDrafts;
  const fail=message=>{throw new Error(message||'Queued prompt changed or is not ready.');};
  function checked(queues,id){
    if((!queues||typeof queues.get!=='function'||typeof queues.set!=='function'||typeof queues.delete!=='function'||typeof queues[Symbol.iterator]!=='function')||typeof id!=='string'||!id||new TextEncoder().encode(id).length>8192||id.includes('\0'))fail();
    const items=queues.get(id)||[];if(!Array.isArray(items))fail();return items;
  }
  function enqueue(queues,id,{token,text,images}){
    const items=checked(queues,id);
    const next={token,text,images:(images||[]).map(D.serializeAttachment),status:'queued'};
    const candidate=new Map(queues);candidate.set(id,[...items,next]);
    // Reuse the exact snapshot validator, including aggregate queue bounds and
    // raster checks. The app's full snapshot also shares limits with drafts.
    const rows=[...candidate].map(([id,queue])=>({id,label:'Queued prompts',text:'',images:[],uncertain:false,keyUncertain:false,queue}));
    const normalized=D.restore({version:3,drafts:rows}).queues;
    const accepted=normalized.get(id).at(-1);
    queues.set(id,[...items,accepted]);return accepted;
  }
  function head(queues,id){return checked(queues,id)[0]||null;}
  function begin(queues,id,token){
    const item=head(queues,id);
    if(!item||item.token!==token||item.status!=='queued')fail();
    item.status='pending';return item;
  }
  function settle(queues,id,token,success){
    if(typeof success!=='boolean')fail();
    const items=checked(queues,id),item=items[0];
    if(!item||item.token!==token||item.status!=='pending')return false;
    if(success){items.shift();if(!items.length)queues.delete(id);}else item.status='uncertain';
    return true;
  }
  function remove(queues,id,token){
    const items=checked(queues,id),index=items.findIndex(item=>item.token===token);
    if(index<0)return false;if(items[index].status==='pending')fail('This queued prompt is being sent. Wait for its result before removing it.');
    items.splice(index,1);if(!items.length)queues.delete(id);return true;
  }
  const api={enqueue,head,begin,settle,remove};
  if(typeof module!=='undefined')module.exports=api;else root.HUDFollowups=api;
})(typeof window!=='undefined'?window:globalThis);
