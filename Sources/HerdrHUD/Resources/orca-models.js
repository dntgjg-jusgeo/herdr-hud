/* Catalog entries are filtered and authorized by the native host. No network or credentials here. */
(function(root){
 'use strict';
 function search(models,query){const q=String(query||'').trim().toLowerCase();return (models||[]).filter(m=>!q||`${m.name} ${m.id}`.toLowerCase().includes(q));}
 function detail(model){if(!model)return 'Choose a model to open a new OpenCode chat.';const parts=[model.id,`Released ${model.releaseDate}`];if(Number.isSafeInteger(model.contextLength)&&model.contextLength>0)parts.push(`${model.contextLength.toLocaleString()} context`);if(typeof model.tools==='boolean')parts.push(model.tools?'Tool support reported':'No tool support reported');return parts.join(' · ');}
 const api={search,detail};if(typeof module!=='undefined')module.exports=api;else root.HUDOrcaModels=api;
})(typeof window!=='undefined'?window:globalThis);
