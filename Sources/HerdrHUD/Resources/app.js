'use strict';
const $=id=>document.getElementById(id);
const post=data=>window.webkit?.messageHandlers?.hud ? window.webkit.messageHandlers.hud.postMessage(data) : window.chrome.webview.postMessage(data);
if(window.chrome?.webview)window.chrome.webview.addEventListener('message',event=>window.receive(event.data));
let agents=[],selected='',opened=false,mode='chat',filter='',reading=false,sending=false,requestSequence=0,lastOutput='',lastRendered='',selectionEpoch=0;
let orcaSupported=false,orcaOpen=false,orcaStandalone=false,orcaModels=[],orcaCatalogRequest='',orcaLaunchRequest='',orcaChosen='',orcaBusy=false;
let supportsVideos=false,videoRequests=new Map();
let supportsAttachments=false,attachments=new Map(),attachmentLoads=new Map(),attachmentSequence=0,pendingAttachmentBytes=0;
let supportsPreviews=false,previewMode=false,previewRequestID='';
let supportsTerminalControls=false,terminalKeyRequests=new Map(),terminalKeyUncertain=new Set(),terminalScreenRendered='',terminalScreenAgent='';
let attachmentPreview=null,attachmentButtons=new Map();
let rosterMode='herdr',shepherdr=null,supportsShepherdr=false,selectedRow='';
let supportsNativeApprovals=false,nativeApprovalStates=new Map(),nativeApprovalRequests=new Map(),nativeApprovalsBusy=new Set(),newCodexBusy=false;
let completed=new Set(),queuedOutput=new Set(),quickPrompts=[],supportsQuick=false;
let queues=new Map(),queueSaving=false,queueHolds=new Map(),queuePaused=new Set(),steerReconcileRequests=new Map();
let supportsDrafts=false,draftsLoaded=true,draftLabels=new Map(),draftTouched=new Set(),draftPersistence=null,storageRequests=new Map(),storageFailed=false,pendingDraftPrompt=new Set(),pendingDraftKeys=new Set();
let baseline=false,unread=new Set(),drafts=new Map(),outputs=new Map(),since=new Map(),uncertain=new Set(),promptByRequest=new Map();
function request(op,extra={}){const requestID=`${Date.now()}-${++requestSequence}`;post({op,requestID,...extra});return requestID;}
function orcaApplies(){const a=active();return orcaSupported&&((a?.agent==='opencode'&&a.orca_managed===true)||(!a&&orcaStandalone));}
function renderOrcaPicker(rebuild=false){
  const visible=orcaApplies();$('orca-toggle').hidden=!visible;$('orca-toggle').setAttribute('aria-expanded',String(visible&&orcaOpen));$('orca-panel').hidden=!visible||!orcaOpen;
  $('orca-refresh').disabled=!!orcaCatalogRequest||orcaBusy;$('orca-search').disabled=orcaBusy;$('orca-select').disabled=orcaBusy||!!orcaCatalogRequest;
  if(rebuild){const visible=window.HUDOrcaModels?.search(orcaModels,$('orca-search').value)||[];const options=[el('option',visible.length?'Choose a model…':'No matching eligible models')];options[0].value='';for(const model of visible){const option=el('option',`${model.name||model.id} · ${model.releaseDate}`);option.value=model.id;options.push(option);}if(!visible.some(x=>x.id===orcaChosen))orcaChosen='';$('orca-select').replaceChildren(...options);$('orca-select').value=orcaChosen;}
  $('orca-launch').disabled=orcaBusy||!!orcaCatalogRequest||!orcaModels.some(x=>x.id===orcaChosen);
  $('orca-detail').textContent=window.HUDOrcaModels?.detail(orcaModels.find(x=>x.id===orcaChosen))||'';
}
function loadOrcaModels(){if(!orcaApplies()||orcaBusy||orcaCatalogRequest)return;orcaCatalogRequest=request('orcaModels');$('orca-status').textContent='Loading your eligible OrcaRouter models…';renderOrcaPicker();}
$('orca-toggle').onclick=()=>{if(!orcaApplies())return;orcaOpen=!orcaOpen;renderOrcaPicker();if(orcaOpen&&!orcaModels.length)loadOrcaModels();};
$('orca-close').onclick=()=>{orcaOpen=false;renderOrcaPicker();};
$('orca-refresh').onclick=loadOrcaModels;
$('orca-search').oninput=()=>renderOrcaPicker(true);
$('orca-select').onchange=()=>{orcaChosen=$('orca-select').value;renderOrcaPicker();};
$('orca-launch').onclick=()=>{if(!orcaApplies()||$('orca-launch').disabled)return;orcaBusy=true;orcaLaunchRequest=request('orcaLaunch',{model:orcaChosen});$('orca-status').textContent='Choose the project folder for this new OpenCode chat.';renderOrcaPicker();};
function active(){const a=agents.find(a=>a.id===selected);if(a||!selected.startsWith('shepherdr:'))return a;const r=linked(selected);return r&&{id:r.view_id,online:true,agent_status:'readonly',agent:'shepherdr',workspace_label:r.space||r.title,machine_label:r.machine};}
function statusLabel(a){return window.HUDUtilities?.status(a,completed.has(a?.id))||a?.agent_status||'Unknown';}
function atBottom(){return window.HUDUtilities?.nearBottom($('output'))??true;}
function name(a){return a.tab_label||a.name||a.pane_id||'Agent';}
function rows(){return rosterMode==='shepherdr'&&supportsShepherdr?HUDModel.shepherdrRows(shepherdr,agents):null;}
function linked(id){return id?rows()?.find(r=>r.view_id===id):undefined;}
function label(a){return linked(a.id)?.title||name(a);}
function el(tag,text,cls){const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;}
function notice(text){$('notice').hidden=!text;$('notice').textContent=text;}
function badge(){const list=rows();post({op:'badge',count:list?list.filter(r=>r.need||unread.has(r.agent_id)).length:agents.filter(a=>a.agent_status==='blocked'||unread.has(a.id)).length});}
// Follow replacement sessions only when no draft would be moved implicitly.
function follow(){if(!selectedRow)selectedRow=linked(selected)?.key||'';const r=selectedRow&&rows()?.find(r=>r.key===selectedRow);if(!r?.view_id||r.view_id===selected)return;if(($('prompt').value||drafts.get(selected))||imagesFor(selected).length||attachmentLoads.get(selected)||queueFor(selected).length){notice('This agent changed. Your draft stays with its original session. Select the new agent and use Saved drafts to copy it.');return;}if(uncertain.has(selected))uncertain.add(r.view_id);drafts.set(r.view_id,$('prompt').value);select(r.view_id);}
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
    const title=el('div',undefined,'agent-title');title.append(el('span',undefined,'dot '+(a.agent_status==='working'?'busy':a.agent_status==='blocked'||unread.has(a.id)?'attention':'')),el('span',name(a)));if(unread.has(a.id))title.append(el('span','New','unread-pill'));button.append(title);
    const meta=el('div',undefined,'agent-meta');meta.append(el('div',a.workspace_label||a.workspace_id),el('div',a.machine_label+' · '+(a.agent||'agent')),el('div',statusLabel(a),'agent-state'));button.append(meta);const metadata=HUDModel.parse(outputs.get(a.id)?.text||'',a.agent);button.title=metadata.model?`${metadata.model} ${metadata.reasoning}`:a.pane_id;button.onclick=()=>select(a.id);return button;}));
  if(!items.length)roster.append(el('p',agents.length?'No matching agents.':'No agents found. Start an agent in Herdr.','empty'));roster.scrollTop=scroll;
}
function select(id){
  orcaStandalone=false;
  if(id!==selected)closeAttachmentPreview(false);
  if(selected)drafts.set(selected,$('prompt').value);selectedRow=linked(id)?.key||'';selected=id;request('preferences',{selectedAgent:id});selectionEpoch++;lastRendered='';$('prompt').value=drafts.get(id)||'';
  lastOutput=outputs.get(id)?.text||'';queuedOutput.delete(id);unread.delete(id);badge();if(previewMode)loadPreviews();renderRoster();renderHeader();renderOutput();read();if(supportsNativeApprovals)request('nativeApprovals',{id});
}
function queueFor(id){return queues.get(id)||[];}
function canQueue(a){return !!(supportsDrafts&&window.HUDFollowups&&a?.online&&['codex','claude','opencode'].includes(a.agent)&&['working','idle','done'].includes(a.agent_status));}
function steerState(a){const s=nativeApprovalStates.get(a?.id);return a?.agent_status==='working'&&s?.canSteer&&!s.steerUncertain?s:null;}
function renderHeader(){
  renderOrcaPicker();
  const a=active(),row=a&&linked(a.id);$('title').textContent=a?label(a):draftLabels.get(selected)||'Select an agent';$('identity').textContent=row?`${row.kind==='task'?row.space+' · ':''}${row.machine} · ${row.state} · ${a.agent}`:a?`${a.workspace_label} · ${a.machine_label} · ${a.agent}`:'Your configured Herdr machines appear automatically';
  $('previews-tab').hidden=!supportsPreviews;$('preview-folder').disabled=!a||a.machine_id!=='local';$('preview-refresh').disabled=!a||a.machine_id!=='local';
  $('agent-status').textContent=statusLabel(a);$('agent-status').className='status-chip '+(a?.agent_status||'unknown');
  const state=a?.agent_status||'';const busy=state==='working';$('working').hidden=!busy;
  if(busy&&!since.has(a.id))since.set(a.id,Date.now());
  const steer=steerState(a),queueMode=canQueue(a)&&(!steer&&(busy||queueFor(selected).length>0||queueHolds.has(selected)));
  $('send').textContent=steer?'Send update ↗':queueMode?'Queue prompt +':'Send prompt ↗';
  $('send').disabled=!draftsLoaded||storageFailed||!a?.online||(!steer&&!queueMode&&(a.can_prompt===false||!['idle','done'].includes(state)))||sending||queueSaving||uncertain.has(selected)||(! $('prompt').value.trim()&&!imagesFor(selected).length)||!!attachmentLoads.get(selected)||(imagesFor(selected).length>0&&!canAttach(a));
  $('queue-instead').hidden=!steer||!canQueue(a);$('queue-instead').disabled=$('send').disabled;
  $('prompt').disabled=!a||!draftsLoaded;$('chat').disabled=a?.agent!=='codex';
  $('send-status').textContent=sending?'Sending once…':uncertain.has(selected)?'Delivery uncertain. Inspect this agent in Herdr before sending again.':!a?'Choose an agent to get started.':!a.online?'Machine offline. Your draft is retained.':state==='readonly'?'Not running. Its Shepherdr chat is shown, read only.':state==='blocked'?'Needs your input in Herdr. Native approvals remain in its terminal.':busy?(steer?'Send an update to the active Codex task.':canQueue(a)?'Queue another prompt. It will send when this agent is ready.':'Agent is working. You can draft the next prompt here.'):a.can_prompt===false?'Waiting for the agent to report idle. Continue in Herdr if needed.':['idle','done'].includes(state)?'Ready for your next prompt.':'Agent state is unknown. Sending is disabled.';
  $('reconcile').hidden=!uncertain.has(selected);
  renderQueue();renderNativeApprovals();renderTerminalControls();renderSuggestions();renderQuickPrompts();renderFileLinks();$('jump-latest').hidden=!queuedOutput.has(selected);$('draft-status').textContent=!supportsDrafts?'':!draftsLoaded?'Restoring saved drafts…':storageFailed?'Draft not saved — keep the HUD open.':'Draft recovery on';
  $('attach').hidden=!supportsAttachments;$('attach').disabled=!canAttach(a)||sending||queueSaving||uncertain.has(selected);renderAttachments();
}
function inline(text,parent){ // No terminal text is ever interpreted as HTML.
  for(const part of text.split(/(\*\*[^*]+\*\*|`[^`]+`)/g)){if(part.startsWith('**')&&part.endsWith('**'))parent.append(el('strong',part.slice(2,-2)));else if(part.startsWith('`')&&part.endsWith('`'))parent.append(el('code',part.slice(1,-1)));else parent.append(document.createTextNode(part));}
}
function renderOutput(){
  $('output').hidden=previewMode;$('previews').hidden=!previewMode;$('previews-tab').setAttribute('aria-pressed',String(previewMode));
  const a=active(),out=$('output'),data=HUDModel.parse(lastOutput,a?.agent||'');const terminal=mode==='terminal'||a?.agent!=='codex';
  renderTerminalControls();
  const signature=JSON.stringify([selected,lastOutput,terminal]);if(signature===lastRendered)return;const wasBottom=out.scrollHeight-out.scrollTop-out.clientHeight<70,scroll=out.scrollTop;const first=!lastRendered;lastRendered=signature;
  const expanded=new Set([...out.querySelectorAll('details[open]')].map(n=>n.dataset.key));out.replaceChildren();
  if(!lastOutput)out.append(el('p',a?'Loading recent output…':'Select an agent to read its recent output.','empty'));
  else if(terminal||!data.blocks.length)out.append(el('pre',data.text));
  else data.blocks.forEach((block,index)=>{const node=el('div',undefined,'block '+block.kind);
    if(block.kind==='approval'){renderApproval(block,node);}else if(block.kind==='tool'){const detail=el('details');detail.dataset.key=block.kind+block.text.split('\n')[0]+index;detail.open=expanded.has(detail.dataset.key);detail.append(el('summary',block.text.split('\n')[0]),el('pre',block.text));node.append(detail);}
    else{if(block.kind==='prompt')node.append(el('div','You','block-label'));else if(block.kind==='reply')node.append(el('div',data.model||a.agent,'block-label'));inline(block.text,node);}out.append(node);});
  if(data.model){$('title').title=`${data.model} ${data.reasoning}`;for(const button of $('roster').children)if(button.getAttribute('aria-pressed')==='true')button.title=`${data.model} ${data.reasoning}`;}
  $('chat').setAttribute('aria-pressed',String(!previewMode&&!terminal));$('terminal').setAttribute('aria-pressed',String(!previewMode&&terminal));
  out.scrollTop=first||wasBottom?out.scrollHeight:scroll;
}
function renderSuggestions(){
  const target=$('suggested-replies'),a=active();
  const visible=!!window.HUDSuggestions&&a?.online&&['idle','done'].includes(a.agent_status)&&a.can_prompt!==false&&!sending&&!uncertain.has(selected)&&!outputs.get(selected)?.terminalControl;
  target.hidden=!visible;if(!visible)return;
  const suggestions=window.HUDSuggestions.extract(HUDModel.parse(outputs.get(selected)?.text||'',a.agent));
  target.replaceChildren(...suggestions.map(item=>{const button=el('button',item.label);button.title=item.text;button.onclick=()=>{
    const current=active();if(selected!==a.id||!current?.online||!['idle','done'].includes(current.agent_status)||current.can_prompt===false||sending||uncertain.has(selected)||outputs.get(selected)?.terminalControl)return;
    const input=$('prompt');input.value+=(input.value.trim()?'\n\n':'')+item.text;input.oninput();input.focus();
  };return button;}));target.hidden=!suggestions.length;
}
function renderApproval(block,node){
  node.setAttribute('role','region');node.setAttribute('aria-label','Computer Use approval in Herdr');
  node.append(el('div','Computer Use permission','block-label'),el('div',block.question,'approval-question'));
  const list=el('ol',undefined,'approval-options');
  for(const option of block.options){const item=el('li',undefined,'approval-option'+(option.selected?' current':''));
    item.append(el('span',String(option.number),'approval-number'),el('strong',option.label));
    if(option.description)item.append(el('div',option.description,'approval-description'));
    if(option.selected)item.append(el('span','Selected in terminal','approval-current'));list.append(item);}
  node.append(list,el('div',block.footer,'approval-footer'));
}
function renderTerminalControls(){
  const a=active(),preview=outputs.get(selected)?.terminalControl;
  const visible=!nativeCardsVisible()&&supportsTerminalControls&&a?.online&&a.agent_status==='blocked'&&['permission','question'].includes(a.input_kind)&&preview&&typeof preview.token==='string'&&typeof preview.text==='string';
  $('terminal-controls').hidden=!visible;
  $('output').hidden=!!visible||previewMode;$('previews').hidden=!!visible||!previewMode;
  if(!visible)return;
  $('send-status').textContent='Needs your input. Choose using the terminal controls above.';
  const screen=$('terminal-screen'),screenSignature=JSON.stringify([selected,preview.text]);
  if(screenSignature!==terminalScreenRendered){
    const scroll=terminalScreenAgent===selected?screen.scrollTop:0,expanded=screen.querySelectorAll('details[open]').length>0;
    screen.replaceChildren();
    const parsed=HUDModel.parse(preview.text,a.agent),card=parsed.blocks.filter(b=>b.kind==='approval').at(-1);
    if(card){
      const node=el('div',undefined,'block approval');renderApproval(card,node);screen.append(node);
      // Keep every byte of the checked screen accessible, including transcript
      // context before the active menu, while making the decision readable first.
      const raw=el('details');raw.open=expanded;raw.append(el('summary','Full terminal screen'),el('pre',preview.text));screen.append(raw);
    }else screen.append(el('pre',preview.text));
    terminalScreenRendered=screenSignature;terminalScreenAgent=selected;screen.scrollTop=scroll;
  }
  const uncertain=preview.uncertain||terminalKeyUncertain.has(selected),busy=terminalKeyRequests.size>0||pendingDraftKeys.size>0;
  const choices=Array.isArray(preview.choices)&&preview.choiceToken?preview.choices:[];
  $('approval-choices').hidden=!choices.length;
  $('approval-choices').replaceChildren?.(...choices.map(item=>{const b=el('button','Send '+item.key);b.title='Displayed option: '+item.label;b.disabled=busy||uncertain;b.onclick=()=>approvalChoice(item.key);return b;}));
  $('terminal-heading').textContent=choices.length?'Guarded number keys':'Manual terminal controls';
  $('terminal-hint').textContent=choices.length?'Each button sends one digit if the observed terminal screen is unchanged. The terminal’s keybindings decide whether it selects or submits an option. No Enter is added.':'These keys go to the terminal, including Enter to submit its current selection. Keys wait for terminal output to become quiet and may be delayed. Use one control at a time.';

  for(const key of ['up','down','enter','esc'])$('terminal-'+key).disabled=busy||uncertain;
  $('terminal-key-reconcile').hidden=!uncertain;$('terminal-key-reconcile').disabled=busy;
  $('terminal-key-status').textContent=busy?'Sending one terminal key…':uncertain?'Key delivery uncertain. Check this agent in Herdr before enabling another key.':'Review the screen above before each key. The screen check cannot prevent changes during delivery.';
}
function terminalKey(key){
  if(nativeCardsVisible())return;
  const a=active(),preview=outputs.get(selected)?.terminalControl;
  if(!supportsTerminalControls||!a?.online||a.agent_status!=='blocked'||!['permission','question'].includes(a.input_kind)||!preview||terminalKeyRequests.size||preview.uncertain||terminalKeyUncertain.has(selected)||!['up','down','enter','esc'].includes(key))return;
  const id=selected;if(pendingDraftKeys.size)return;pendingDraftKeys.add(id);renderTerminalControls();beforeMutation(()=>{const requestID=request('terminalKey',{id,token:preview.token,key});terminalKeyRequests.set(requestID,{id,operation:'terminalKey'});pendingDraftKeys.delete(id);renderTerminalControls();},()=>{pendingDraftKeys.delete(id);renderTerminalControls();});
}
function approvalChoice(key){
  if(nativeCardsVisible())return;
  const a=active(),preview=outputs.get(selected)?.terminalControl;
  if(!supportsTerminalControls||!a?.online||a.agent_status!=='blocked'||!preview?.choiceToken||!preview.choices?.some(x=>x.key===key)||terminalKeyRequests.size||pendingDraftKeys.size||preview.uncertain||terminalKeyUncertain.has(selected))return;
  const id=selected,token=preview.choiceToken;pendingDraftKeys.add(id);renderTerminalControls();
  beforeMutation(()=>{const requestID=request('approvalChoice',{id,token,key});terminalKeyRequests.set(requestID,{id,operation:'approvalChoice'});pendingDraftKeys.delete(id);renderTerminalControls();},()=>{pendingDraftKeys.delete(id);renderTerminalControls();});
}
for(const key of ['up','down','enter','esc'])$('terminal-'+key).onclick=()=>terminalKey(key);
$('terminal-key-reconcile').onclick=()=>{
  if(terminalKeyRequests.size)return;
  const id=selected,requestID=request('reconcileTerminalKeys',{id});terminalKeyRequests.set(requestID,{id,operation:'reconcileTerminalKeys'});renderTerminalControls();
};
function nativeCardsVisible(){const state=nativeApprovalStates.get(selected);return supportsNativeApprovals&&!!state?.connected&&Array.isArray(state.cards)&&state.cards.length>0;}
function renderNativeApprovals(){
  const state=nativeApprovalStates.get(selected),box=$('native-approvals');box.hidden=!supportsNativeApprovals||!state?.linked;if(box.hidden)return;
  $('native-approval-context').textContent='Linked chat: '+(state.threadId||'')+' · This approval belongs to this chat ID.';
  $('native-approval-status').textContent=state.status||'Waiting for approval requests.';
  $('native-reconnect').hidden=!!state.connected;
  if(state.connected&&(state.cards||[]).length)$('send-status').textContent='Respond to the Codex approval above. Your draft stays here.';
  const target=$('native-approval-cards');
  target.replaceChildren?.(...(state.cards||[]).map(card=>{
    const node=el('div',undefined,'native-approval-card');node.append(el('strong',card.question||'Approval requested'));
    if(card.detail)node.append(el('pre',card.detail));
    const actions=el('div',undefined,'native-approval-actions');
    for(const choice of card.choices||[]){const b=el('button',choice.label);b.disabled=!state.connected||!!card.pending||nativeApprovalsBusy.has(card.token);b.onclick=()=>sendNativeApproval(card.token,choice.key);actions.append(b);}
    node.append(actions);if(card.pending)node.append(el('p','Sending response… Waiting for Codex to resolve this request.'));return node;
  }));
}
function sendNativeApproval(token,choice){
  const state=nativeApprovalStates.get(selected),card=state?.cards?.find(c=>c.token===token);
  if(!supportsNativeApprovals||!state?.connected||!card||card.pending||nativeApprovalsBusy.has(token)||!card.choices?.some(c=>c.key===choice))return;
  nativeApprovalsBusy.add(token);const requestID=request('nativeApprovalResponse',{id:selected,token,choice});nativeApprovalRequests.set(requestID,{id:selected,token});renderNativeApprovals();
}
$('native-reconnect').onclick=()=>{if(supportsNativeApprovals)request('nativeApprovals',{id:selected,reconnect:true});};
$('new-codex').onclick=()=>{if(!supportsNativeApprovals)return;$('new-codex-status').textContent='Choose its project folder to start.';$('new-codex-dialog').showModal();};
$('new-codex-cancel').onclick=()=>{if(!newCodexBusy)$('new-codex-dialog').close();};
$('new-codex-start').onclick=()=>{if(newCodexBusy)return;newCodexBusy=true;$('new-codex-start').disabled=true;$('new-codex-cancel').disabled=true;$('new-codex-status').textContent='Starting a new Codex session…';request('newCodexSession');};
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
function canAttach(a=active()){return supportsAttachments&&a?.can_attach===true&&a.online&&['claude','codex','opencode'].includes(a.agent);}
function closeAttachmentPreview(restore=true){
  if(!attachmentPreview)return;
  const key=attachmentPreview.key;attachmentPreview=null;$('attachment-preview').close();
  if(restore)(attachmentButtons.get(key)||$('attach')).focus();
}
function openAttachmentPreview(item){
  if(item.kind==='video'){request('openVideo',{id:selected,attachment:window.HUDDrafts.serializeAttachment(item)});return;}
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
    preview.type='button';preview.setAttribute('aria-label','Preview '+item.name);preview.append(image);if(item.kind==='video')preview.append(el('span','▶','video-play'));preview.onclick=()=>openAttachmentPreview(item);attachmentButtons.set(item.key,preview);
    const remove=el('button','×');remove.setAttribute('aria-label','Remove '+item.name);remove.disabled=sending||queueSaving||uncertain.has(selected);
    remove.onclick=()=>{attachments.set(selected,imagesFor(selected).filter(x=>x.key!==item.key));draftChanged();renderHeader();};
    chip.append(preview,el('span',item.name+(item.kind==='video'?' · MP4':'')),remove);return chip;
  }));
}
function videoRequest(op,data){return new Promise((resolve,reject)=>{const id=request(op,data);const timer=setTimeout(()=>{videoRequests.delete(id);reject(new Error('Video import timed out. Attach the file again.'));},60000);videoRequests.set(id,{resolve,reject,timer});});}
function canStageVideos(count){
  if(!supportsVideos||!draftsLoaded||!canAttach()||sending||queueSaving||uncertain.has(selected)){notice('MP4 files are available for local Claude, Codex and managed OpenCode chats.');return false;}
  if(imagesFor(selected).length+(attachmentLoads.get(selected)||0)+count>3){notice('Attach up to three images or MP4 videos.');return false;}return true;
}
function acceptVideo(id,item){
  const value=window.HUDDrafts.serializeAttachment(item),next=new Map(attachments);next.set(id,[...imagesFor(id),{...value,key:++attachmentSequence,url:value.poster}]);window.HUDDrafts.snapshot({...draftState(),attachments:next});attachments=next;draftChanged();
}
async function stageVideoOffer(data){
  if(data.id!==selected||!canStageVideos(data.count))return;const id=selected;
  attachmentLoads.set(id,(attachmentLoads.get(id)||0)+data.count);renderHeader();
  try{const result=await videoRequest('videoImport',{id,offer:data.offer});for(const item of result.attachments||[])acceptVideo(id,item);}
  catch(error){notice(error.message||'Could not import video.');}
  finally{attachmentLoads.set(id,Math.max(0,(attachmentLoads.get(id)||0)-data.count));renderHeader();}
}
async function stageVideos(files){
  if(!files.length||!canStageVideos(files.length))return;const id=selected;
  if(files.some(f=>!f.size||f.size>100*1024*1024)){notice('MP4 videos must be under 100 MB each.');return;}
  attachmentLoads.set(id,(attachmentLoads.get(id)||0)+files.length);renderHeader();
  for(const file of files){let token='';try{
    token=(await videoRequest('videoBegin',{id,name:file.name,bytes:file.size})).token;
    for(let offset=0;offset<file.size;offset+=1024*1024){
      const chunk=file.slice(offset,Math.min(file.size,offset+1024*1024));
      const data=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(',')[1]);reader.onerror=()=>reject(new Error('Could not read video.'));reader.readAsDataURL(chunk);});
      await videoRequest('videoChunk',{id,token,offset,data});
    }
    const result=await videoRequest('videoFinish',{id,token});acceptVideo(id,result.attachment);
  }catch(error){if(token)request('videoCancel',{id,token});notice(error.message||'Could not import video.');}
  finally{attachmentLoads.set(id,Math.max(0,(attachmentLoads.get(id)||0)-1));renderHeader();}}
}
function stageFiles(files){
  const list=Array.from(files),videos=list.filter(f=>f.type==='video/mp4'||/\.mp4$/i.test(f.name||'')),images=list.filter(f=>!videos.includes(f));
  if(imagesFor(selected).length+(attachmentLoads.get(selected)||0)+list.length>3){notice('Attach up to three images or MP4 videos.');return;}
  if(images.length)stageImages(images);if(videos.length)stageVideos(videos);
}
async function stageImages(files){
  if(!draftsLoaded||!canAttach()||sending||queueSaving||uncertain.has(selected)){notice('Images are available for local Claude, Codex, and managed OpenCode chats.');return;}
  const id=selected,list=Array.from(files),count=imagesFor(id).length+(attachmentLoads.get(id)||0);
  const stagedBytes=[...attachments.values(),...[...queues.values()].flat().map(item=>item.images)].flat().reduce((n,item)=>n+(item.kind==='video'?0:item.bytes),0)+pendingAttachmentBytes;
  if(!list.length)return;
  if(stagedBytes+list.reduce((n,f)=>n+f.size,0)>24*1024*1024){notice('Drafts and queued images total 24 MB. Remove an image or queued prompt first.');return;}
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
    finally{draftChanged();pendingAttachmentBytes-=file.size;attachmentLoads.set(id,Math.max(0,(attachmentLoads.get(id)||0)-1));renderHeader();}
  }
}
$('attach').onclick=()=>$('attachment-files').click();
$('attachment-files').onchange=e=>{stageFiles(e.target.files);e.target.value='';};
$('prompt').onpaste=e=>{
  const clipboard=e.clipboardData;if(!clipboard)return;
  // Items and files can describe the same clipboard image; use files only as a fallback.
  let files=Array.from(clipboard.items||[]).filter(item=>item.kind==='file').map(item=>item.getAsFile()).filter(Boolean);
  if(!files.length)files=Array.from(clipboard.files||[]);
  files=files.filter(file=>file.type.startsWith('image/')||file.type==='video/mp4'||/\.mp4$/i.test(file.name||''));
  if(!files.length)return;
  e.preventDefault();
  // A mixed clipboard still inserts its plain text at the current selection.
  const text=files.some(file=>file.type==='video/mp4'||/\.mp4$/i.test(file.name||''))?'':clipboard.getData?.('text/plain');
  if(text){const input=$('prompt');input.setRangeText(text,input.selectionStart,input.selectionEnd,'end');input.oninput();}
  stageFiles(files);
};
// Prevent WebKit's default path insertion/navigation for every file drop, including unsupported agents.
for(const kind of ['dragover','drop'])document.addEventListener(kind,e=>{
  if(!Array.from(e.dataTransfer?.types||[]).includes('Files'))return;
  e.preventDefault();
  if(kind==='drop'){stageFiles(e.dataTransfer.files);}
});
function read(){if(!opened||reading||!active()?.online)return;reading=true;request('output',{id:selected});}
function renderQueue(){
  const items=queueFor(selected),panel=$('prompt-queue');panel.hidden=!items.length;
  if(!items.length)return;
  $('queue-title').textContent=`${items.length} queued prompt${items.length===1?'':'s'}`;
  const paused=queuePaused.has(selected)||uncertain.has(selected)||items[0]?.status==='uncertain';
  $('queue-status').textContent=paused?'Paused — inspect this session before continuing.':queueHolds.has(selected)?'Waiting for this task to finish.':'Sends in order when this agent is ready.';
  $('queue-resume').hidden=!paused&&!queueHolds.has(selected);
  $('queue-resume').disabled=sending||queueSaving||storageFailed||!active()?.online||active()?.agent_status!=='idle'||uncertain.has(selected)||items[0]?.status!=='queued';
  const signature=JSON.stringify([selected,items.map(x=>[x.token,x.text,x.images.length,x.status]),sending,queueSaving]);
  if(panel._signature===signature)return;panel._signature=signature;
  $('queue-items').replaceChildren(...items.map((item,index)=>{
    const row=el('div',undefined,'queued-prompt');row.append(el('span',`${index+1}. ${item.text.slice(0,150)||'Attachment prompt'}${item.images.length?` · ${item.images.length} file(s)`:''}`));
    const remove=el('button',item.status==='uncertain'?'Discard uncertain item':'Remove');remove.disabled=item.status==='pending'||queueSaving||sending;
    remove.onclick=()=>{if(remove.disabled)return;try{window.HUDFollowups.remove(queues,selected,item.token);draftChanged();renderHeader();}catch(error){notice(error.message);}};row.append(remove);return row;
  }));
}
function clearSentDraft(id,message,images){
  if(selected===id&&$('prompt').value===message)$('prompt').value='';
  if(drafts.get(id)===message)drafts.delete(id);
  const sent=new Set(images.map(x=>x.key));attachments.set(id,imagesFor(id).filter(x=>!sent.has(x.key)));
}
function enqueuePrompt(){
  const id=selected,message=$('prompt').value,images=imagesFor(id).slice();
  const token=`queue-${Date.now()}-${++requestSequence}`;
  try{window.HUDFollowups.enqueue(queues,id,{token,text:message,images});}
  catch(error){notice(error.message);return;}
  // Move the captured intent atomically: disk must never contain both a queued
  // item and the unchanged composer copy after an acknowledged enqueue.
  clearSentDraft(id,message,images);queueSaving=true;renderHeader();
  beforeMutation(()=>{queueSaving=false;notice('Prompt saved in the queue.');renderHeader();pumpQueue();},()=>{
    window.HUDFollowups.remove(queues,id,token);queueSaving=false;queuePaused.add(id);
    const live=selected===id?$('prompt').value:drafts.get(id)||'';
    const restored=message+(message&&live?'\n\n':'')+live;drafts.set(id,restored);if(selected===id)$('prompt').value=restored;
    attachments.set(id,[...images,...imagesFor(id)]);renderHeader();
  });
}
function observeQueueCycles(){
  for(const a of agents){const hold=queueHolds.get(a.id);if(!hold)continue;
    if(a.agent_status==='working')queueHolds.set(a.id,'await-idle');
    else if(a.agent_status==='idle'&&hold==='await-idle')queueHolds.delete(a.id);
  }
}
function pumpQueue(){
  if(!supportsDrafts||!draftsLoaded||storageFailed||queueSaving||sending)return;
  const a=agents.find(a=>a.online&&a.agent_status==='idle'&&a.can_prompt!==false&&queueFor(a.id).length&&!queueHolds.has(a.id)&&!queuePaused.has(a.id)&&!uncertain.has(a.id)&&!terminalKeyUncertain.has(a.id));
  if(!a)return;const item=window.HUDFollowups.head(queues,a.id);if(!item||item.status!=='queued')return;
  window.HUDFollowups.begin(queues,a.id,item.token);queueHolds.set(a.id,'await-working');
  sendPrompt(a.id,item.text,item.images,{queueToken:item.token});
}
$('queue-instead').onclick=()=>{if(!$('queue-instead').hidden&&!$('queue-instead').disabled)enqueuePrompt();};
$('queue-resume').onclick=()=>{if($('queue-resume').disabled)return;queuePaused.delete(selected);queueHolds.delete(selected);renderHeader();pumpQueue();};

function send(){
  if($('send').disabled)return;
  const a=active(),steer=steerState(a);
  if(!steer&&canQueue(a)&&(a.agent_status==='working'||queueFor(selected).length||queueHolds.has(selected))){enqueuePrompt();return;}
  const id=selected,message=$('prompt').value,images=imagesFor(id).slice();
  sendPrompt(id,message,images,steer?{operation:'nativeSteer',expectedTurnId:steer.activeTurnId}:{});
}
function sendPrompt(id,message,images,options={}){
  sending=true;notice('');if(!options.operation)queueHolds.set(id,'await-working');pendingDraftPrompt.add(id);renderHeader();
  beforeMutation(()=>{const operation=options.operation||(options.queueToken?'queuedPrompt':'prompt');const requestID=request(operation,{id,message,attachments:images.map(x=>x.kind==='video'?window.HUDDrafts.serializeAttachment(x):({data:x.data})),...(options.expectedTurnId?{expectedTurnId:options.expectedTurnId}:{}),...(options.queueToken?{queueToken:options.queueToken}:{})});promptByRequest.set(requestID,{id,message,images,operation,queueToken:options.queueToken});pendingDraftPrompt.delete(id);},()=>{pendingDraftPrompt.delete(id);sending=false;if(options.queueToken){window.HUDFollowups.settle(queues,id,options.queueToken,false);queuePaused.add(id);}renderHeader();});
}
window.receive=({type,data})=>{
  if(type==='videoOffer'){stageVideoOffer(data);return;}
  if(['videoBegin','videoChunk','videoFinish','videoImport'].includes(type)){const pending=videoRequests.get(data.requestID);if(!pending)return;videoRequests.delete(data.requestID);clearTimeout(pending.timer);if(data.error)pending.reject(new Error(data.error));else pending.resolve(data);return;}
  if(type==='openVideo'||type==='videoCancel'){if(data.error)notice(data.error);return;}

  if(type==='openOrcaModels'){const target=agents.find(a=>a.agent==='opencode'&&a.orca_managed===true);select(target?.id||'');orcaStandalone=!target;orcaOpen=true;renderOrcaPicker();loadOrcaModels();}else if(type==='orcaModels'){
    if(data.requestID!==orcaCatalogRequest)return;orcaCatalogRequest='';
    if(data.error){orcaModels=[];orcaChosen='';$('orca-status').textContent=data.error;}
    else{orcaModels=data.models||[];$('orca-policy').textContent=`Released since ${data.cutoffDate} · Claude/OpenAI and automatic routers excluded · Unknown dates hidden`;$('orca-status').textContent=orcaModels.length?`${orcaModels.length} eligible models. Choose one, then click Open new OpenCode chat.`:'No models currently meet your provider and verified-release-date filters.';}
    renderOrcaPicker(true);
  }else if(type==='orcaLaunch'){
    if(data.requestID!==orcaLaunchRequest)return;orcaLaunchRequest='';orcaBusy=false;
    $('orca-status').textContent=data.error|| (data.cancelled?'No chat opened.':'OpenCode chat opened in Herdr.');renderOrcaPicker();if(!data.error&&!data.cancelled)request('refresh');
  }else if(type==='roster'){
    const before=agents;agents=data.agents||[];observeQueueCycles();shepherdr=data.shepherdr||(rosterMode==='shepherdr'?shepherdr:null);
    if(baseline)for(const a of agents){const old=before.find(b=>b.id===a.id);if(old&&a.online&&old.online&&old.agent_status==='working'&&['idle','done'].includes(a.agent_status)){completed.add(a.id);unread.add(a.id);}if(a.agent_status==='working')completed.delete(a.id);if(old&&a.agent_status==='blocked'&&old.agent_status!=='blocked')unread.add(a.id);}
    const updates=baseline?HUDModel.alerts(before,agents):[];baseline=true;
    for(const a of agents){if(a.agent_status==='working'&&!since.has(a.id))since.set(a.id,Date.now());if(a.agent_status!=='working')since.delete(a.id);}
    for(const a of agents){draftLabels.set(a.id,label(a));if(a.orca_uncertain){uncertain.add(a.id);draftChanged();}}
    const valid=new Set(agents.map(a=>a.id));unread=new Set([...unread].filter(id=>valid.has(id)));
    if(updates.length&&!opened){const a=updates[0];request('alertPreview',{id:a.id,title:label(a)+(a.agent_status==='blocked'?' needs input':' finished')});}
    $('machines').replaceChildren(...(data.machines||[]).map(m=>{const node=el('span',undefined,'machine');node.append(el('span',undefined,'dot '+(m.online?'online':'')),document.createTextNode(`${m.label} · ${m.online?`${m.count} agents`:'offline'}`));node.title=m.error||'';return node;}));
    if(data.discoveryError)notice('Herdr setup: '+data.discoveryError);else if(rosterMode==='shepherdr'&&data.shepherdr?.error)notice('Shepherdr: '+data.shepherdr.error);
    follow();if(!selected&&!orcaStandalone&&agents.length)select(rows()?.find(r=>r.agent_id)?.agent_id||agents[0].id);renderRoster();renderHeader();badge();read();pumpQueue();
  }else if(type==='visibility'){opened=data.open;if(opened){renderHeader();read();}}
  else if(type==='resetBaseline'){baseline=false;}
  else if(type==='select'){select(data.id);}
  else if(type==='alertPreview'){if(!opened){const parsed=HUDModel.parse(data.text,data.provider),reply=parsed.blocks.filter(x=>x.kind==='reply').at(-1)?.text||'';post({op:'alert',id:data.id,title:data.title,preview:HUDModel.notificationPreview(reply)});}}
  else if(type==='output'){
    reading=false;if(data.error){if(data.id===selected)notice(data.error);return;}
    outputs.set(data.id,data);if(data.id!==selected){read();return;}
    const changed=lastOutput!==data.text;notice('');if(changed&&lastRendered&&opened&&!atBottom()&&!data.terminalControl){queuedOutput.add(selected);unread.add(selected);renderHeader();renderRoster();badge();return;}lastOutput=data.text;if(opened&&!previewMode){unread.delete(selected);queuedOutput.delete(selected);badge();}renderOutput();renderRoster();renderHeader();
  }else if(type==='terminalKey'||type==='approvalChoice'||type==='reconcileTerminalKeys'){
    const pending=terminalKeyRequests.get(data.requestID);if(!pending||pending.operation!==type)return;terminalKeyRequests.delete(data.requestID);
    if(data.error){notice(data.error);if(/uncertain/i.test(data.error))terminalKeyUncertain.add(pending.id);}
    else if(type==='reconcileTerminalKeys')terminalKeyUncertain.delete(pending.id);
    const output=outputs.get(pending.id);if(output)delete output.terminalControl;
    draftChanged();renderTerminalControls();request('refresh');read();
  }else if(type==='prompt'||type==='queuedPrompt'||type==='nativeSteer'){
    const pending=promptByRequest.get(data.requestID);if(!pending||pending.operation!==type)return;promptByRequest.delete(data.requestID);sending=false;
    if(data.error){notice(data.error);if(data.uncertain||/uncertain/i.test(data.error))uncertain.add(pending.id);}
    else{if(!pending.queueToken)clearSentDraft(pending.id,pending.message,pending.images);notice(type==='nativeSteer'?'Update accepted by Codex.':'Prompt sent.');request('refresh');}
    if(pending.queueToken){window.HUDFollowups.settle(queues,pending.id,pending.queueToken,!data.error);if(data.error)queuePaused.add(pending.id);}
    draftChanged();renderHeader();
    // Persist removal before allowing another queued delivery; a crash retains an uncertain head.
    if(supportsDrafts){queueSaving=true;beforeMutation(()=>{queueSaving=false;renderHeader();pumpQueue();},()=>{queueSaving=false;renderHeader();});}
  }else if(type==='previewFolderChanged'){if(data.id===selected&&previewMode)loadPreviews();
  }else if(type==='previews'){renderPreviews(data);
  }else if(type==='nativeApprovals'){if(typeof data.id==='string'){nativeApprovalStates.set(data.id,data);if(data.steerUncertain){uncertain.add(data.id);draftChanged();}if(data.id===selected){renderHeader();}}}
  else if(type==='nativeSteerReconcile'||type==='orcaReconcile'){const id=steerReconcileRequests.get(data.requestID);if(!id)return;steerReconcileRequests.delete(data.requestID);if(data.error)notice(data.error);else{uncertain.delete(id);draftChanged();notice('');}renderHeader();}
  else if(type==='nativeApprovalResponse'){const pending=nativeApprovalRequests.get(data.requestID);if(!pending)return;nativeApprovalRequests.delete(data.requestID);nativeApprovalsBusy.delete(pending.token);if(data.error)notice(data.error);renderNativeApprovals();}
  else if(type==='newCodexProgress'){$('new-codex-status').textContent=data.message||'Complete startup in Herdr.';}
  else if(type==='newCodexSession'){newCodexBusy=false;$('new-codex-start').disabled=false;$('new-codex-cancel').disabled=false;if(data.error){$('new-codex-status').textContent=data.error;}else if(data.cancelled){$('new-codex-status').textContent='Choose its project folder to start.';}else{$('new-codex-dialog').close();request('refresh');if(data.id)select(data.id);}}
  else if(type==='preferences'){orcaSupported=!!data.orcaModelsSupported;renderOrcaPicker();supportsNativeApprovals=!!data.nativeApprovalsSupported;$('new-codex').hidden=!supportsNativeApprovals;configureLocalFeatures(data);if(data.selectedAgent&&!selected)selected=data.selectedAgent;if(data.rosterWidth>=155)document.querySelector('aside').style.width=data.rosterWidth+'px';mode=data.mode||'chat';supportsAttachments=!!data.attachmentsSupported;supportsVideos=!!data.videoAttachmentsSupported;supportsPreviews=!!data.previewsSupported;supportsTerminalControls=!!data.terminalControlsSupported;$('previews-tab').hidden=!supportsPreviews;supportsShepherdr=!!data.shepherdrSupported;rosterMode=supportsShepherdr&&data.rosterMode==='shepherdr'?'shepherdr':'herdr';renderModes();if(rosterMode==='shepherdr')renderRoster();}
  else if(type==='quickPrompts'){quickPrompts=data.prompts;renderQuickPrompts();}
  else if(type==='loadDrafts'){restoreDrafts(data);}
  else if(type==='saveDrafts'){const pending=storageRequests.get(data.requestID);if(pending){storageRequests.delete(data.requestID);if(data.error)pending.reject(Error(data.error));else pending.resolve();}}
  else if(type==='notice'){notice(data.message);}
};
window.handleEscape=()=>{if($('new-codex-dialog').open){if(!newCodexBusy)$('new-codex-dialog').close();return;}if($('quick-editor').open){$('quick-editor').close();return;}if($('draft-recovery').open){$('draft-recovery').close();return;}if(attachmentPreview)closeAttachmentPreview();else request('close');};
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!event.isComposing){event.preventDefault();window.handleEscape();}});
$('refresh').onclick=()=>request('refresh');$('close').onclick=()=>request('close');$('hide').onclick=()=>request('hide');$('send').onclick=send;
$('reconcile').onclick=()=>{if(active()?.orca_managed){if([...steerReconcileRequests.values()].includes(selected))return;const requestID=request('orcaReconcile',{id:selected});steerReconcileRequests.set(requestID,selected);return;}if(nativeApprovalStates.get(selected)?.steerUncertain){if([...steerReconcileRequests.values()].includes(selected))return;const requestID=request('nativeSteerReconcile',{id:selected});steerReconcileRequests.set(requestID,selected);return;}uncertain.delete(selected);draftChanged();notice('');renderHeader();};
$('search').oninput=()=>{filter=$('search').value.toLowerCase();renderRoster();};
$('prompt').oninput=()=>{drafts.set(selected,$('prompt').value);draftChanged();renderHeader();};
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
function renderFileLinks(){
  const box=$('file-links'),items=outputs.get(selected)?.files||[];
  box.hidden=!items.length||!!outputs.get(selected)?.terminalControl;if(!items.length)return;
  const signature=JSON.stringify([selected,items]);if(box._signature===signature)return;box._signature=signature;
  box.replaceChildren(...items.map(item=>{const b=el('button',item.name);b.title=item.path;b.onclick=()=>request('openFileLink',{id:selected,token:item.token});return b;}));
}
function renderQuickPrompts(){
  $('quick-prompts').hidden=!supportsQuick;
  if(!supportsQuick)return;
  const target=$('quick-buttons'),signature=JSON.stringify([quickPrompts,!!active(),draftsLoaded]);
  if(target._signature!==signature){target._signature=signature;target.replaceChildren(...quickPrompts.map(item=>{const b=el('button',item.label);b.title=item.text;b.disabled=!active()||!draftsLoaded;b.onclick=()=>{const input=$('prompt');if(input.disabled)return;input.value+=(input.value.trim()?'\n\n':'')+item.text;input.oninput();input.focus();};return b;}));}
  $('recover-drafts').hidden=![...drafts.keys(),...attachments.keys(),...queues.keys()].some(id=>id!==selected&&((drafts.get(id)||'').length||imagesFor(id).length||queueFor(id).length));
}
function editQuickPrompts(){
  const list=$('quick-editor-rows');list.replaceChildren();
  for(const item of quickPrompts)addQuickRow(item);
  $('quick-editor').showModal();
}
function addQuickRow(item={label:'',text:''}){
  const list=$('quick-editor-rows');if(list.children.length>=6)return;
  const row=el('div',undefined,'quick-edit-row'),name=el('input'),body=el('textarea'),remove=el('button','Remove');
  name.value=item.label;name.maxLength=32;name.placeholder='Button name';name.setAttribute('aria-label','Quick prompt name');
  body.value=item.text;body.maxLength=2000;body.placeholder='Text to add to your draft';body.setAttribute('aria-label','Quick prompt text');remove.onclick=()=>row.remove();row.append(name,body,remove);list.append(row);
}
$('edit-quick').onclick=editQuickPrompts;$('quick-add').onclick=()=>addQuickRow();$('quick-cancel').onclick=()=>$('quick-editor').close();
$('quick-save').onclick=()=>{try{const rows=Array.from($('quick-editor-rows').children).map(row=>({label:row.children[0].value,text:row.children[1].value}));const prompts=window.HUDUtilities.prompts(rows);request('saveQuickPrompts',{prompts});$('quick-editor').close();}catch(error){notice(error.message);}};
$('jump-latest').onclick=()=>{lastOutput=outputs.get(selected)?.text||lastOutput;lastRendered='';queuedOutput.delete(selected);unread.delete(selected);renderOutput();renderHeader();renderRoster();badge();};
$('output').onscroll=()=>{if(atBottom()&&queuedOutput.has(selected))$('jump-latest').onclick();};
function draftState(){if(selected&&draftsLoaded)drafts.set(selected,$('prompt').value);return {drafts,attachments,queues,uncertain,keyUncertain:terminalKeyUncertain,labels:draftLabels,pendingPromptIDs:[...pendingDraftPrompt,...[...promptByRequest.values()].map(x=>x.id)],pendingKeyIDs:[...pendingDraftKeys,...[...terminalKeyRequests.values()].map(x=>x.id)]};}
function draftChanged(){if(selected)draftTouched.add(selected);draftPersistence?.changed(error=>{storageFailed=true;notice(error.message);renderHeader();});}
function beforeMutation(action,failed){
  if(!supportsDrafts){action();return;}
  if(!draftsLoaded||!draftPersistence){notice('Wait for saved drafts to restore before sending.');failed();return;}
  draftPersistence.flush().then(action).catch(error=>{storageFailed=true;notice(error.message);failed();renderHeader();});
}
function configureLocalFeatures(data){
  supportsQuick=!!data.quickPromptsSupported;if(data.quickPrompts)quickPrompts=data.quickPrompts;
  if(data.draftsSupported&&!supportsDrafts&&window.HUDDrafts){supportsDrafts=true;draftsLoaded=false;request('loadDrafts');renderHeader();}
}
function restoreDrafts(data){
  if(data.error){storageFailed=true;draftsLoaded=true;notice(data.error);renderHeader();return;}
  try{
    const state=window.HUDDrafts.mergeRestored(data.snapshot,draftState(),draftTouched);
    drafts=state.drafts;attachments=state.attachments;queues=state.queues||new Map();queuePaused=new Set([...queues.keys()]);uncertain=state.uncertain;terminalKeyUncertain=state.keyUncertain;draftLabels=state.labels;
    attachmentSequence=Math.max(0,...[...attachments.values(),...[...queues.values()].flat().map(x=>x.images)].flat().map(x=>x.key));draftsLoaded=true;
    $('prompt').value=drafts.get(selected)||'';
    draftPersistence=window.HUDDrafts.persistence({capture:()=>window.HUDDrafts.snapshot(draftState()),save:snapshot=>new Promise((resolve,reject)=>{const id=request('saveDrafts',{snapshot});storageRequests.set(id,{resolve,reject});})});
    draftPersistence.start();renderHeader();
  }catch(error){storageFailed=true;draftsLoaded=true;notice(error.message);renderHeader();}
}
window.flushDraftsForQuit=async()=>{if(!supportsDrafts)return true;if(!draftsLoaded||storageFailed||!draftPersistence)throw Error('Drafts could not be saved.');await draftPersistence.flush();return true;};
$('recover-drafts').onclick=()=>{
  const ids=[...new Set([...drafts.keys(),...attachments.keys()])].filter(id=>id!==selected&&((drafts.get(id)||'').length||imagesFor(id).length));
  $('recovered-list').replaceChildren(...ids.map(id=>{const row=el('div',undefined,'recovered-row');row.append(el('strong',draftLabels.get(id)||'Saved session'),el('p',(drafts.get(id)||'').slice(0,240)),el('small',`${imagesFor(id).length} files`));const copy=el('button','Copy into current draft');copy.disabled=!active()||!draftsLoaded;copy.onclick=()=>{
    if(imagesFor(selected).length+imagesFor(id).length>3){notice('Remove an attachment from the current draft first (3 maximum).');return;}
    const input=$('prompt'),text=input.value+(input.value.trim()?'\n\n':'')+(drafts.get(id)||''),images=[...imagesFor(selected),...imagesFor(id).map(x=>({...x,key:++attachmentSequence}))];
    try { const state=draftState(),nextDrafts=new Map(drafts),nextImages=new Map(attachments);nextDrafts.set(selected,text);nextImages.set(selected,images);window.HUDDrafts.snapshot({...state,drafts:nextDrafts,attachments:nextImages}); } catch(error){notice(error.message);return;}
    input.value=text;attachments.set(selected,images);if(uncertain.has(id))uncertain.add(selected);if(terminalKeyUncertain.has(id))terminalKeyUncertain.add(selected);input.oninput();$('draft-recovery').close();
  };const remove=el('button','Discard saved draft');remove.onclick=()=>{drafts.delete(id);attachments.delete(id);uncertain.delete(id);terminalKeyUncertain.delete(id);draftChanged();$('recover-drafts').onclick();};row.append(copy,remove);return row;}));
  for(const [id,items] of queues){if(id===selected)continue;for(const item of items){
    const row=el('div',undefined,'recovered-row');row.append(el('strong',(draftLabels.get(id)||'Saved session')+' · queued prompt'),el('p',item.text.slice(0,240)),el('small',`${item.images.length} files · ${item.status}`));
    const copy=el('button','Copy into current draft');copy.disabled=!active()||!draftsLoaded||item.status==='pending';copy.onclick=()=>{
      const text=$('prompt').value+($('prompt').value.trim()?'\n\n':'')+item.text,images=[...imagesFor(selected),...item.images.map(x=>({...x,key:++attachmentSequence}))];
      try{const state=draftState(),d=new Map(drafts),a=new Map(attachments);d.set(selected,text);a.set(selected,images);window.HUDDrafts.snapshot({...state,drafts:d,attachments:a});}catch(error){notice(error.message);return;}
      $('prompt').value=text;attachments.set(selected,images);if(item.status==='uncertain')uncertain.add(selected);$('prompt').oninput();$('draft-recovery').close();
    };
    const remove=el('button','Discard queued prompt');remove.disabled=item.status==='pending'||sending||queueSaving;remove.onclick=()=>{if(remove.disabled)return;window.HUDFollowups.remove(queues,id,item.token);draftChanged();$('recover-drafts').onclick();};row.append(copy,remove);$('recovered-list').append(row);
  }}
  if(!$('draft-recovery').open)$('draft-recovery').showModal();
};
$('recovery-close').onclick=()=>$('draft-recovery').close();

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
