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
test('backward compatible queue normalization and queue-only rows are retained',()=>{
 const old=D.restore(value([row({images:[]})]));assert.equal(old.queues.size,0);
 const saved=value([row({text:'',images:[],queue:[{token:'first',text:'Next task',images:[],status:'pending'}]})]);
 const restored=D.restore(saved);assert.equal(restored.queues.get('exact identity')[0].status,'uncertain');
 assert.equal(D.snapshot(restored).drafts[0].queue[0].text,'Next task');
 for(const queue of [[{token:'bad',text:'',images:[],status:'queued'}],[{token:'bad',text:'x',images:[],status:'done'}]])assert.throws(()=>D.restore(value([row({queue})])));
});

test('loads legacy version one but always writes version two to fail closed on old rollback binaries',()=>{
 const migrated=D.snapshot(D.restore(value([row({images:[]})])));assert.equal(migrated.version,2);assert.equal(migrated.drafts[0].text,'keep me');
 assert.equal(D.snapshot(D.restore({version:2,drafts:[]})).version,2);assert.equal(D.restore({version:3,drafts:[]}).drafts.size,0);
});

const video=(token='01234567-89ab-cdef-0123-456789abcdef')=>({kind:'video',token,name:'clip.mp4',bytes:104857600,poster:'data:image/jpeg;base64,/9j/2Q==',duration:2,width:640,height:480});
test('mixed video references round trip, recover and count shared tokens only once',()=>{
 const v=video(),saved={version:3,drafts:[row({images:[{name:'image.png',data:png},v],queue:[{token:'q',text:'next',images:[v],status:'pending'}]})]};
 const state=D.restore(saved),snap=D.snapshot(state);assert.equal(snap.version,3);assert.deepEqual(snap.drafts[0].images,[{data:png,name:'image.png'},v]);assert.deepEqual(snap.drafts[0].queue[0].images,[v]);assert.equal(snap.drafts[0].queue[0].status,'uncertain');
 const merged=D.mergeRestored(snap,D.restore(saved),new Set(['exact identity']));assert.equal(merged.attachments.get('exact identity').length,2);
 assert.throws(()=>D.restore({...saved,version:2}));
 for(const patch of [{token:'BAD'},{bytes:0},{poster:'data:image/jpeg;base64,AAAA'},{poster:'data:image/png;base64,/9j/2Q=='},{duration:Infinity},{name:'../clip'}])assert.throws(()=>D.restore({version:3,drafts:[row({images:[{...v,...patch}]})]}));
 assert.throws(()=>D.restore({version:3,drafts:[row({images:[v,{...v,bytes:1}]})]}));
 const tooMany=Array.from({length:6},(_,i)=>row({id:String(i),images:[video(`01234567-89ab-cdef-0123-${String(i).padStart(12,'0')}`)]}));assert.throws(()=>D.restore({version:3,drafts:tooMany}));
});

test('repeated posters across composer and queue are bounded before persistence',()=>{
 const v=video();v.poster='data:image/jpeg;base64,/9j/'+ 'A'.repeat(349972); // valid base64 and within the individual cap
 const rows=Array.from({length:6},(_,i)=>row({id:String(i),images:i===0?[v]:[],queue:i===0?[]:[{token:'q'+i,text:'',images:[v],status:'queued'}]}));
 assert.throws(()=>D.restore({version:3,drafts:rows}));
 const accepted=D.restore({version:3,drafts:rows.slice(0,5)});accepted.queues.set('extra',[{token:'extra',text:'',images:[v],status:'queued'}]);
 assert.throws(()=>D.snapshot(accepted));
 for(const patch of [{name:'clip.mov'},{name:'clip\n.mp4'},{width:1.5},{height:16385},{width:8000,height:8000},{duration:86401}])assert.throws(()=>D.restore({version:3,drafts:[row({images:[{...video(),...patch}]})]}));
});

test('Markdown uses v4, round trips exact UTF8 and shares aggregate text budget',()=>{
 const text='# Café\n<script>not executed</script>',md={kind:'markdown',name:'notes.md',text,bytes:Buffer.byteLength(text)};
 const restored=D.restore({version:4,drafts:[row({images:[md]})]});assert.deepEqual(D.snapshot(restored).drafts[0].images,[md]);assert.equal(D.snapshot(restored).version,4);
 assert.throws(()=>D.restore({version:3,drafts:[row({images:[md]})]}));
 for(const patch of [{bytes:1},{name:'../x.md'},{name:'x.exe'},{text:'bad\0',bytes:4},{text:'x'.repeat(16385),bytes:16385}])assert.throws(()=>D.restore({version:4,drafts:[row({images:[{...md,...patch}]})]}));
 const large={kind:'markdown',name:'large.md',text:'x'.repeat(16384),bytes:16384};
 assert.throws(()=>D.restore({version:4,drafts:Array.from({length:65},(_,i)=>row({id:String(i),text:'',images:[large]}))}));
});
