/* Shared, deterministic HUD interaction helpers. */
(function(root){
 const defaults=[{label:'Review this',text:'Please review the current changes and flag any issues.'},{label:'Run tests',text:'Please run the relevant tests and report the results.'},{label:'Summarize progress',text:'Please summarize what is done, what remains, and any blockers.'}];
 function prompts(rows){if(!Array.isArray(rows)||rows.length>6)throw Error('Use up to six quick prompts.');return rows.map(r=>{if(typeof r.label!=='string'||!r.label.trim()||r.label.length>32||typeof r.text!=='string'||!r.text.trim()||r.text.length>2000)throw Error('Each prompt needs a name (32 characters) and text (2,000 characters).');return {label:r.label.trim(),text:r.text.trim()};});}
 function status(a,finished=false){if(!a)return 'No agent';if(!a.online)return 'Offline';if(a.agent_status==='blocked')return {permission:'Needs approval',question:'Has a question',auth:'Needs sign-in'}[a.input_kind]||'Needs input';return {working:'Working',done:'Finished',idle:finished?'Finished':'Ready',readonly:'Not running',error:'Error'}[a.agent_status]||'Status unknown';}
 function nearBottom(node){return typeof node.scrollHeight!=='number'||node.scrollHeight-node.scrollTop-node.clientHeight<70;}
 const api={defaults,prompts,status,nearBottom};if(typeof module!=='undefined')module.exports=api;else root.HUDUtilities=api;
})(globalThis);
