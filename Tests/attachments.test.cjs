const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8');
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;}append(...n){this.children.push(...n);}replaceChildren(...n){this.children=n;}setAttribute(){}querySelectorAll(){return [];}click(){this.onclick?.();}}
function harness(){
 const nodes=new Map(),messages=[],listeners={},reads=[];
 const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(t,fn){listeners[t]=fn;}};
 const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}}};
 class FileReader{readAsDataURL(file){reads.push(()=>{this.result='data:image/png;base64,YWJj';this.onload();});}}
 class Image{set src(v){this.naturalWidth=4;this.naturalHeight=4;this.onload();}}
 const context=vm.createContext({window,document,FileReader,Image,setInterval(){},console});vm.runInContext(source,context);
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
