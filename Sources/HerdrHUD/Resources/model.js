/* MIT — transcript parser and roster semantics shared by desktop shells. */
(function(root){
  function priority(a,unread){return a.agent_status==='blocked'||unread.has(a.id)?0:a.agent_status==='working'?1:2;}
  function sorted(agents,unread){return agents.map((agent,index)=>({agent,index})).sort((a,b)=>priority(a.agent,unread)-priority(b.agent,unread)||a.index-b.index).map(x=>x.agent);}
  function identity(a){return JSON.stringify([a.id,a.terminal_id,a.agent_session||null]);}
  function alerts(previous,current){const old=new Map(previous.map(a=>[a.id,a]));return current.filter(a=>{const b=old.get(a.id);return a.online&&b?.online&&identity(a)===identity(b)&&((a.agent_status==='blocked'&&b.agent_status!=='blocked')||(b.agent_status==='working'&&['idle','done'].includes(a.agent_status)));});}
  // Display-only recognition: this never creates terminal actions or authorization.
  // Unknown layouts stay verbatim. Require the complete Computer Use menu envelope,
  // not merely a numbered list that could be ordinary agent output.
  function approval(lines){
    const footer=lines.findIndex(line=>/^\s*enter to submit\s*[|·]\s*esc to cancel\s*$/i.test(line));
    if(footer<0)return null;
    let start=-1;
    for(let i=footer-1;i>=0;i--)if(/^\s*Allow Computer Use\b/.test(lines[i])){start=i;break;}
    if(start<0)return null;
    let first=-1;const options=[];
    for(let i=start+1;i<footer;i++){
      const match=/^\s*([›❯>])?\s*([1-4])\.\s+(Allow for this session|Always allow|Allow|Cancel)(?:\s{2,}(.*?))?\s*$/.exec(lines[i]);
      if(match){if(first<0)first=i;options.push({number:Number(match[2]),label:match[3],selected:!!match[1],description:match[4]?[match[4]]:[]});}
      else if(first>=0&&lines[i].trim())options.at(-1).description.push(lines[i].trim());
    }
    const labels=['Allow','Allow for this session','Always allow','Cancel'];
    if(options.length!==4||options.some((o,i)=>o.number!==i+1||o.label!==labels[i])||options.filter(o=>o.selected).length!==1)return null;
    let previous=start-1;while(previous>=0&&!lines[previous].trim())previous--;
    if(previous>=0&&/^\s*Field\s+1\s*\/\s*1\s*$/i.test(lines[previous]))start=previous;
    return {start,end:footer,question:lines.slice(start,first).join('\n').trim(),options:options.map(o=>({...o,description:o.description.join('\n')})),footer:lines[footer].trim()};
  }
  function parse(text,provider){
    let model='',reasoning='',lines=text.trimEnd().split('\n');
    if(provider!=='codex')return {text,model,reasoning,blocks:[]};
    // Codex's live composer is terminal chrome, not a submitted user message.
    // Newer versions wrap the model/path and add shortcut/warning rows beneath it.
    for(let end=lines.length-1;end>=Math.max(0,lines.length-10);end--){
      const footer=/^\s*(gpt-[\w.-]+|o[134](?:-[\w.-]+)?|codex-[\w.-]+)(?:\s+(minimal|low|medium|high|xhigh|max|ultra))?\s+[·|]\s*.+$/i.exec(lines[end]);
      if(!footer)continue;
      const suffix=lines.slice(end+1);
      if(suffix.some(line=>line.trim()&&(!line.startsWith('  ')||/^\s*[›❯»•●`]/.test(line))))continue;
      for(let i=end-1;i>=Math.max(0,end-14);i--){
        if(/^\s*[›❯»](?:\s|$)/.test(lines[i])){
          // A code sample may legitimately contain a prompt and model footer.
          const fences=lines.slice(0,i).filter(line=>line.trimStart().startsWith('```')).length;
          if(fences%2)break;
          model=footer[1];reasoning=(footer[2]||'').toLowerCase();lines=lines.slice(0,i);break;
        }
        if(lines[i].trim()&&(!lines[i].startsWith('  ')||/^\s*[•●`]/.test(lines[i])))break;
      }
      if(model)break;
    }
    const menu=approval(lines);
    let kind='context',body=[],fenced=false,blocks=[];
    const flush=()=>{const text=body.join('\n').trim();if(text)blocks.push({kind,text});body=[];};
    for(let index=0;index<lines.length;index++){const line=lines[index];
      if(menu&&index===menu.start&&!fenced){flush();blocks.push({kind:'approval',text:lines.slice(menu.start,menu.end+1).join('\n'),question:menu.question,options:menu.options,footer:menu.footer});index=menu.end;kind='context';continue;}
      const marker=!fenced&&/^([›❯»•●])(?: |$)(.*)/.exec(line),status=!fenced&&/^[─━]+ (Worked for .+|Conversation recap.*)/.exec(line);
      if(marker||status){flush();if(status){kind='status';body=[line.replace(/[─━]/g,'').trim()];}else{kind=/[›❯»]/.test(marker[1])?'prompt':/^(Ran |Explored\b|Viewed Image\b|Searched (for|the web)|Edited .+\(\+|Added .+\(\+|Deleted .+\(-|Interacted with background terminal\b)/.test(marker[2])?'tool':'reply';body=[marker[2]];}}
      else body.push(line);if(line.trimStart().startsWith('```'))fenced=!fenced;
    }flush();return {text:lines.join('\n').trimEnd(),model,reasoning,blocks};
  }
  function sessionModel(agent,output,native){
    if(!agent?.online)return '';
    const reported=(model,reasoning)=>{
      if(typeof model!=='string'||!(/^[a-z0-9][a-z0-9_./:-]{0,119}$/i.test(model)||/^Claude (?:Opus|Sonnet|Haiku) [0-9]+(?:\.[0-9]+)*$/i.test(model)))return '';
      return [model,typeof reasoning==='string'&&/^(none|minimal|low|medium|high|xhigh|max|ultra)$/i.test(reasoning)?reasoning.toLowerCase():''].filter(Boolean).join(' · ');
    };
    if(agent.agent==='codex'){
      const exact=native?.id===agent.id&&native.connected&&reported(native.model,native.reasoningEffort);
      if(exact)return exact;
      if(output?.id===agent.id&&output.provider==='codex'&&output.screenComplete!==false){
        const {model,reasoning}=parse(output.text||'','codex');
        const screen=reported(model,reasoning);if(screen)return screen;
      }
    }
    return reported(agent.reported_model,agent.reported_reasoning_effort)||
      (agent.agent==='opencode'&&agent.orca_managed===true?reported(agent.orca_model):'');
  }
  // Shepherdr mode: each space's coordinator, then its tasks (needs you first, merged last), linked to herdr agents by id.
  // A row without a running agent opens read only (view_id shepherdr:<chat key>), showing its Shepherdr chat.
  const TASK_ORDER=['need','ready','work','merging','todo','queued','done'],TASK_LABEL={need:'Needs you',ready:'Ready to merge',merging:'Merging',work:'Working',queued:'Queued',todo:'To do',done:'Done'};
  function shepherdrRows(data,agents){
    const byId=new Map(agents.map(a=>[a.id,a])),rank=t=>{const i=TASK_ORDER.indexOf(t.status);return i<0?TASK_ORDER.length:i;},rows=[];
    for(const space of data?.spaces||[]){
      const agent=byId.get(space.agent_id),view=(id,chat)=>id||(chat?'shepherdr:'+chat:'');
      rows.push({kind:'space',key:'space:'+space.id,agent_id:agent?space.agent_id:'',view_id:view(agent?space.agent_id:'',space.chat),title:space.name,detail:space.machine+' · coordinator',machine:space.machine,need:!!space.need,
        state:space.need?'Needs you':space.offline||agent?.online===false?'Offline':!agent?'Not running':agent.agent_status==='working'?'Working':agent.agent_status==='blocked'?'Blocked':'Idle'});
      (data.tasks||[]).filter(t=>t.place===space.id).map((t,i)=>({t,i})).sort((a,b)=>rank(a.t)-rank(b.t)||a.i-b.i).forEach(({t})=>{
        const state=t.status==='done'?t.sub||'Done':TASK_LABEL[t.status]||t.status;
        const id=byId.has(t.agent_id)?t.agent_id:'';
        rows.push({kind:'task',key:`task:${space.id}:${t.id}`,agent_id:id,view_id:view(id,t.chat),title:`${t.id} · ${t.title}`,detail:t.sub&&t.sub!==state?t.sub:'',space:space.name,machine:space.machine,need:t.status==='need',status:t.status,state});
      });
    }
    return rows;
  }
  // A local extractive preview: keep the opening outcome, never invent a summary.
  function notificationPreview(text,limit=150){
    const clean=String(text||'').replace(/```[\s\S]*?```/g,' ').replace(/!\[[^\]]*\]\([^)]*\)/g,' ')
      .replace(/\[([^\]]+)\]\([^)]*\)/g,'$1').replace(/^\s*(?:#{1,6}\s+|[-*•]\s+|\d+[.)]\s+)/gm,'')
      .replace(/[*`_]/g,'').replace(/\s+/g,' ').trim();
    if(!clean)return 'Open the chat to read the latest output.';
    if(clean.length<=limit)return clean;
    let summary='';for(const boundary of clean.matchAll(/[.!?](?=\s|$)/g)){const end=boundary.index+1;if(end>limit)break;summary=clean.slice(0,end);}
    if(summary.length>=35)return summary;
    const prefix=clean.slice(0,limit-1),space=prefix.lastIndexOf(' ');
    return prefix.slice(0,space>limit/2?space:prefix.length).replace(/[,:;\s]+$/,'')+'…';
  }
  const api={notificationPreview,sorted,alerts,parse,sessionModel,identity,shepherdrRows};if(typeof module!=='undefined')module.exports=api;else root.HUDModel=api;
})(globalThis);
