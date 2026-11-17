const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;this.scrollTop=0;}append(...n){this.children.push(...n);}replaceChildren(...n){this.children=n;}setAttribute(){}focus(){this.focused=true;}querySelectorAll(){return [];}click(){if(!this.disabled)this.onclick?.();}}
function harness(){
 const nodes=new Map(),messages=[];
 const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(){}};
 const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}},HUDSuggestions:require('../Sources/HerdrHUD/Resources/suggestions.js')};
 const context=vm.createContext({window,document,HUDModel:require('../Sources/HerdrHUD/Resources/model.js'),setInterval(){},console});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8'),context);
 const evalCode=s=>vm.runInContext(s,context);
 evalCode("supportsTerminalControls=true;agents=[{id:'A',online:true,agent:'codex',agent_status:'blocked',input_kind:'permission',can_prompt:false}];selected='A';opened=true;outputs.set('A',{text:'approval',terminalControl:{token:'token',text:'Live <script>plain text</script>',uncertain:false}});renderHeader()");
 return {messages,window,eval:evalCode,$:id=>document.getElementById(id)};
}
test('chat heading displays the active model and clears it on session change',()=>{
 const h=harness();
 h.window.receive({type:'output',data:{id:'A',provider:'codex',screenComplete:true,text:'• Recent reply\n› Ask Codex anything\n  GPT-6.2-Astra medium · ~/repo'}});
 assert.match(h.$('identity').textContent,/GPT-6\.2-Astra · medium$/);
 h.eval("agents.push({id:'B',online:true,agent:'claude',agent_status:'idle',reported_model:'claude-opus-4-8'});select('B')");
 assert.match(h.$('identity').textContent,/claude-opus-4-8$/);
 assert.doesNotMatch(h.$('identity').textContent,/Astra|medium/);
});
test('manual key shows exact text, sends one fixed key, locks and refreshes without repeating stale errors',()=>{
 const h=harness();assert.equal(h.$('terminal-controls').hidden,false);assert.equal(h.$('terminal-screen').children[0].textContent,'Live <script>plain text</script>');assert.equal(h.$('send').disabled,true);
 h.$('terminal-down').click();h.$('terminal-enter').click();let keys=h.messages.filter(m=>m.op==='terminalKey');assert.equal(keys.length,1);assert.equal(keys[0].key,'down');assert.equal(keys[0].token,'token');
 h.window.receive({type:'terminalKey',data:{requestID:keys[0].requestID,id:'A',error:'Terminal question changed. Refresh and review.'}});
 assert.equal(h.$('terminal-controls').hidden,true);assert.equal(h.messages.filter(m=>m.op==='terminalKey').length,1);assert.equal(h.messages.some(m=>m.op==='refresh'),true);assert.equal(h.messages.some(m=>m.op==='output'),true);
});
test('uncertain key disables subsequent controls until explicit reconciliation; responses remain agent bound',()=>{
 const h=harness();h.$('terminal-enter').click();const sent=h.messages.find(m=>m.op==='terminalKey');
 h.window.receive({type:'terminalKey',data:{requestID:sent.requestID,id:'A',error:'Key delivery uncertain'}});
 h.window.receive({type:'output',data:{id:'A',text:'still blocked',terminalControl:{token:'next',text:'Current screen',uncertain:true}}});
 assert.equal(h.$('terminal-enter').disabled,true);assert.equal(h.$('terminal-key-reconcile').hidden,false);h.$('terminal-enter').click();assert.equal(h.messages.filter(m=>m.op==='terminalKey').length,1);
 h.$('terminal-key-reconcile').click();const reconcile=h.messages.find(m=>m.op==='reconcileTerminalKeys');assert.equal(reconcile.id,'A');
 h.window.receive({type:'reconcileTerminalKeys',data:{id:'A',requestID:reconcile.requestID,ok:true}});assert.equal(h.$('terminal-controls').hidden,true);assert.equal(h.messages.filter(m=>m.op==='terminalKey').length,1);
});
test('unknown status kind, ordinary numbered output and unsupported hosts cannot offer controls',()=>{
 const h=harness();for(const change of ["agents[0].input_kind=''","agents[0].input_kind='permission';agents[0].agent_status='idle'","agents[0].agent_status='blocked';supportsTerminalControls=false"]){h.eval(change+';renderHeader()');assert.equal(h.$('terminal-controls').hidden,true);h.eval("terminalKey('enter')");}
 assert.equal(h.messages.some(m=>m.op==='terminalKey'),false);
});
test('suggested reply fills and retains existing draft, never sends',()=>{
 const h=harness();h.eval("agents[0].agent_status='idle';agents[0].can_prompt=true;outputs.set('A',{text:'• Would you like me to add a search box?'});renderHeader()");
 assert.equal(h.$('suggested-replies').hidden,false);h.$('prompt').value='Please keep current colors.';h.$('suggested-replies').children[0].click();
 assert.match(h.$('prompt').value,/^Please keep current colors\.\n\n/);assert.match(h.$('prompt').value,/search box/);assert.equal(h.$('prompt').focused,true);assert.equal(h.messages.some(m=>m.op==='prompt'||m.op==='terminalKey'),false);
});

