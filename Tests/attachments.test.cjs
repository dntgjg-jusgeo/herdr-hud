const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8');
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;this.listeners={};this.selectionStart=0;this.selectionEnd=0;}append(...n){this.children.push(...n);}replaceChildren(...n){this.children=n;}setAttribute(){}focus(){this.focused=true;}showModal(){this.open=true;}close(){this.open=false;}querySelectorAll(){return [];}click(){this.onclick?.();}addEventListener(t,fn){this.listeners[t]=fn;}setRangeText(text,start,end){this.value=this.value.slice(0,start)+text+this.value.slice(end);this.selectionStart=this.selectionEnd=start+text.length;}}
function harness(){
 const nodes=new Map(),messages=[],listeners={},reads=[];
 const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(t,fn){listeners[t]=fn;}};
 const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}}};
 class FileReader{readAsDataURL(file){reads.push(()=>{this.result='data:image/png;base64,YWJj';this.onload();});}}
 class Image{set src(v){this.naturalWidth=4;this.naturalHeight=4;this.onload();}}
 const HUDModel=require('../Sources/HerdrHUD/Resources/model.js');
 const context=vm.createContext({window,document,FileReader,Image,HUDModel,setInterval(){},console});vm.runInContext(source,context);
 vm.runInContext("supportsAttachments=true;agents=[{id:'A',online:true,can_attach:true,agent_status:'idle',agent:'codex'},{id:'B',online:true,can_attach:true,agent_status:'idle',agent:'claude'}];selected='A'",context);
 return {context,messages,reads,listeners,$:id=>document.getElementById(id),eval:s=>vm.runInContext(s,context)};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('real drop handler prevents default, stages captured draft and never uploads',async()=>{
 const h=harness();let prevented=false;
 h.listeners.drop({preventDefault(){prevented=true;},dataTransfer:{types:['Files'],files:[{type:'image/png',name:'/fakepath/screenshot.png',size:3}]}});
 assert.equal(prevented,true);assert.equal(h.$('send').disabled,true);
 h.eval("selected='B'");h.reads[0]();await tick();
 assert.equal(h.eval("imagesFor('A').length"),1);assert.equal(h.eval("imagesFor('B').length"),0);
 h.eval("selected='A';renderHeader()");assert.equal(h.$('attachments').children[0].children[1].textContent,'screenshot.png');
 assert.equal(h.$('prompt').value,'');assert.equal(h.messages.filter(m=>m.op==='prompt').length,0);
 h.$('attachments').children[0].children[2].click();assert.equal(h.eval("imagesFor('A').length"),0);
});
test('send includes bytes once, successful receipt clears only submitted images; failure preserves and blocks',async()=>{
 const h=harness();h.eval("stageImages([{type:'image/png',name:'image.png',size:3}])");h.reads[0]();await tick();
 h.eval('send()');const request=h.messages.find(m=>m.op==='prompt');assert.equal(request.attachments[0].data,'YWJj');assert.equal(request.message,'');
 h.window=h.context.window;h.window.receive({type:'prompt',data:{requestID:request.requestID,error:'delivery uncertain'}});
 assert.equal(h.eval("imagesFor('A').length"),1);assert.equal(h.$('send').disabled,true);
 h.eval("uncertain.clear();renderHeader();send()");const retry=h.messages.filter(m=>m.op==='prompt').at(-1);
 h.window.receive({type:'prompt',data:{requestID:retry.requestID,ok:true}});assert.equal(h.eval("imagesFor('A').length"),0);
});
test('unsupported drop cannot insert paths, and malformed/oversize files never read',()=>{
 const h=harness();h.eval('supportsAttachments=false');let prevented=false;
 h.listeners.drop({preventDefault(){prevented=true;},dataTransfer:{types:['Files'],files:[{type:'image/png',size:3,name:'image.png'}]}});assert.equal(prevented,true);assert.equal(h.reads.length,0);
 h.eval("supportsAttachments=true;stageImages([{type:'image/svg+xml',size:3,name:'unsafe.svg'}]);stageImages([{type:'image/png',size:5000000,name:'large.png'}])");assert.equal(h.reads.length,0);
});
test('paste stages an item image once, preserves mixed text, and waits for Send',async()=>{
 const h=harness(),file={type:'image/png',name:'screenshot.png',size:3};let prevented=false;
 h.$('prompt').value='before after';h.$('prompt').selectionStart=7;h.$('prompt').selectionEnd=7;
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'file',type:file.type,getAsFile:()=>file}],files:[file],getData:()=> 'text '}});
 assert.equal(prevented,true);assert.equal(h.$('prompt').value,'before text after');assert.equal(h.eval("drafts.get('A')"),'before text after');assert.equal(h.reads.length,1);
 h.reads[0]();await tick();assert.equal(h.eval("imagesFor('A').length"),1);assert.equal(h.messages.filter(m=>m.op==='prompt').length,0);
});
test('text paste remains native; file fallback handles images including unsupported types',async()=>{
 const h=harness();let prevented=false;
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'string',type:'text/plain'}],files:[]}});assert.equal(prevented,false);assert.equal(h.reads.length,0);
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[],files:[{type:'image/png',name:'paste.png',size:3}],getData:()=>''}});assert.equal(prevented,true);assert.equal(h.reads.length,1);
 h.reads[0]();await tick();assert.equal(h.eval("imagesFor('A').length"),1);
 prevented=false;h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[],files:[{type:'image/tiff',name:'paste.tiff',size:3}],getData:()=>''}});assert.equal(prevented,true);assert.equal(h.reads.length,1);
});

test('attachment preview opens and closes without sending or changing the draft',async()=>{
 const h=harness();h.$('prompt').value='keep this draft';h.$('prompt').oninput();
 h.eval("stageImages([{type:'image/png',name:'image.png',size:3}])");h.reads[0]();await tick();
 const chip=h.$('attachments').children[0];chip.children[0].click();
 assert.equal(h.$('attachment-preview').open,true);assert.equal(h.$('attachment-preview-name').textContent,'image.png');
 assert.equal(h.$('attachment-preview-image').src,'data:image/png;base64,YWJj');
 h.eval('renderHeader()');const current=h.$('attachments').children[0].children[0];
 let prevented=false;h.listeners.keydown({key:'Escape',isComposing:false,preventDefault(){prevented=true;}});assert.equal(prevented,true);assert.equal(h.$('attachment-preview').open,false);assert.equal(current.focused,true);
 assert.equal(h.$('prompt').value,'keep this draft');assert.equal(h.eval("imagesFor('A').length"),1);
 assert.equal(h.messages.filter(m=>m.op==='prompt'||m.op==='close').length,0);
 current.click();h.$('attachment-preview-close').click();assert.equal(h.$('attachment-preview').open,false);
 current.click();h.eval("select('B')");assert.equal(h.$('attachment-preview').open,false);assert.equal(h.eval("imagesFor('A').length"),1);
 h.context.window.handleEscape();assert.equal(h.messages.filter(m=>m.op==='close').length,1);
});
