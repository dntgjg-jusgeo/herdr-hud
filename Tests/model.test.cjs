const {test}=require('node:test'),assert=require('node:assert/strict');
const {sorted,alerts,parse,sessionModel}=require('../Sources/HerdrHUD/Resources/model.js');
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
test('session heading preserves exact model version and reported reasoning',()=>{
  const agent={id:'codex-1',agent:'codex',online:true};
  const output={id:agent.id,provider:'codex',screenComplete:true,text:'• Reply\n› Ask Codex anything\n  GPT-6-Astra medium · ~/repo'};
  assert.equal(sessionModel(agent,output),'GPT-6-Astra · medium');
  assert.equal(sessionModel(agent,{...output,text:output.text.replace('6-Astra medium','6.2-Astra high')}),'GPT-6.2-Astra · high');
  assert.equal(sessionModel(agent,output,{id:agent.id,connected:true,model:'gpt-6.2-astra',reasoningEffort:'xhigh'}),'gpt-6.2-astra · xhigh');
  assert.equal(sessionModel(agent,{...output,screenComplete:false}),'');
  assert.equal(sessionModel(agent,{...output,id:'codex-2'},{id:'codex-2',connected:true,model:'gpt-6.2-astra'}),'');
  assert.equal(sessionModel(agent,{...output,text:'• I am GPT-6.2-Astra with medium effort.'}),'');
  assert.equal(sessionModel({...agent,online:false},output),'');
});
test('Claude and OpenCode heading uses provider-reported metadata',()=>{
  const claude={id:'claude-1',agent:'claude',online:true,reported_model:'claude-opus-4-8',reported_reasoning_effort:'high'};
  const openCode={id:'code-1',agent:'opencode',online:true,orca_managed:true,orca_model:'deepseek/deepseek-v4.1-flash'};
  assert.equal(sessionModel(claude),'claude-opus-4-8 · high');
  assert.equal(sessionModel(openCode),'deepseek/deepseek-v4.1-flash');
  assert.equal(sessionModel({...openCode,orca_managed:false}),'');
});

const computerUseMenu='Field 1/1\n\nAllow Computer Use to use "Demo Drag Test"?\nApp: /Applications/Demo.app\n\n› 1. Allow\n  2. Allow for this session\n  3. Always allow\n  4. Cancel\n\nenter to submit | esc to cancel';
test('complete Computer Use menu is display-only approval, preserving question and scope',()=>{
  const p=parse('• Waiting for your decision.\n\n'+computerUseMenu,'codex'),card=p.blocks.at(-1);
  assert.equal(card.kind,'approval');assert.equal(card.question,'Field 1/1\n\nAllow Computer Use to use "Demo Drag Test"?\nApp: /Applications/Demo.app');
  assert.deepEqual(card.options.map(o=>[o.number,o.label,o.selected]),[[1,'Allow',true],[2,'Allow for this session',false],[3,'Always allow',false],[4,'Cancel',false]]);
  assert.equal(card.footer,'enter to submit | esc to cancel');assert.equal(p.blocks.some(b=>b.kind==='prompt'),false);assert.equal(p.text,'• Waiting for your decision.\n\n'+computerUseMenu);
});
test('menu wraps and descriptions remain exact, never inferred from scope labels',()=>{
  const wrapped=computerUseMenu.replace('App:', 'with window access\nApp:').replace('  3. Always allow','    Applies until this agent exits.\n  3. Always allow');
  const card=parse(wrapped,'codex').blocks[0];assert.equal(card.kind,'approval');assert.match(card.question,/with window access\nApp:/);
  assert.equal(card.options[1].description,'Applies until this agent exits.');assert.equal(card.options[2].description,'');
});
test('ordinary, incomplete, unknown, unselected and fenced menus never become approval cards',()=>{
  for(const text of ['• Steps\n1. Allow\n2. Allow for this session\n3. Always allow\n4. Cancel',computerUseMenu.replace('enter to submit | esc to cancel',''),computerUseMenu.replace('Always allow','Allow permanently'),computerUseMenu.replace('› 1.','1.'),'• Example\n```\n'+computerUseMenu+'\n```'])assert.equal(parse(text,'codex').blocks.some(b=>b.kind==='approval'),false,text);
  assert.deepEqual(parse(computerUseMenu,'claude').blocks,[]);
});
test('screenshot approval menu keeps same-line descriptions and wrapped scope',()=>{
  const screenshot=computerUseMenu.replace('› 1. Allow','› 1. Allow    Run the tool and continue').replace('  2. Allow for this session','  2. Allow for this session    Run the tool and remember this choice for\n    this session').replace('  3. Always allow','  3. Always allow    Remember this choice for future requests').replace('  4. Cancel','  4. Cancel    Stop this request');
  const blocks=parse(screenshot,'codex').blocks;assert.equal(blocks.length,1);assert.equal(blocks[0].kind,'approval');assert.equal(blocks[0].options[0].description,'Run the tool and continue');assert.equal(blocks[0].options[1].description,'Run the tool and remember this choice for\nthis session');assert.equal(blocks.some(b=>b.kind==='prompt'),false);
});
