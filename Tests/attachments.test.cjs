const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8');
class Node{constructor(){this.children=[];this.value='';this.style={};this.disabled=false;this.listeners={};this.selectionStart=0;this.selectionEnd=0;}append(...n){this.children.push(...n);}replaceChildren(...n){this.children=n;}setAttribute(){}focus(){this.focused=true;}showModal(){this.open=true;}close(){this.open=false;}querySelectorAll(){return [];}click(){this.onclick?.();}addEventListener(t,fn){this.listeners[t]=fn;}setRangeText(text,start,end){this.value=this.value.slice(0,start)+text+this.value.slice(end);this.selectionStart=this.selectionEnd=start+text.length;}}
function harness(){
 const nodes=new Map(),messages=[],listeners={},reads=[];
 const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},createElement:()=>new Node(),createTextNode:text=>({textContent:text}),addEventListener(t,fn){listeners[t]=fn;}};
 const window={HUDDrafts:require('../Sources/HerdrHUD/Resources/drafts.js'),webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}}};
 class FileReader{readAsDataURL(file){reads.push(()=>{this.result='data:image/png;base64,YWJj';this.onload();});}}
 class Image{set src(v){this.naturalWidth=4;this.naturalHeight=4;this.onload();}}
 const HUDModel=require('../Sources/HerdrHUD/Resources/model.js');
 const context=vm.createContext({window,document,FileReader,Image,TextEncoder,TextDecoder,HUDModel,setInterval(){},setTimeout,clearTimeout,console});vm.runInContext(source,context);
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

const video={kind:'video',token:'12345678-1234-1234-1234-123456789abc',name:'clip.mp4',bytes:30,poster:'data:image/jpeg;base64,/9j/2Q==',duration:1,width:64,height:64};
test('native MP4 paste/drop offer stages a preview token and sends no path until Send',async()=>{
 const h=harness();h.eval('supportsVideos=true');h.context.window.receive({type:'videoOffer',data:{id:'A',offer:'opaque',count:1}});
 const imported=h.messages.find(m=>m.op==='videoImport');assert.ok(imported);assert.equal(h.$('send').disabled,true);
 h.context.window.receive({type:'videoImport',data:{requestID:imported.requestID,id:'A',attachments:[video]}});await tick();
 assert.equal(h.eval("imagesFor('A')[0].kind"),'video');assert.equal(h.$('prompt').value,'');h.$('attachments').children[0].children[0].click();assert.equal(h.messages.at(-1).op,'openVideo');assert.equal(h.messages.at(-1).attachment.token,video.token);
 assert.equal(h.messages.some(m=>m.op==='prompt'),false);h.eval('send()');const sent=h.messages.find(m=>m.op==='prompt');assert.equal(sent.attachments[0].token,video.token);assert.equal(sent.attachments[0].data,undefined);
});
test('MP4 clipboard files suppress path text and request bounded native import',async()=>{
 const h=harness();h.eval('supportsVideos=true');let prevented=false;
 const file={name:'clip.mp4',type:'video/mp4',size:30,slice(){return this;}};
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'file',type:'video/mp4',getAsFile:()=>file}],files:[file],getData:()=>'/private/example/clip.mp4'}});
 assert.equal(prevented,true);assert.equal(h.$('prompt').value,'');const started=h.messages.find(m=>m.op==='videoBegin');assert.ok(started);assert.equal(h.messages.filter(m=>m.op==='videoBegin').length,1);
 h.context.window.receive({type:'videoBegin',data:{requestID:started.requestID,error:'fixture refusal'}});await tick();assert.equal(h.eval("attachmentLoads.get('A')"),0);assert.equal(h.messages.some(m=>m.op==='prompt'),false);
});

test('Markdown drop stages exact UTF-8 contents with safe preview and captured identity',async()=>{
 const h=harness();h.eval("supportsMarkdown=true");const text='# Notes\n<script>alert(1)</script>\nCafé';const bytes=new TextEncoder().encode(text);let finish;
 const file={name:'notes.md',type:'text/markdown',size:bytes.length,arrayBuffer:()=>new Promise(resolve=>{finish=()=>resolve(bytes.buffer);})};let prevented=false;
 h.listeners.drop({preventDefault(){prevented=true;},dataTransfer:{types:['Files'],files:[file]}});
 assert.equal(prevented,true);h.eval("selected='B'");finish();await tick();
 assert.equal(h.eval("imagesFor('A')[0].text"),text);assert.equal(h.eval("imagesFor('B').length"),0);
 h.eval("selected='A';renderHeader()");h.$('attachments').children[0].children[0].click();
 assert.equal(h.$('attachment-preview-text').textContent,text);assert.equal(h.$('attachment-preview-image').hidden,true);
 assert.equal(h.$('prompt').value,'');assert.equal(h.messages.some(m=>m.op==='prompt'),false);
});
test('Markdown rejects oversized and non-UTF8 files without staging',async()=>{
 const h=harness();h.eval("supportsMarkdown=true");
 await h.context.window;h.eval("stageMarkdown([{name:'big.md',size:16385}])");assert.equal(h.eval("imagesFor('A').length"),0);
 h.context.bad={name:'bad.md',size:1,arrayBuffer:async()=>new Uint8Array([255]).buffer};await h.eval('stageMarkdown([bad])');
 assert.equal(h.eval("imagesFor('A').length"),0);assert.equal(h.eval("attachmentLoads.get('A')"),0);
});
