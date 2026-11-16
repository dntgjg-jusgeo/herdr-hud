const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const M=require('../Sources/HerdrHUD/Resources/orca-models.js');
const models=[{id:'deepseek/new',name:'DeepSeek New',releaseDate:'2026-10-17',contextLength:1000000,tools:true},{id:'qwen/new',name:'Qwen New',releaseDate:'2026-09-02'}];
test('search and details use supplied verified metadata without inventing capabilities',()=>{assert.equal(M.search(models,'QWEN')[0].id,'qwen/new');assert.match(M.detail(models[0]),/2026-10-17/);assert.match(M.detail(models[0]),/Tool support reported/);assert.doesNotMatch(M.detail(models[1]),/tool support/i);});
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;this.hidden=false;}append(...x){this.children.push(...x);}replaceChildren(...x){this.children=x;}setAttribute(k,v){this[k]=v;}querySelectorAll(){return [];}click(){if(!this.disabled)this.onclick?.();}}
function harness(){const nodes=new Map(),messages=[];const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(){}};const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}},HUDOrcaModels:M};const context=vm.createContext({window,document,HUDModel:require('../Sources/HerdrHUD/Resources/model.js'),setInterval(){},console});vm.runInContext(fs.readFileSync('Sources/HerdrHUD/Resources/app.js','utf8'),context);return{window,messages,$:id=>document.getElementById(id)};}
test('picker fetches only when opened, preserves composer, and selection never launches',()=>{
 const h=harness();h.window.receive({type:'roster',data:{agents:[{id:'orca',agent:'opencode',orca_managed:true,online:true,agent_status:'idle'}],machines:[]}});h.$('prompt').value='Keep my draft';h.window.receive({type:'preferences',data:{orcaModelsSupported:true}});assert.equal(h.messages.some(x=>x.op==='orcaModels'),false);h.window.receive({type:'openOrcaModels',data:{}});const req=h.messages.find(x=>x.op==='orcaModels');assert.ok(req);
 h.window.receive({type:'orcaModels',data:{requestID:req.requestID,models,cutoffDate:'2026-07-16'}});assert.equal(h.$('orca-select').children.length,3);h.$('orca-select').value='qwen/new';h.$('orca-select').onchange();assert.equal(h.messages.some(x=>x.op==='orcaLaunch'),false);assert.equal(h.$('prompt').value,'Keep my draft');
 h.$('orca-launch').click();h.$('orca-launch').click();assert.equal(h.messages.filter(x=>x.op==='orcaLaunch').length,1);assert.equal(h.messages.at(-1).model,'qwen/new');h.$('orca-close').click();assert.equal(h.$('orca-panel').hidden,true);
});
test('stale catalog responses and filtered-away selections cannot launch',()=>{
 const h=harness();h.window.receive({type:'preferences',data:{orcaModelsSupported:true}});h.window.receive({type:'openOrcaModels',data:{}});const req=h.messages.find(x=>x.op==='orcaModels');h.window.receive({type:'orcaModels',data:{requestID:'old',models}});assert.equal(h.$('orca-launch').disabled,true);
 h.window.receive({type:'orcaModels',data:{requestID:req.requestID,models,cutoffDate:'2026-07-16'}});h.$('orca-select').value='deepseek/new';h.$('orca-select').onchange();h.$('orca-search').value='qwen';h.$('orca-search').oninput();assert.equal(h.$('orca-launch').disabled,true);assert.equal(h.$('orca-select').children.length,2);
});

test('Orca controls follow only managed OpenCode selection and ignore late catalog replies',()=>{
 const h=harness();h.window.receive({type:'preferences',data:{orcaModelsSupported:true}});
 h.window.receive({type:'roster',data:{agents:[{id:'codex',agent:'codex',online:true,agent_status:'idle'},{id:'claude',agent:'claude',online:true,agent_status:'idle'},{id:'orca',agent:'opencode',orca_managed:true,online:true,agent_status:'idle'},{id:'other',agent:'opencode',online:true,agent_status:'unknown'}],machines:[]}});
 assert.equal(h.$('orca-toggle').hidden,true);h.window.receive({type:'select',data:{id:'orca'}});assert.equal(h.$('orca-toggle').hidden,false);h.$('orca-toggle').click();const req=h.messages.find(x=>x.op==='orcaModels');assert.equal(h.$('orca-panel').hidden,false);
 for(const id of ['codex','claude','other']){h.window.receive({type:'select',data:{id}});assert.equal(h.$('orca-toggle').hidden,true);assert.equal(h.$('orca-panel').hidden,true);}
 h.window.receive({type:'orcaModels',data:{requestID:req.requestID,models}});assert.equal(h.$('orca-panel').hidden,true);
 h.window.receive({type:'openOrcaModels',data:{}});assert.equal(h.$('orca-toggle').hidden,false);assert.equal(h.$('orca-panel').hidden,false);
});
