const {test}=require('node:test'),assert=require('node:assert/strict');
const D=require('../Sources/HerdrHUD/Resources/drafts.js');
const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY9sAAAAASUVORK5CYII=';
function row(extra={}){return {id:'exact identity',label:'Claude · task',text:'keep me',images:[{name:'image.png',data:png}],uncertain:false,keyUncertain:false,...extra};}
function value(rows=[row()]){return {version:1,drafts:rows};}
test('restores exact identity, original image name and full bytes; snapshots pending delivery as uncertain',()=>{
 const state=D.restore(value());assert.equal(state.drafts.get('exact identity'),'keep me');
 const image=state.attachments.get('exact identity')[0];assert.equal(image.name,'image.png');assert.equal(image.data,png);assert.ok(image.url.startsWith('data:image/png;base64,'));
 state.pendingPromptIDs=['exact identity'];state.pendingKeyIDs=['exact identity'];const saved=D.snapshot(state);assert.equal(saved.drafts[0].uncertain,true);assert.equal(saved.drafts[0].keyUncertain,true);assert.equal(saved.drafts[0].label,'Claude · task');
});
test('rejects invalid identities, duplicates, malformed bytes and bounded content',()=>{
 for(const snapshot of [value([row(),row()]),value([row({id:''})]),value([row({text:'a'.repeat(60001)})]),value([row({images:[{name:'../bad.png',data:png}]})]),value([row({images:[{name:'bad.svg',data:btoa('<svg/>')}]})]),value([row({images:Array(4).fill({name:'a.png',data:png})})]),value(Array.from({length:129},(_,i)=>row({id:String(i)})))])assert.throws(()=>D.restore(snapshot));
 assert.throws(()=>D.restore(value([row({text:'😀'.repeat(16000)})])));
});
test('startup merge preserves edits, images, labels, and uncertain flags without rebinding identity',()=>{
 const live=D.restore(value([row({text:'typed meanwhile',images:[],uncertain:true})]));
 const merged=D.mergeRestored(value(),live,new Set(['exact identity']));
 assert.equal(merged.drafts.get('exact identity'),'keep me\n\ntyped meanwhile');assert.equal(merged.attachments.get('exact identity').length,1);assert.equal(merged.uncertain.has('exact identity'),true);assert.equal(merged.drafts.has('replacement identity'),false);
});
test('persistence cannot overwrite before restoration and flush waits for acknowledged serialized saves',async()=>{
 let current=1,timer,ack;const writes=[];
 const p=D.persistence({capture:()=>current,save:v=>{writes.push(v);return new Promise(resolve=>ack=resolve);},setTimer:fn=>(timer=fn,1),clearTimer:()=>{timer=null;}});
 p.changed();assert.equal(timer,undefined);await assert.rejects(p.flush(),/restoring/);assert.deepEqual(writes,[]);
 p.start();const first=p.flush();await Promise.resolve();await Promise.resolve();assert.deepEqual(writes,[1]);let done=false;first.then(()=>done=true);assert.equal(done,false);
 current=2;const second=p.flush();await Promise.resolve();assert.deepEqual(writes,[1]);ack();await first;await Promise.resolve();assert.deepEqual(writes,[1,2]);ack();await second;
 p.changed();assert.equal(typeof timer,'function');p.stop();assert.equal(timer,null);
});
