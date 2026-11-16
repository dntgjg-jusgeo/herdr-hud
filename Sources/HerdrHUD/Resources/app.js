'use strict';
const $=id=>document.getElementById(id);
const post=data=>window.webkit?.messageHandlers?.hud ? window.webkit.messageHandlers.hud.postMessage(data) : window.chrome.webview.postMessage(data);
if(window.chrome?.webview)window.chrome.webview.addEventListener('message',event=>window.receive(event.data));
let agents=[],selected='',opened=false,mode='chat',filter='',reading=false,sending=false,requestSequence=0,lastOutput='',lastRendered='',selectionEpoch=0;
let supportsAttachments=false,attachments=new Map(),attachmentLoads=new Map(),attachmentSequence=0,pendingAttachmentBytes=0;
let supportsPreviews=false,previewMode=false,previewRequestID='';
let attachmentPreview=null,attachmentButtons=new Map();
let rosterMode='herdr',shepherdr=null,supportsShepherdr=false,selectedRow='';
let baseline=false,unread=new Set(),drafts=new Map(),outputs=new Map(),since=new Map(),uncertain=new Set(),promptByRequest=new Map();
function request(op,extra={}){const requestID=`${Date.now()}-${++requestSequence}`;post({op,requestID,...extra});return requestID;}
function active(){const a=agents.find(a=>a.id===selected);if(a||!selected.startsWith('shepherdr:'))return a;const r=linked(selected);return r&&{id:r.view_id,online:true,agent_status:'readonly',agent:'shepherdr',workspace_label:r.space||r.title,machine_label:r.machine};}
function name(a){return a.tab_label||a.name||a.pane_id||'Agent';}
function rows(){return rosterMode==='shepherdr'&&supportsShepherdr?HUDModel.shepherdrRows(shepherdr,agents):null;}
function linked(id){return id?rows()?.find(r=>r.view_id===id):undefined;}
function label(a){return linked(a.id)?.title||name(a);}
function el(tag,text,cls){const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;}
function notice(text){$('notice').hidden=!text;$('notice').textContent=text;}
function badge(){const list=rows();post({op:'badge',count:list?list.filter(r=>r.need||unread.has(r.agent_id)).length:agents.filter(a=>a.agent_status==='blocked'||unread.has(a.id)).length});}
// A Shepherdr row keeps its selection when its agent starts, finishes or is replaced; the draft and any uncertain-send block move with it.
function follow(){if(!selectedRow)selectedRow=linked(selected)?.key||'';const r=selectedRow&&rows()?.find(r=>r.key===selectedRow);if(!r?.view_id||r.view_id===selected)return;if(imagesFor(selected).length||attachmentLoads.get(selected)){notice('This agent changed. Images remain with this draft; remove them or select the new agent manually.');return;}if(uncertain.has(selected))uncertain.add(r.view_id);drafts.set(r.view_id,$('prompt').value);select(r.view_id);}
function renderModes(){$('modes').hidden=!supportsShepherdr;$('mode-herdr').setAttribute('aria-pressed',String(rosterMode==='herdr'));$('mode-shepherdr').setAttribute('aria-pressed',String(rosterMode==='shepherdr'));$('roster-label').textContent=rosterMode==='shepherdr'&&supportsShepherdr?'SPACES & TASKS':'AGENTS';$('search').placeholder=rosterMode==='shepherdr'&&supportsShepherdr?'Find a space or task…':'Find an agent…';}
function renderShepherdr(list,roster,scroll){
  const shown=list.filter(r=>`${r.title} ${r.detail} ${r.state} ${r.machine}`.toLowerCase().includes(filter));$('count').textContent=list.filter(r=>r.kind==='task').length;
  roster.replaceChildren(...shown.map(r=>{const a=agents.find(x=>x.id===r.agent_id),on=!!r.view_id&&r.view_id===selected,button=el('button',undefined,'agent '+r.kind+(on?' selected':'')+(a&&!a.online?' offline':''));button.setAttribute('aria-pressed',String(on));button.disabled=!r.view_id;
    const title=el('div',undefined,'agent-title');title.append(el('span',undefined,'dot '+(r.need||a?.agent_status==='blocked'||unread.has(r.agent_id)?'attention':a?.agent_status==='working'?'busy':'')),el('span',r.title));button.append(title);
    const meta=el('div',undefined,'agent-meta');if(r.detail)meta.append(el('div',r.detail));meta.append(el('div',r.state,'agent-state'+(r.need?' need':'')));button.append(meta);
    button.title=r.agent_id?'':r.view_id?'Not running: opens its Shepherdr chat, read only':`No running herdr agent for this ${r.kind}`;if(r.view_id)button.onclick=()=>select(r.view_id);return button;}));
  if(!shown.length)roster.append(el('p',!shepherdr?'Reading Shepherdr…':list.length?'No matching spaces or tasks.':'No Shepherdr spaces found.','empty'));roster.scrollTop=scroll;
}
function renderRoster(){
  const roster=$('roster'),scroll=roster.scrollTop,list=rows();if(list)return renderShepherdr(list,roster,scroll);$('count').textContent=agents.length;
  const items=HUDModel.sorted(agents,unread).filter(a=>`${name(a)} ${a.workspace_label} ${a.machine_label} ${a.agent}`.toLowerCase().includes(filter));
  roster.replaceChildren(...items.map(a=>{const button=el('button',undefined,'agent'+(a.id===selected?' selected':'')+(!a.online?' offline':''));button.setAttribute('aria-pressed',String(a.id===selected));
    const title=el('div',undefined,'agent-title');title.append(el('span',undefined,'dot '+(a.agent_status==='working'?'busy':a.agent_status==='blocked'||unread.has(a.id)?'attention':'')),el('span',name(a)));button.append(title);
    const meta=el('div',undefined,'agent-meta');meta.append(el('div',a.workspace_label||a.workspace_id),el('div',a.machine_label+' · '+(a.agent||'agent')),el('div',a.online?a.agent_status:'Offline','agent-state'));button.append(meta);const metadata=HUDModel.parse(outputs.get(a.id)?.text||'',a.agent);button.title=metadata.model?`${metadata.model} ${metadata.reasoning}`:a.pane_id;button.onclick=()=>select(a.id);return button;}));
  if(!items.length)roster.append(el('p',agents.length?'No matching agents.':'No agents found. Start an agent in Herdr.','empty'));roster.scrollTop=scroll;
}
function select(id){
  if(id!==selected)closeAttachmentPreview(false);
  drafts.set(selected,$('prompt').value);selectedRow=linked(id)?.key||'';selected=id;request('preferences',{selectedAgent:id});selectionEpoch++;lastRendered='';$('prompt').value=drafts.get(id)||'';
  lastOutput=outputs.get(id)?.text||'';if(previewMode)loadPreviews();renderRoster();renderHeader();renderOutput();read();
}
function renderHeader(){
  const a=active(),row=a&&linked(a.id);$('title').textContent=a?label(a):'Select an agent';$('identity').textContent=row?`${row.kind==='task'?row.space+' · ':''}${row.machine} · ${row.state} · ${a.agent}`:a?`${a.workspace_label} · ${a.machine_label} · ${a.agent}`:'Your configured Herdr machines appear automatically';
  $('previews-tab').hidden=!supportsPreviews;$('preview-folder').disabled=!a||a.machine_id!=='local';$('preview-refresh').disabled=!a||a.machine_id!=='local';
  const state=a?.agent_status||'';const busy=state==='working';$('working').hidden=!busy;
  if(busy&&!since.has(a.id))since.set(a.id,Date.now());
  $('send').disabled=!a?.online||a.can_prompt===false||!['idle','done'].includes(state)||sending||uncertain.has(selected)||(! $('prompt').value.trim()&&!imagesFor(selected).length)||!!attachmentLoads.get(selected)||(imagesFor(selected).length>0&&!canAttach(a));
  $('prompt').disabled=!a;$('chat').disabled=a?.agent!=='codex';
  $('send-status').textContent=sending?'Sending once…':uncertain.has(selected)?'Delivery uncertain. Inspect this agent in Herdr before sending again.':!a?'Choose an agent to get started.':!a.online?'Machine offline. Your draft is retained.':state==='readonly'?'Not running. Its Shepherdr chat is shown, read only.':state==='blocked'?'Needs your input in Herdr. Native approvals remain in its terminal.':busy?'Agent is working. You can draft the next prompt here.':a.can_prompt===false?'Waiting for the agent to report idle. Continue in Herdr if needed.':['idle','done'].includes(state)?'Ready for your next prompt.':'Agent state is unknown. Sending is disabled.';
  $('reconcile').hidden=!uncertain.has(selected);
  $('attach').hidden=!supportsAttachments;$('attach').disabled=!canAttach(a)||sending||uncertain.has(selected);renderAttachments();
}
function inline(text,parent){ // No terminal text is ever interpreted as HTML.
  for(const part of text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g)){if(part.startsWith('**')&&part.endsWith('**'))parent.append(el('strong',part.slice(2,-2)));else if(part.startsWith('`')&&part.endsWith('`'))parent.append(el('code',part.slice(1,-1)));else parent.append(document.createTextNode(part));}
}
function renderOutput(){
  $('output').hidden=previewMode;$('previews').hidden=!previewMode;$('previews-tab').setAttribute('aria-pressed',String(previewMode));
  const a=active(),out=$('output'),data=HUDModel.parse(lastOutput,a?.agent||'');const terminal=mode==='terminal'||a?.agent!=='codex';
  const signature=JSON.stringify([selected,lastOutput,terminal]);if(signature===lastRendered)return;const wasBottom=out.scrollHeight-out.scrollTop-out.clientHeight<70,scroll=out.scrollTop;const first=!lastRendered;lastRendered=signature;
  const expanded=new Set([...out.querySelectorAll('details[open]')].map(n=>n.dataset.key));out.replaceChildren();
  if(!lastOutput)out.append(el('p',a?'Loading recent output…':'Select an agent to read its recent output.','empty'));
  else if(terminal||!data.blocks.length)out.append(el('pre',data.text));
  else data.blocks.forEach((block,index)=>{const node=el('div',undefined,'block '+block.kind);
    if(block.kind==='tool'){const detail=el('details');detail.dataset.key=block.kind+block.text.split('\n')[0]+index;detail.open=expanded.has(detail.dataset.key);detail.append(el('summary',block.text.split('\n')[0]),el('pre',block.text));node.append(detail);}
    else{if(block.kind==='prompt')node.append(el('div','You','block-label'));else if(block.kind==='reply')node.append(el('div',data.model||a.agent,'block-label'));inline(block.text,node);}out.append(node);});
  if(data.model){$('title').title=`${data.model} ${data.reasoning}`;for(const button of $('roster').children)if(button.getAttribute('aria-pressed')==='true')button.title=`${data.model} ${data.reasoning}`;}
  $('chat').setAttribute('aria-pressed',String(!previewMode&&!terminal));$('terminal').setAttribute('aria-pressed',String(!previewMode&&terminal));
  out.scrollTop=first||wasBottom?out.scrollHeight:scroll;
}
function loadPreviews(){
  $('preview-grid').replaceChildren();
  const local=active()?.machine_id==='local';
  $('preview-status').textContent=local?'Loading recent images…':'Previews are available for local agents. Select one to choose a folder.';
  previewRequestID=local?request('previews',{id:selected}):'';
}
function renderPreviews(data){
  if(data.id!==selected||data.requestID!==previewRequestID)return;
  const items=Array.isArray(data.items)?data.items.slice(0,24):[];
  $('preview-status').textContent=data.error||`${data.folder||'Local folder'} · ${items.length?items.length+' recent images · click to open a copy in Preview':'No supported images in this folder or outputs. Choose another folder.'}`;
  $('preview-grid').replaceChildren(...items.filter(item=>typeof item.token==='string'&&typeof item.thumbnail==='string'&&/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(item.thumbnail)&&item.thumbnail.length<=350000).map(item=>{
    const button=el('button',undefined,'preview-image'),image=el('img');image.src=item.thumbnail;image.alt=item.name||'Image preview';
    button.title=`Open a copy of ${item.name||'image'} in Preview`;button.append(image,el('span',item.name||'Image'),el('small',`${item.width} × ${item.height}`));
    button.onclick=()=>request('openPreview',{id:selected,token:item.token});return button;
  }));
}
function imagesFor(id){return attachments.get(id)||[];}
function canAttach(a=active()){return supportsAttachments&&a?.can_attach===true&&a.online&&['claude','codex'].includes(a.agent);}
function closeAttachmentPreview(restore=true){
  if(!attachmentPreview)return;
  const key=attachmentPreview.key;attachmentPreview=null;$('attachment-preview').close();
  if(restore)(attachmentButtons.get(key)||$('attach')).focus();
}
function openAttachmentPreview(item){
  attachmentPreview={key:item.key,id:selected};$('attachment-preview-name').textContent=item.name;
  $('attachment-preview-image').src=item.url;$('attachment-preview-image').alt=item.name;
  $('attachment-preview').showModal();$('attachment-preview-close').focus();
}
$('attachment-preview-close').onclick=()=>closeAttachmentPreview();
$('attachment-preview').oncancel=event=>{event.preventDefault();closeAttachmentPreview();};
function renderAttachments(){
  attachmentButtons=new Map();
  if(attachmentPreview&&(attachmentPreview.id!==selected||!imagesFor(selected).some(x=>x.key===attachmentPreview.key)))closeAttachmentPreview(false);
  const items=imagesFor(selected);$('attachments').hidden=!items.length;
  if(!items.length){$('attachments').replaceChildren?.();return;}
  $('attachments').replaceChildren(...items.map(item=>{
    const chip=el('div',undefined,'attachment'),image=el('img'),preview=el('button',undefined,'attachment-thumbnail');image.src=item.url;image.alt='';
    preview.type='button';preview.setAttribute('aria-label','Preview '+item.name);preview.append(image);preview.onclick=()=>openAttachmentPreview(item);attachmentButtons.set(item.key,preview);
    const remove=el('button','×');remove.setAttribute('aria-label','Remove '+item.name);remove.disabled=sending||uncertain.has(selected);
    remove.onclick=()=>{attachments.set(selected,imagesFor(selected).filter(x=>x.key!==item.key));renderHeader();};
    chip.append(preview,el('span',item.name),remove);return chip;
  }));
}
async function stageImages(files){
  if(!canAttach()||sending||uncertain.has(selected)){notice('Images are available for local hc Claude and Codex agents.');return;}
  const id=selected,list=Array.from(files),count=imagesFor(id).length+(attachmentLoads.get(id)||0);
  const stagedBytes=[...attachments.values()].flat().reduce((n,item)=>n+item.bytes,0)+pendingAttachmentBytes;
  if(!list.length)return;
  if(stagedBytes+list.reduce((n,f)=>n+f.size,0)>24*1024*1024){notice('Attached drafts total 24 MB. Remove an image from another draft first.');return;}
  if(count+list.length>3||list.some(f=>!['image/png','image/jpeg','image/webp','image/gif'].includes(f.type)||!f.size||f.size>4*1024*1024)){notice('Attach up to 3 PNG, JPEG, WebP or GIF images, 4 MB each.');return;}
  pendingAttachmentBytes+=list.reduce((n,f)=>n+f.size,0);attachmentLoads.set(id,(attachmentLoads.get(id)||0)+list.length);renderHeader();
  for(const file of list){
    try{
      const url=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('Could not read image.'));reader.readAsDataURL(file);});
      if(typeof url!=='string'||url.length>5600000||!/^data:image\/(png|jpeg|webp|gif);base64,[A-Za-z0-9+/=]+$/.test(url))throw new Error('Could not read image.');
      const valid=await new Promise(resolve=>{const image=new Image();image.onload=()=>resolve(image.naturalWidth>0&&image.naturalWidth<=16384&&image.naturalHeight>0&&image.naturalHeight<=16384&&image.naturalWidth*image.naturalHeight<=40000000);image.onerror=()=>resolve(false);image.src=url;});
      if(!valid)throw new Error('Use a valid raster image under 40 million pixels.');
      attachments.set(id,[...imagesFor(id),{key:++attachmentSequence,bytes:file.size,name:file.name.split(/[\\/]/).pop().slice(0,120)||'Image',url,data:url.slice(url.indexOf(',')+1)}]);
    }catch(error){notice(error.message||'Could not read image.');}
    finally{pendingAttachmentBytes-=file.size;attachmentLoads.set(id,Math.max(0,(attachmentLoads.get(id)||0)-1));renderHeader();}
  }
}
$('attach').onclick=()=>$('attachment-files').click();
$('attachment-files').onchange=e=>{stageImages(e.target.files);e.target.value='';};
$('prompt').onpaste=e=>{
  const clipboard=e.clipboardData;if(!clipboard)return;
  // Items and files can describe the same clipboard image; use files only as a fallback.
  let files=Array.from(clipboard.items||[]).filter(item=>item.kind==='file'&&item.type.startsWith('image/')).map(item=>item.getAsFile()).filter(Boolean);
  if(!files.length)files=Array.from(clipboard.files||[]).filter(file=>file.type.startsWith('image/'));
  if(!files.length)return;
  e.preventDefault();
  // A mixed clipboard still inserts its plain text at the current selection.
  const text=clipboard.getData?.('text/plain');
  if(text){const input=$('prompt');input.setRangeText(text,input.selectionStart,input.selectionEnd,'end');input.oninput();}
  stageImages(files);
};
// Prevent WebKit's default path insertion/navigation for every file drop, including unsupported agents.
for(const kind of ['dragover','drop'])document.addEventListener(kind,e=>{
  if(!Array.from(e.dataTransfer?.types||[]).includes('Files'))return;
  e.preventDefault();
  if(kind==='drop'){stageImages(e.dataTransfer.files);}
});
function read(){if(!opened||reading||!active()?.online)return;reading=true;request('output',{id:selected});}
function send(){if($('send').disabled)return;const id=selected,message=$('prompt').value;sending=true;notice('');const images=imagesFor(id).slice();const requestID=request('prompt',{id,message,attachments:images.map(x=>({data:x.data}))});promptByRequest.set(requestID,{id,message,images});renderHeader();}
window.receive=({type,data})=>{
  if(type==='roster'){
    const before=agents;agents=data.agents||[];shepherdr=data.shepherdr||(rosterMode==='shepherdr'?shepherdr:null);
    if(baseline)for(const a of agents){const old=before.find(b=>b.id===a.id);if(old&&a.online&&old.online&&old.agent_status!==a.agent_status)unread.add(a.id);}
    const updates=baseline?HUDModel.alerts(before,agents):[];baseline=true;
    for(const a of agents){if(a.agent_status==='working'&&!since.has(a.id))since.set(a.id,Date.now());if(a.agent_status!=='working')since.delete(a.id);}
    const valid=new Set(agents.map(a=>a.id));unread=new Set([...unread].filter(id=>valid.has(id)));
    if(updates.length&&!opened){const a=updates[0];request('alertPreview',{id:a.id,title:label(a)+(a.agent_status==='blocked'?' needs input':' finished')});}
    $('machines').replaceChildren(...(data.machines||[]).map(m=>{const node=el('span',undefined,'machine');node.append(el('span',undefined,'dot '+(m.online?'online':'')),document.createTextNode(`${m.label} · ${m.online?`${m.count} agents`:'offline'}`));node.title=m.error||'';return node;}));
    if(data.discoveryError)notice('Herdr setup: '+data.discoveryError);else if(rosterMode==='shepherdr'&&data.shepherdr?.error)notice('Shepherdr: '+data.shepherdr.error);
    follow();if(!selected&&agents.length)select(rows()?.find(r=>r.agent_id)?.agent_id||agents[0].id);renderRoster();renderHeader();badge();read();
  }else if(type==='visibility'){opened=data.open;if(opened){renderHeader();read();}}
  else if(type==='resetBaseline'){baseline=false;}
  else if(type==='select'){select(data.id);}
  else if(type==='alertPreview'){if(!opened){const parsed=HUDModel.parse(data.text,data.provider),reply=parsed.blocks.filter(x=>x.kind==='reply').at(-1)?.text||'';post({op:'alert',id:data.id,title:data.title,preview:reply.replace(/\s+/g,' ').slice(0,200)||'Click to read the latest output'});}}
  else if(type==='output'){
    reading=false;if(data.error){if(data.id===selected)notice(data.error);return;}
    outputs.set(data.id,data);if(data.id!==selected){read();return;}
    lastOutput=data.text;notice('');if(opened){unread.delete(selected);badge();}renderOutput();renderRoster();
  }else if(type==='prompt'){
    const pending=promptByRequest.get(data.requestID);if(!pending)return;promptByRequest.delete(data.requestID);sending=false;
    if(data.error){notice(data.error);if(/uncertain/i.test(data.error))uncertain.add(pending.id);}
    else{if(selected===pending.id&&$('prompt').value===pending.message)$('prompt').value='';if(drafts.get(pending.id)===pending.message)drafts.delete(pending.id);const sent=new Set(pending.images.map(x=>x.key));attachments.set(pending.id,imagesFor(pending.id).filter(x=>!sent.has(x.key)));notice('Prompt sent.');request('refresh');}renderHeader();
  }else if(type==='previewFolderChanged'){if(data.id===selected&&previewMode)loadPreviews();
  }else if(type==='previews'){renderPreviews(data);
  }else if(type==='preferences'){if(data.selectedAgent&&!selected)selected=data.selectedAgent;if(data.rosterWidth>=155)document.querySelector('aside').style.width=data.rosterWidth+'px';mode=data.mode||'chat';supportsAttachments=!!data.attachmentsSupported;supportsPreviews=!!data.previewsSupported;$('previews-tab').hidden=!supportsPreviews;supportsShepherdr=!!data.shepherdrSupported;rosterMode=supportsShepherdr&&data.rosterMode==='shepherdr'?'shepherdr':'herdr';renderModes();if(rosterMode==='shepherdr')renderRoster();}
  else if(type==='notice'){notice(data.message);}
};
window.handleEscape=()=>{if(attachmentPreview)closeAttachmentPreview();else request('close');};
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!event.isComposing){event.preventDefault();window.handleEscape();}});
$('refresh').onclick=()=>request('refresh');$('close').onclick=()=>request('close');$('hide').onclick=()=>request('hide');$('send').onclick=send;
$('reconcile').onclick=()=>{uncertain.delete(selected);notice('');renderHeader();};
$('search').oninput=()=>{filter=$('search').value.toLowerCase();renderRoster();};
$('prompt').oninput=()=>{drafts.set(selected,$('prompt').value);renderHeader();};
$('prompt').onkeydown=e=>{
  if(e.key!=='Enter'||e.isComposing||e.keyCode===229)return;
  // Modifier-Enter always inserts a newline, including Control on macOS,
  // whose native textarea behavior is not consistently a line break.
  e.preventDefault();
  if(e.shiftKey||e.ctrlKey||e.metaKey||e.altKey){
    const input=$('prompt');input.setRangeText('\n',input.selectionStart,input.selectionEnd,'end');
    input.dispatchEvent(new Event('input',{bubbles:true}));
  }else if(!e.repeat){send();}
};
for(const view of ['herdr','shepherdr'])$('mode-'+view).onclick=()=>{if(rosterMode===view)return;rosterMode=view;shepherdr=null;selectedRow='';notice('');request('preferences',{rosterMode:view});renderModes();renderRoster();renderHeader();badge();};
$('previews-tab').onclick=()=>{previewMode=true;lastRendered='';renderOutput();loadPreviews();};
$('preview-refresh').onclick=loadPreviews;
$('preview-folder').onclick=()=>request('choosePreviewFolder',{id:selected});
for(const view of ['chat','terminal'])$(view).onclick=()=>{previewMode=false;mode=view;request('preferences',{mode});lastRendered='';renderOutput();};
const divider=$('divider');divider.onpointerdown=e=>{divider.setPointerCapture(e.pointerId);};divider.onpointermove=e=>{if(divider.hasPointerCapture(e.pointerId)){document.querySelector('aside').style.width=Math.min(Math.max(e.clientX,155),innerWidth*.42)+'px';}};
divider.onpointerup=()=>request('preferences',{rosterWidth:document.querySelector('aside').offsetWidth});
divider.onkeydown=e=>{if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();const aside=document.querySelector('aside');aside.style.width=Math.min(Math.max(aside.offsetWidth+(e.key==='ArrowLeft'?-15:15),155),innerWidth*.42)+'px';request('preferences',{rosterWidth:aside.offsetWidth});}};
setInterval(()=>{const a=active();if(a?.agent_status==='working'){const seconds=Math.max(0,Math.floor((Date.now()-(since.get(a.id)||Date.now()))/1000));$('work-text').textContent=`Working · ${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')} observed`; }},1000);
request('ready');
// Read-only integration check used by --verify-ui; never presses Send.
window.verifyControls=async()=>{
  const saved={selected,filter,mode,draft:$('prompt').value,drafts:new Map(drafts)},results={};
  const wait=async predicate=>{const end=Date.now()+22000;while(!predicate()){if(Date.now()>end)throw Error('Timed out waiting for agent output');await new Promise(r=>setTimeout(r,100));}};
  try{
    const online=agents.filter(a=>a.online),first=online.find(a=>a.machine_id==='local'&&a.agent==='codex')||online.find(a=>a.machine_id==='local')||online[0];
    const second=online.find(a=>a.machine_id!==first?.machine_id)||online.find(a=>a.id!==first?.id);
    if(!first||!second)throw Error('This check requires two online agents');
    select(first.id);await wait(()=>outputs.has(first.id)&&!reading);results.firstOutput=outputs.get(first.id).text.length>0;
    $('prompt').value='HUD verification draft — never submitted';$('prompt').dispatchEvent(new Event('input'));
    select(second.id);await wait(()=>outputs.has(second.id)&&!reading);results.secondOutput=outputs.get(second.id).text.length>0;
    select(first.id);results.draftPreserved=$('prompt').value==='HUD verification draft — never submitted';
    $('terminal').click();results.terminalView=$('output').querySelector('pre')!==null;
    if(first.agent==='codex'){$('chat').click();results.chatView=$('chat').getAttribute('aria-pressed')==='true';}
    else results.chatDisabled=$('chat').disabled;
    $('search').value='a-nonexistent-agent-filter';$('search').dispatchEvent(new Event('input'));results.searchFilters=$('roster').querySelectorAll('.agent').length===0;
    const test=el('div');inline('<img src=x onerror=alert(1)>',test);results.transcriptIsText=test.querySelector('img')===null&&test.textContent.includes('<img');
    results.layoutFits=document.body.scrollWidth<=innerWidth&&document.body.scrollHeight<=innerHeight;
    results.pass=Object.values(results).every(Boolean);return results;
  }finally{drafts=new Map(saved.drafts);filter=saved.filter;mode=saved.mode;$('search').value=saved.filter;select(saved.selected);$('prompt').value=saved.draft;drafts=new Map(saved.drafts);request('preferences',{mode});renderHeader();renderOutput();}
};
