const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;this.scrollTop=0;this.scrollHeight=500;this.clientHeight=500;}append(...x){this.children.push(...x);}replaceChildren(...x){this.children=x;}setAttribute(){}querySelectorAll(){return [];}focus(){}click(){if(!this.disabled)this.onclick?.();}}
function harness(){
 const nodes=new Map(),messages=[];const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(){}};
 const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}},HUDUtilities:require('../Sources/HerdrHUD/Resources/utilities.js'),HUDDrafts:require('../Sources/HerdrHUD/Resources/drafts.js')};
 const context=vm.createContext({window,document,HUDModel:require('../Sources/HerdrHUD/Resources/model.js'),TextEncoder,atob,setTimeout:()=>1,clearTimeout(){},setInterval(){},console});
 vm.runInContext(fs.readFileSync('Sources/HerdrHUD/Resources/app.js','utf8'),context);
 const run=s=>vm.runInContext(s,context);run("agents=[{id:'A',online:true,agent:'codex',agent_status:'idle',can_prompt:true}];selected='A';opened=true;renderHeader()");return {window,messages,run,$:id=>document.getElementById(id)};
}
const tick=()=>new Promise(r=>setImmediate(r));
test('restores text under exact identity and saves pending intent before sending',async()=>{
 const h=harness();h.window.receive({type:'preferences',data:{draftsSupported:true}});assert.equal(h.$('prompt').disabled,true);
 h.window.receive({type:'loadDrafts',data:{snapshot:{version:1,drafts:[{id:'A',label:'Original',text:'Keep me',images:[],uncertain:false,keyUncertain:false},{id:'OLD',label:'Replaced',text:'Separate',images:[],uncertain:true,keyUncertain:false}]}}});
 assert.equal(h.$('prompt').value,'Keep me');assert.equal(h.run("drafts.get('OLD')"),'Separate');assert.equal(h.run("uncertain.has('OLD')"),true);
 h.run('send()');await tick();assert.equal(h.messages.some(x=>x.op==='prompt'),false);
 const save=h.messages.find(x=>x.op==='saveDrafts');assert.equal(save.snapshot.drafts.find(x=>x.id==='A').uncertain,true);
 h.window.receive({type:'saveDrafts',data:{requestID:save.requestID,ok:true}});await tick();assert.equal(h.messages.filter(x=>x.op==='prompt').length,1);
 h.run('draftPersistence.stop()');
});
test('save failure prevents delivery and retains draft',async()=>{
 const h=harness();h.window.receive({type:'preferences',data:{draftsSupported:true}});h.window.receive({type:'loadDrafts',data:{snapshot:{version:1,drafts:[]}}});h.$('prompt').value='Never lose this';h.$('prompt').oninput();h.run('send()');await tick();const save=h.messages.find(x=>x.op==='saveDrafts');h.window.receive({type:'saveDrafts',data:{requestID:save.requestID,error:'Disk unavailable'}});await tick();assert.equal(h.messages.some(x=>x.op==='prompt'),false);assert.equal(h.$('prompt').value,'Never lose this');assert.equal(h.$('send').disabled,true);h.run('draftPersistence.stop()');
});
test('new output is queued above reader position until explicit jump',()=>{
 const h=harness();h.window.receive({type:'output',data:{id:'A',text:'• Old reply'}});h.$('output').scrollHeight=1000;h.$('output').clientHeight=300;h.$('output').scrollTop=50;const previous=h.$('output').children[0];h.window.receive({type:'output',data:{id:'A',text:'• New reply'}});assert.equal(h.$('output').children[0],previous);assert.equal(h.$('jump-latest').hidden,false);h.$('jump-latest').click();assert.equal(h.run('lastOutput'),'• New reply');assert.equal(h.$('jump-latest').hidden,true);
});
test('quick prompt buttons append text and never submit',()=>{
 const h=harness();h.window.receive({type:'preferences',data:{quickPromptsSupported:true,quickPrompts:[{label:'Tests',text:'Run relevant tests.'}]}});h.run('renderHeader()');h.$('prompt').value='Keep notes.';h.$('quick-buttons').children[0].click();assert.equal(h.$('prompt').value,'Keep notes.\n\nRun relevant tests.');assert.equal(h.messages.some(x=>x.op==='prompt'),false);
});
test('guarded buttons identify literal digits and never append Enter or fall back',()=>{
 const h=harness();h.run("supportsTerminalControls=true;agents[0].agent_status='blocked';agents[0].input_kind='permission';outputs.set('A',{terminalControl:{token:'manual',text:'question',choiceToken:'guarded',choices:[{key:'2',label:'Allow for this session'}]}});renderTerminalControls()");
 const button=h.$('approval-choices').children[0];assert.equal(button.textContent,'Send 2');assert.match(h.$('terminal-hint').textContent,/keybindings/);button.click();button.click();
 const sent=h.messages.filter(x=>x.op==='approvalChoice');assert.equal(sent.length,1);assert.equal(sent[0].key,'2');assert.equal(sent[0].token,'guarded');
 h.window.receive({type:'approvalChoice',data:{requestID:sent[0].requestID,error:'Key delivery uncertain'}});
 assert.equal(h.run("terminalKeyUncertain.has('A')"),true);assert.equal(h.messages.some(x=>x.op==='terminalKey'),false);
});
test('semantic approval sends exact opaque token and decision without keys or prompts',()=>{
 const h=harness();h.run("supportsNativeApprovals=true;supportsTerminalControls=true;agents[0].agent_status='blocked';agents[0].input_kind='permission';outputs.set('A',{terminalControl:{token:'manual',text:'menu'}})");
 h.window.receive({type:'nativeApprovals',data:{id:'A',linked:true,connected:true,threadId:'native-thread-123',cards:[{token:'opaque-request',question:'Allow Computer Use?',detail:'App: Demo',choices:[{key:'allow-once',label:'Allow'},{key:'cancel',label:'Cancel'}]}]}});
 assert.match(h.$('native-approval-context').textContent,/native-thread-123/);assert.equal(h.$('terminal-controls').hidden,true);
 const actions=h.$('native-approval-cards').children[0].children[2];actions.children[0].click();actions.children[0].click();
 const sent=h.messages.filter(x=>x.op==='nativeApprovalResponse');assert.equal(sent.length,1);assert.equal(sent[0].token,'opaque-request');assert.equal(sent[0].choice,'allow-once');
 assert.equal(h.messages.some(x=>['terminalKey','approvalChoice','prompt'].includes(x.op)),false);
 h.window.receive({type:'nativeApprovals',data:{id:'A',linked:true,connected:false,threadId:'native-thread-123',cards:[],status:'Disconnected'}});h.run("sendNativeApproval('opaque-request','cancel')");assert.equal(h.messages.filter(x=>x.op==='nativeApprovalResponse').length,1);
});
test('resolved native approval cannot use a previously rendered button',()=>{
 const h=harness();h.run("supportsNativeApprovals=true");
 h.window.receive({type:'nativeApprovals',data:{id:'A',linked:true,connected:true,threadId:'thread',cards:[{token:'gone',question:'Permission',choices:[{key:'accept',label:'Allow'}]}]}});
 const old=h.$('native-approval-cards').children[0].children[1].children[0];
 h.window.receive({type:'nativeApprovals',data:{id:'A',linked:true,connected:true,threadId:'thread',cards:[]}});old.click();assert.equal(h.messages.some(x=>x.op==='nativeApprovalResponse'),false);
});
