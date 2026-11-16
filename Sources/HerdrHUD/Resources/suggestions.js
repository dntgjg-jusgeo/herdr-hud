/* MIT — conservative, reviewable drafts from the latest assistant reply. */
(function(root){
  const unsafe=/\b(?:allow|approval|approve|permission|authorize|authorise|consent|always[- ]allow|grant(?:ing)? access|permit|deny|reject)\b/i;
  function clean(s){return s.replace(/\*\*/g,'').replace(/\s+/g,' ').trim();}
  function label(s){return s.length<=42?s:s.slice(0,39).trimEnd()+'…';}
  function draft(s,proposal=false){
    s=clean(s);if(proposal)s=s.replace(/[.!?]+$/,'');
    if(!s||s.length>240||unsafe.test(s)||/^(?:the|it|this|that|they|he|she|we|i)\b/i.test(s))return null;
    return {label:label(s),text:proposal&&!/^please\b/i.test(s)?'Please '+s.charAt(0).toLowerCase()+s.slice(1):s};
  }
  function extract(parsed){
    if(!parsed||!Array.isArray(parsed.blocks)||!parsed.blocks.length)return [];
    const last=parsed.blocks[parsed.blocks.length-1];
    if(!last||last.kind!=='reply'||typeof last.text!=='string')return [];
    // A code fence anywhere near a proposed menu makes its context ambiguous.
    if(/```|~~~/.test(last.text))return [];
    const lines=last.text.split('\n').map(s=>s.trim()).filter(Boolean);
    if(!lines.length)return [];
    const choices=[];let i=lines.length-1;
    while(i>=0){
      const m=/^(?:[-*]|\d+[.)])\s+(.+)$/.exec(lines[i]);
      if(!m)break;
      choices.unshift(clean(m[1]));i--;
    }
    if(choices.length){
      if(choices.length<2||choices.length>3||i<0)return [];
      const question=clean(lines[i]);
      if(unsafe.test(question)||!question.endsWith('?')||! /^(?:which|what would you like|what should|would you like|do you want|can you choose|could you choose)\b/i.test(question))return [];
      const results=choices.map(s=>draft(s));
      return results.every(Boolean)?results:[];
    }
    const question=clean(lines[lines.length-1]);
    if(unsafe.test(question))return [];
    const proposal=/^Would you like me to (.+)\?$/i.exec(question);
    if(!proposal)return [];
    const result=draft(proposal[1],true);return result?[result]:[];
  }
  const api={extract};if(typeof module!=='undefined')module.exports=api;else root.HUDSuggestions=api;
})(globalThis);
