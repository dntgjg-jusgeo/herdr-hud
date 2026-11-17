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
 vm.runInContext("supportsNativeFiles=true;supportsAttachments=true;agents=[{id:'A',online:true,can_attach:true,agent_status:'idle',agent:'codex'},{id:'B',online:true,can_attach:true,agent_status:'idle',agent:'claude'}];selected='A'",context);
 return {context,messages,reads,listeners,$:id=>document.getElementById(id),eval:s=>vm.runInContext(s,context)};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));

const token='01234567-89ab-cdef-0123-456789abcdef';
const file=(name,type,size=30)=>({name,type,size,slice(start,end){return {size:end-start};}});
const ref=(kind,name,bytes=30)=>({kind,token,name,bytes,...(kind==='pdf'?{pages:2}:{})});
function receive(h,type,data){h.context.window.receive({type,data});}
async function completeNative(h,item){
 const begin=h.messages.filter(m=>m.op==='fileBegin').at(-1);assert.ok(begin);
 receive(h,'fileBegin',{requestID:begin.requestID,token});await tick();
 assert.equal(h.reads.length,1);h.reads[0]();await tick();
 const chunk=h.messages.find(m=>m.op==='fileChunk');assert.ok(chunk);assert.equal(chunk.offset,0);
 receive(h,'fileChunk',{requestID:chunk.requestID,ok:true});await tick();
 const finish=h.messages.find(m=>m.op==='fileFinish');assert.ok(finish);
 receive(h,'fileFinish',{requestID:finish.requestID,attachment:item});await tick();
}
test('drop streams to native without decoding image, binds completion to captured draft',async()=>{
 const h=harness();let prevented=false;
 h.listeners.drop({preventDefault(){prevented=true;},dataTransfer:{types:['Files'],files:[file('screenshot.png','image/png',6*1024*1024)]}});
 assert.equal(prevented,true);assert.equal(h.$('send').disabled,true);assert.equal(h.reads.length,0);
 // Refuse the synthetic large upload; large import boundaries/real decoding are native-tested.
 const begin=h.messages.find(m=>m.op==='fileBegin');assert.equal(begin.bytes,6*1024*1024);
 receive(h,'fileBegin',{requestID:begin.requestID,error:'controlled refusal'});await tick();
 assert.equal(h.eval("attachmentLoads.get('A')"),0);assert.equal(h.messages.some(m=>m.op==='prompt'),false);
 const h2=harness();h2.eval("stageImages([fixture])".replace('fixture',JSON.stringify({name:'screenshot.png',type:'image/png',size:30}))); // staged test file has no browser read until native accepts
 const request=h2.messages.find(m=>m.op==='fileBegin');h2.eval("selected='B'");receive(h2,'fileBegin',{requestID:request.requestID,error:'controlled refusal'});await tick();
 assert.equal(h2.eval("imagesFor('B').length"),0);
});
test('image sends opaque original once and uncertain receipt preserves draft',async()=>{
 const h=harness();h.context.fixture=file('image.png','image/png');h.eval('stageImages([fixture])');await completeNative(h,ref('raster','image.png'));
 h.eval('send()');const request=h.messages.find(m=>m.op==='prompt');assert.equal(request.attachments[0].token,token);assert.equal(request.attachments[0].data,undefined);
 receive(h,'prompt',{requestID:request.requestID,error:'delivery uncertain'});assert.equal(h.eval("imagesFor('A').length"),1);assert.equal(h.$('send').disabled,true);
 h.eval('uncertain.clear();renderHeader();send()');const retry=h.messages.filter(m=>m.op==='prompt').at(-1);receive(h,'prompt',{requestID:retry.requestID,ok:true});assert.equal(h.eval("imagesFor('A').length"),0);
});
test('unsupported and oversized files reject before bridge read',async()=>{
 const h=harness();h.eval("stageImages([{type:'image/svg+xml',size:3,name:'unsafe.svg'}]);stageImages([{type:'image/png',size:104857601,name:'large.png'}]);supportsMarkdown=true;stageMarkdown([{name:'large.md',size:10485761}]);supportsPDF=true;stagePDFs([{name:'large.pdf',size:104857601}]);supportsWord=true;stageWords([{name:'large.docx',size:104857601}]);supportsVideos=true;stageVideos([{name:'large.mp4',size:52428801}])");
 assert.equal(h.reads.length,0);assert.equal(h.messages.some(m=>m.op==='fileBegin'||m.op==='videoBegin'),false);
});
test('paste stages once, preserves mixed text, and waits for Send',async()=>{
 const h=harness(),image=file('screenshot.png','image/png');let prevented=false;
 h.$('prompt').value='before after';h.$('prompt').selectionStart=7;h.$('prompt').selectionEnd=7;
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'file',getAsFile:()=>image}],files:[image],getData:()=> 'text '}});
 assert.equal(prevented,true);assert.equal(h.$('prompt').value,'before text after');assert.equal(h.messages.filter(m=>m.op==='fileBegin').length,1);
 await completeNative(h,ref('raster','screenshot.png'));assert.equal(h.eval("imagesFor('A').length"),1);assert.equal(h.messages.some(m=>m.op==='prompt'),false);
});
test('text paste remains native and file fallback preserves paste behavior',async()=>{
 const h=harness();let prevented=false;
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'string'}],files:[]}});assert.equal(prevented,false);
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[],files:[file('paste.png','image/png')],getData:()=>''}});assert.equal(prevented,true);await completeNative(h,ref('raster','paste.png'));
 assert.equal(h.eval("imagesFor('A').length"),1);
});
test('new image preview opens verified full original natively without changing draft',async()=>{
 const h=harness();h.$('prompt').value='keep this draft';h.$('prompt').oninput();h.context.fixture=file('image.png','image/png');h.eval('stageImages([fixture])');await completeNative(h,ref('raster','image.png'));
 h.$('attachments').children[0].children[0].click();assert.equal(h.messages.at(-1).op,'openFile');assert.equal(h.messages.at(-1).attachment.token,token);assert.equal(h.$('prompt').value,'keep this draft');assert.equal(h.messages.some(m=>m.op==='prompt'),false);
 h.$('attachments').children[0].children[2].click();assert.equal(h.eval("imagesFor('A').length"),0);
});
test('legacy inline image retains modal preview and Escape focus',()=>{
 const h=harness();h.eval("attachments.set('A',[{key:1,name:'old.png',url:'data:image/png;base64,YWJj',data:'YWJj',bytes:3}]);renderHeader()");
 const current=h.$('attachments').children[0].children[0];current.click();assert.equal(h.$('attachment-preview').open,true);
 let prevented=false;h.listeners.keydown({key:'Escape',isComposing:false,preventDefault(){prevented=true;}});assert.equal(prevented,true);assert.equal(h.$('attachment-preview').open,false);assert.equal(current.focused,true);
});
for(const [kind,name,type,flag,preview] of [['markdown','notes.md','text/markdown','supportsMarkdown','openFile'],['pdf','guide.pdf','application/pdf','supportsPDF','openPDF'],['word','report.docx','application/vnd.openxmlformats-officedocument.wordprocessingml.document','supportsWord','openWord']]){
 test(kind+' drop streams privately and previews original without sending',async()=>{
  const h=harness();h.eval(flag+'=true');let prevented=false;
  h.listeners.drop({preventDefault(){prevented=true;},dataTransfer:{types:['Files'],files:[file(name,type)]}});assert.equal(prevented,true);
  await completeNative(h,ref(kind,name));assert.equal(h.eval("imagesFor('A')[0].kind"),kind);h.$('attachments').children[0].children[0].click();assert.equal(h.messages.at(-1).op,preview);assert.equal(h.messages.some(x=>x.op==='prompt'),false);
 });
}
test('Finder large Markdown offer preserves exact draft and native preview reference',async()=>{
 const h=harness();h.eval('supportsVideos=true;supportsMarkdown=true;stageVideoOffer({id:"A",offer:"fixture",count:1})');const request=h.messages.find(m=>m.op==='videoImport');h.eval("selected='B'");
 receive(h,'videoImport',{requestID:request.requestID,id:'A',attachments:[ref('markdown','notes.md',22000)]});await tick();
 assert.equal(h.eval("imagesFor('A')[0].token"),token);assert.equal(h.eval("imagesFor('B').length"),0);assert.equal(h.eval("imagesFor('A')[0].text"),undefined);
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


test('successful native image completion remains with A after selecting B',async()=>{
 const h=harness();h.context.fixture=file('image.png','image/png');h.eval('stageImages([fixture])');h.eval("selected='B'");
 await completeNative(h,ref('raster','image.png'));assert.equal(h.eval("imagesFor('A')[0].token"),token);assert.equal(h.eval("imagesFor('B').length"),0);
 h.eval("selected='A';renderHeader()");assert.equal(h.$('attachments').children[0].children[1].textContent,'image.png');
});
test('Finder Word offer preserves original exact draft after selecting another agent',async()=>{
 const h=harness();h.eval('supportsVideos=true;supportsWord=true;stageVideoOffer({id:"A",offer:"finder-word",count:1})');const request=h.messages.find(m=>m.op==='videoImport');h.eval("selected='B'");
 receive(h,'videoImport',{requestID:request.requestID,id:'A',attachments:[ref('word','report.docx')]});await tick();assert.equal(h.eval("imagesFor('A')[0].token"),token);assert.equal(h.eval("imagesFor('B').length"),0);assert.equal(h.messages.some(m=>m.op==='prompt'),false);
});
test('Word Finder clipboard suppresses pasted path and native failure clears loading only',async()=>{
 const h=harness();h.eval('supportsWord=true');const doc=file('report.docx','application/vnd.openxmlformats-officedocument.wordprocessingml.document');let prevented=false;
 h.$('prompt').onpaste({preventDefault(){prevented=true;},clipboardData:{items:[{kind:'file',getAsFile:()=>doc}],files:[doc],getData:()=>'/Users/example/report.docx'}});
 assert.equal(prevented,true);assert.equal(h.$('prompt').value,'');const request=h.messages.find(m=>m.op==='fileBegin');receive(h,'fileBegin',{requestID:request.requestID,error:'synthetic failure'});await tick();assert.equal(h.eval("imagesFor('A').length"),0);assert.equal(h.eval("attachmentLoads.get('A')"),0);
});
test('legacy host image path still reads and previews inline images',async()=>{
 const h=harness();h.eval('supportsNativeFiles=false;stageImages([{name:"old.png",type:"image/png",size:3}])');assert.equal(h.messages.some(m=>m.op==='fileBegin'),false);h.reads[0]();await tick();
 h.$('attachments').children[0].children[0].click();assert.equal(h.$('attachment-preview').open,true);h.$('attachment-preview-close').click();assert.equal(h.$('attachment-preview').open,false);
 h.$('attachments').children[0].children[0].click();h.eval("select('B')");assert.equal(h.$('attachment-preview').open,false);assert.equal(h.eval("imagesFor('A').length"),1);
});
test('native preview and cancellation errors appear without mutating drafts',()=>{
 const h=harness();receive(h,'openFile',{error:'preview failed'});assert.equal(h.$('notice').textContent,'preview failed');receive(h,'fileCancel',{error:'cancel failed'});assert.equal(h.$('notice').textContent,'cancel failed');assert.equal(h.messages.some(m=>m.op==='prompt'),false);
});

test('chat settings keep shortcut and handoff choices independent per agent',()=>{
 const h=harness();
 h.context.window.HUDHandoff={eligible:()=>true};
 h.eval('supportsQuick=true;supportsHandoff=true;renderHeader()');
 assert.equal(h.$('quick-prompts').hidden,true);
 assert.equal(h.$('handoff-toolbar').hidden,true);
 h.$('chat-tools').click();
 h.$('show-handoff').checked=true;
 h.$('show-handoff').onchange();
 assert.equal(h.$('handoff-toolbar').hidden,false);
 assert.equal(h.$('quick-prompts').hidden,true);
 assert.equal(h.messages.at(-1).chatID,'A');
 h.eval("selected='B';renderHeader()");
 assert.equal(h.$('handoff-toolbar').hidden,true);
 h.eval("selected='A';renderHeader()");
 assert.equal(h.$('handoff-toolbar').hidden,false);
});
