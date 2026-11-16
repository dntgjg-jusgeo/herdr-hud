const {test}=require('node:test'),assert=require('node:assert/strict');
const {sorted,alerts,parse}=require('../Sources/HerdrHUD/Resources/model.js');
const row=(id,status)=>({id,terminal_id:id,agent_status:status,online:true});
test('attention before working before read idle',()=>assert.deepEqual(sorted([row('a','idle'),row('b','working'),row('c','blocked')],new Set()).map(a=>a.id),['c','b','a']));
test('status alerts exclude baseline, replacements, and offline recovery',()=>{assert.equal(alerts([],[row('a','done')]).length,0);assert.equal(alerts([row('a','working')],[row('a','done')]).length,1);assert.equal(alerts([row('a','working')],[{...row('a','done'),terminal_id:'new'}]).length,0);assert.equal(alerts([{...row('a','working'),online:false}],[row('a','done')]).length,0)});
test('provider fallback retains all text',()=>assert.equal(parse('plain text','claude').text,'plain text'));
test('Codex composer removed only with model footer',()=>{const p=parse('• Hello\n\n› Ask Codex to do anything\n  gpt-6-astra ultra · ~/repo','codex');assert.equal(p.model,'gpt-6-astra');assert.equal(p.reasoning,'ultra');assert.equal(p.blocks[0].text,'Hello');assert.equal(parse('quote gpt-6-astra\n› Keep this','codex').blocks.at(-1).text,'Keep this')});
test('tool blocks fold and code markers do not invent messages',()=>{const p=parse('• Ran test\n  output\n• Result\n```\n› not a prompt\n```','codex');assert.equal(p.blocks[0].kind,'tool');assert.equal(p.blocks.length,2);assert.match(p.blocks[1].text,/not a prompt/)});

test('wrapped current Codex composer and shortcut rows are not chat messages',()=>{
  const p=parse('• Finished the update.\n\n› Ask Codex to do anything\n\n  GPT-6-Astra medium · ~/Documents/project-\n  folder · Install skills\n  ← for agents · ? for shortcuts       ⚠ 1 warning · f2 to view','codex');
  assert.equal(p.model,'GPT-6-Astra');assert.equal(p.reasoning,'medium');
  assert.deepEqual(p.blocks,[{kind:'reply',text:'Finished the update.'}]);
});
test('submitted placeholder text and quoted model footer remain visible',()=>{
  const real=parse('› Ask Codex to do anything\n• What would you like?','codex');
  assert.equal(real.blocks[0].text,'Ask Codex to do anything');
  const example='• Example\n```\n› Ask Codex to do anything\n  GPT-6-Astra medium · ~/repo\n```';
  assert.match(parse(example,'codex').text,/Ask Codex to do anything/);
});
