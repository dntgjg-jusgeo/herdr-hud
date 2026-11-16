const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm');
const Q=require('../Sources/HerdrHUD/Resources/followups.js'),D=require('../Sources/HerdrHUD/Resources/drafts.js');
const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY9sAAAAASUVORK5CYII=';
const image=()=>({name:'proof.png',data:png});
const item=(token,text='Follow up')=>({token,text,images:[]});
const state=queues=>({...D.restore({version:1,drafts:[]}),queues});
test('Claude and Codex queues keep exact identities and FIFO independently',()=>{
 const queues=new Map();
 for(const id of ['claude/core/t1/created1/pid1','codex/core/t2/created2/pid2']){
  Q.enqueue(queues,id,item(id+'-first','First'));Q.enqueue(queues,id,item(id+'-second','Second'));
  assert.equal(Q.head(queues,id).text,'First');assert.throws(()=>Q.begin(queues,id,id+'-second'));
  assert.equal(Q.begin(queues,id,id+'-first').status,'pending');assert.throws(()=>Q.remove(queues,id,id+'-first'));
  assert.equal(Q.settle(queues,id,id+'-second',true),false);assert.equal(Q.head(queues,id).text,'First');
  assert.equal(Q.settle(queues,id,id+'-first',true),true);assert.equal(Q.head(queues,id).text,'Second');
 }
 assert.equal(Q.head(queues,'replacement/pid3'),null);
});
test('uncertain sends never begin again; explicit remove is permitted without sending',()=>{
 const queues=new Map();Q.enqueue(queues,'claude',item('one'));Q.enqueue(queues,'claude',item('two'));
 Q.begin(queues,'claude','one');Q.settle(queues,'claude','one',false);
 assert.equal(Q.head(queues,'claude').status,'uncertain');assert.throws(()=>Q.begin(queues,'claude','one'));
 assert.equal(Q.remove(queues,'claude','one'),true);assert.equal(Q.head(queues,'claude').token,'two');
 assert.equal(Q.remove(queues,'claude','two'),true);assert.equal(queues.has('claude'),false);
});
test('queue-only images survive snapshot/restart; pending intent restores uncertain',()=>{
 const queues=new Map(),images=[image()];Q.enqueue(queues,'codex',{token:'image',text:'',images});images[0].name='changed';
 assert.equal(Q.head(queues,'codex').images[0].name,'proof.png');Q.begin(queues,'codex','image');
 const saved=D.snapshot(state(queues));assert.equal(saved.drafts[0].text,'');assert.equal(saved.drafts[0].queue[0].status,'uncertain');
 const restored=D.restore(saved);assert.equal(restored.queues.get('codex')[0].images[0].data,png);assert.throws(()=>Q.begin(restored.queues,'codex','image'));
});
test('snapshot shares text/image budgets and rejects duplicate tokens or oversized queues',()=>{
 const queues=new Map();for(let i=0;i<16;i++)Q.enqueue(queues,'claude',item('entry-'+i));
 assert.throws(()=>Q.enqueue(queues,'claude',item('overflow')));assert.throws(()=>Q.enqueue(queues,'codex',item('entry-0')));
 assert.throws(()=>Q.enqueue(new Map(),'codex',item('too-big','x'.repeat(60001))));
 const many=new Map();for(let i=0;i<16;i++)Q.enqueue(many,'codex',item('text-'+i,'x'.repeat(60000)));
 const combined=state(many);combined.drafts.set('claude','y'.repeat(60000));combined.drafts.set('codex','z'.repeat(60000));assert.throws(()=>D.snapshot(combined));
 const raw=D.snapshot(state(new Map([['codex',[{...item('pending'),status:'pending'}]]])));assert.equal(D.restore(raw).queues.get('codex')[0].status,'uncertain');
});
test('startup merge keeps saved FIFO and cannot rebind token to another session',()=>{
 const savedQueues=new Map();Q.enqueue(savedQueues,'claude',item('saved','Old first'));
 const current=state(new Map());Q.enqueue(current.queues,'claude',item('live','New second'));
 const restored=D.mergeRestored(D.snapshot(state(savedQueues)),current);assert.deepEqual(restored.queues.get('claude').map(x=>x.token),['saved','live']);
 current.queues=new Map([['codex',[{...item('saved'),status:'queued'}]]]);assert.throws(()=>D.mergeRestored(D.snapshot(state(savedQueues)),current));
});
test('queue helper accepts the browser map realm used by host integration fixtures',()=>{
 const queues=vm.runInNewContext('new Map()');Q.enqueue(queues,'codex',item('realm'));assert.equal(Q.head(queues,'codex').token,'realm');
});

test('video queue references survive and equality checks token and metadata',()=>{
 const video={kind:'video',token:'01234567-89ab-cdef-0123-456789abcdef',name:'clip.mp4',bytes:20,poster:'data:image/jpeg;base64,/9j/2Q==',duration:1,width:20,height:10};
 const queues=new Map();Q.enqueue(queues,'codex',{token:'q',text:'',images:[image(),video]});
 const saved=D.snapshot(state(queues));assert.equal(saved.version,3);assert.deepEqual(saved.drafts[0].queue[0].images[1],video);
 const restored=D.restore(saved);assert.equal(restored.queues.get('codex')[0].images[1].token,video.token);
 const current=state(new Map([['codex',[{token:'q',text:'',images:[image(),{...video,token:'11234567-89ab-cdef-0123-456789abcdef'}],status:'queued'}]]]));
 assert.throws(()=>D.mergeRestored(saved,current));
});