test('verified terminal preview occupies conversation once; ordinary views restore when unavailable',()=>{
 const h=harness();assert.equal(h.$('output').hidden,true);assert.equal(h.$('previews').hidden,true);assert.equal(h.$('terminal-controls').hidden,false);
 h.eval("agents[0].agent_status='idle';renderHeader()");assert.equal(h.$('terminal-controls').hidden,true);assert.equal(h.$('output').hidden,false);assert.equal(h.$('previews').hidden,true);
 h.eval("previewMode=true;renderHeader()");assert.equal(h.$('output').hidden,true);assert.equal(h.$('previews').hidden,false);
});

test('prefixed live screen formats active approval and preserves exact full context without polling scroll jumps',()=>{
 const h=harness(),raw='• Earlier transcript\n\nField 1/1\nAllow Computer Use to use "Demo"?\nApp: Demo\n› 1. Allow    Run the tool\n  2. Allow for this session    Until session ends\n  3. Always allow    Future requests\n  4. Cancel    Stop\nenter to submit | esc to cancel';
 h.window.receive({type:'output',data:{id:'A',text:raw,terminalControl:{token:'new',text:raw,uncertain:false}}});
 const screen=h.$('terminal-screen');assert.equal(screen.children[0].className,'block approval');assert.equal(screen.children[1].children[0].textContent,'Full terminal screen');assert.equal(screen.children[1].children[1].textContent,raw);
 screen.scrollTop=85;const card=screen.children[0];h.eval('renderTerminalControls()');assert.equal(screen.children[0],card);assert.equal(screen.scrollTop,85);
});

test('model picker holds prompts per session and uses the observed session-only key',()=>{
 const h=harness();h.eval("agents[0].agent_status='idle';agents[0].can_prompt=true;agents[0].machine_id='local';outputs.set('A',{text:'ready',modelPicker:{ready:true,pending:false,uncertain:false}});renderHeader()");
 h.$('prompt').value='Keep this draft';h.$('model-toggle').click();const open=h.messages.find(m=>m.op==='openModelPicker');assert.equal(open.id,'A');assert.equal(h.$('prompt').disabled,true);assert.equal(h.$('prompt').value,'Keep this draft');
 h.window.receive({type:'openModelPicker',data:{id:'A',requestID:open.requestID}});const read=h.messages.filter(m=>m.op==='output').at(-1);h.window.receive({type:'output',data:{id:'A',requestID:read.requestID,text:'menu',modelPicker:{ready:false,pending:false,uncertain:false,menu:{heading:'Models',text:'Sonnet',applyKey:'s',token:'observed'}}}});
 h.$('model-apply').click();const key=h.messages.find(m=>m.op==='modelPickerKey');assert.equal(key.key,'s');assert.equal(key.token,'observed');assert.equal(h.$('send').disabled,true);
 h.eval("agents.push({id:'B',online:true,agent:'claude',machine_id:'local',agent_status:'idle'});select('B')");assert.equal(h.eval("modelHeld('A')"),true);assert.equal(h.eval("modelHeld('B')"),false);
});
test('uncertain model key requires explicit reconciliation and missing apply key cannot send',()=>{
 const h=harness();h.eval("agents[0].agent_status='idle';agents[0].machine_id='local';outputs.set('A',{text:'menu',modelPicker:{ready:false,pending:false,uncertain:false,menu:{heading:'Models',text:'More',token:'t'}}});renderHeader()");
 assert.equal(h.$('model-apply').disabled,true);h.$('model-down').click();const key=h.messages.find(m=>m.op==='modelPickerKey');h.window.receive({type:'modelPickerKey',data:{id:'A',requestID:key.requestID,uncertain:true,error:'Uncertain'}});
 assert.equal(h.$('model-reconcile').hidden,false);assert.equal(h.eval("modelHeld('A')"),true);
 const read=h.messages.filter(m=>m.op==='output').at(-1);
 h.window.receive({type:'output',data:{id:'A',requestID:read.requestID,text:'Awaiting manual check',modelPicker:{ready:false,pending:true,uncertain:true}}});
 assert.equal(h.$('model-reconcile').disabled,false);h.$('model-reconcile').click();
 assert.equal(h.messages.find(m=>m.op==='reconcileModelPicker')?.id,'A');
});
