const {test}=require('node:test');
const assert=require('node:assert/strict');
const {notificationPreview}=require('../Sources/HerdrHUD/Resources/model.js');
test('notification keeps a complete opening outcome and removes markdown',()=>{
  const opening='Implemented the card stack and arrow navigation.';
  assert.equal(notificationPreview('**'+opening+'**\n- '+ 'Additional implementation details '.repeat(20)),opening);
});
test('long notification ends at a word boundary with ellipsis',()=>{
  const result=notificationPreview('Implemented the card stack: '+ 'new captures join the stack '.repeat(20));
  assert.ok(result.length<=150);assert.ok(result.endsWith('…'));assert.ok(!result.includes('\n'));
});
test('short notification stays intact and empty output has a useful fallback',()=>{
  assert.equal(notificationPreview('[Build](file:///tmp/build) passed.'),'Build passed.');
  assert.equal(notificationPreview(''),'Open the chat to read the latest output.');
});

test('dotted versions and URLs never lose the opening outcome',()=>{
  for(const opening of ['Implemented version 1.2.3 and finished the migration.', 'Updated https://example.com/page and completed the checks.']){
    assert.equal(notificationPreview(opening+' '+'Additional details '.repeat(30)),opening);
  }
});
