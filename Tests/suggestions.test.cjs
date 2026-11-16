const assert=require('node:assert/strict');
const {extract}=require('../Sources/HerdrHUD/Resources/suggestions.js');
const reply=text=>({blocks:[{kind:'reply',text}]});
assert.deepEqual(extract(reply('Which option would you like?\n- Create a draft\n- Review the design')), [
  {label:'Create a draft',text:'Create a draft'},
  {label:'Review the design',text:'Review the design'}
]);
assert.deepEqual(extract(reply('Which option would you like?\n- Yes\n- No')), [{label:'Yes',text:'Yes'},{label:'No',text:'No'}]);
assert.deepEqual(extract(reply('Which option would you like?\n- Dark theme\n- Light theme')), [{label:'Dark theme',text:'Dark theme'},{label:'Light theme',text:'Light theme'}]);
assert.deepEqual(extract(reply('Would you like me to run the tests?')), [{label:'run the tests',text:'Please run the tests'}]);
for(const text of [
  'Results:\n1. First finding\n2. Second finding',
  'Which option?\n1. Allow\n2. Always allow',
  'Would you like me to approve this?',
  'Would you like me to grant access?',
  'Which option?\n- The server restarted\n- The job completed',
  '```\nWhich option?\n- First\n- Second\n```',
  'Which option?\n- One',
  'Which option?\n- One\n- Two\n- Three\n- Four',
  'Finished the work.',
  'What happened?\n1. The server restarted\n2. The job completed'
]) assert.deepEqual(extract(reply(text)),[],text);
assert.deepEqual(extract({blocks:[{kind:'reply',text:'Would you like me to run tests?'},{kind:'prompt',text:'No'}]}),[]);
assert.deepEqual(extract({blocks:[{kind:'reply',text:'Would you like me to run tests?'},{kind:'tool',text:'Ran tests'}]}),[]);
assert.deepEqual(extract({blocks:[{kind:'approval',text:'Would you like me to run tests?'}]}),[]);
assert.deepEqual(extract({blocks:[]}),[]);
console.log('suggestions tests passed');
