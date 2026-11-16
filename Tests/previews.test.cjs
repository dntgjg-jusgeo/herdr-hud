const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8'),model=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/model.js'),'utf8');
class Node{constructor(tag){this.tag=tag;this.children=[];this.attrs={};this.textContent='';this.value='';this.style={};this.hidden=false;this.disabled=false;}
  append(...n){this.children.push(...n);}replaceChildren(...n){this.children=n;}setAttribute(k,v){this.attrs[k]=v;}getAttribute(k){return this.attrs[k];}
  querySelectorAll(){return [];}querySelector(){return null;}dispatchEvent(e){this['on'+e.type]?.(e);}click(){this.onclick?.();}}
function harness(platform){
  const nodes=new Map(),messages=[];
  const document={getElementById(id){if(!nodes.has(id))nodes.set(id,new Node(id));return nodes.get(id);},createElement:tag=>new Node(tag),createTextNode:text=>({textContent:text}),addEventListener(){},querySelector:()=>new Node('aside')};
  const window=platform==='mac'?{webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}}}:{chrome:{webview:{postMessage:m=>messages.push(m),addEventListener(){}}}};
  const context=vm.createContext({window,document,globalThis:{},setInterval(){},Event:class{constructor(type){this.type=type;}},console,innerWidth:900,innerHeight:600});
  vm.runInContext(model.replace('(globalThis)','(this)'),context);vm.runInContext(source,context);
  const $=id=>document.getElementById(id),buttons=()=>$('roster').children.filter(n=>n.tag==='button'),badge=()=>messages.filter(m=>m.op==='badge').at(-1)?.count;
  return {window,messages,$,buttons,badge};
}

test('preview copies use opaque tokens, reject stale requests and preserve draft',()=>{
  const h=harness('mac'),a={id:'A',machine_id:'local',agent:'codex',agent_status:'idle',online:true};
  h.window.receive({type:'preferences',data:{previewsSupported:true}});
  h.window.receive({type:'roster',data:{agents:[a],machines:[]}});
  h.$('prompt').value='keep this draft';h.$('prompt').oninput();
  h.$('previews-tab').click();
  assert.equal(h.$('output').hidden,true);assert.equal(h.$('previews').hidden,false);
  const first=h.messages.filter(m=>m.op==='previews').at(-1);
  h.$('preview-refresh').click();const current=h.messages.filter(m=>m.op==='previews').at(-1);
  const item={token:'opaque',name:'<img onerror=bad>.png',thumbnail:'data:image/jpeg;base64,YQ==',width:12,height:8};
  h.window.receive({type:'previews',data:{id:'A',requestID:first.requestID,items:[item]}});
  assert.equal(h.$('preview-grid').children.length,0);
  h.window.receive({type:'previews',data:{id:'A',requestID:current.requestID,items:[item,{...item,thumbnail:'https://example.com/image.png'}]}});
  const buttons=h.$('preview-grid').children;assert.equal(buttons.length,1);assert.equal(buttons[0].children[1].textContent,item.name);
  buttons[0].click();const open=h.messages.find(m=>m.op==='openPreview');assert.equal(open.token,'opaque');assert.equal(open.id,'A');assert.equal(open.path,undefined);
  h.$('chat').click();assert.equal(h.$('prompt').value,'keep this draft');assert.equal(h.messages.filter(m=>m.op==='prompt').length,0);
  assert.equal(h.$('output').hidden,false);
});
test('unsupported host hides previews and other agent folder completion cannot replace gallery',()=>{
  const h=harness('windows');h.window.receive({type:'preferences',data:{}});assert.equal(h.$('previews-tab').hidden,true);
  const before=h.messages.length;h.window.receive({type:'previewFolderChanged',data:{id:'other'}});assert.equal(h.messages.length,before);
});
