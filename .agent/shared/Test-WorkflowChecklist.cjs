const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(__dirname+'/Update-HumanWorkConsole.ps1','utf8');
const code=source.split('// WORKFLOW_CHECKLIST_BEGIN')[1].split('// WORKFLOW_CHECKLIST_END')[0];
function run(saved={},fail=false){
 let scrolls=[],stored;
 const boxes=['a/one','a/two','b/one'].map(id=>({checked:false,getAttribute:()=>id,addEventListener(event,fn){this.change=fn;}}));
 const steps=[[boxes[0],boxes[1]],[boxes[2]]].map((items,i)=>({classes:new Set(),progress:{},querySelectorAll:()=>items,querySelector(){return this.progress;},scrollIntoView(){scrolls.push(i);},classList:{toggle(c,on){on?steps[i].classes.add(c):steps[i].classes.delete(c);},remove(c){steps[i].classes.delete(c);},add(c){steps[i].classes.add(c);}}}));
 const elements={'workflow-storage':{},'workflow-progress':{},'work-panel-0':{hidden:false},'workflow-resume':{addEventListener(e,fn){this.click=fn;}}};
 const context={document:{querySelectorAll:s=>s==='.workflow-step'?steps:boxes,getElementById:id=>elements[id]},location:{pathname:'/work/console.html'},localStorage:{getItem(){if(fail)throw Error();return JSON.stringify(saved);},setItem(k,v){if(fail)throw Error();stored=JSON.parse(v);}},requestAnimationFrame:fn=>fn()};
 vm.runInNewContext(code,context);
 return {boxes,steps,elements,scrolls,get stored(){return stored;}};
}
let x=run({'a/one':true,'a/two':true});
assert.deepEqual(x.scrolls,[1]);assert(x.steps[0].classes.has('is-complete'));assert(x.steps[1].classes.has('is-current'));
x.boxes[2].checked=true;x.boxes[2].change();assert.deepEqual(x.scrolls,[1]);assert.equal(x.elements['workflow-progress'].textContent,'모든 단계를 완료했습니다.');
assert.deepEqual(x.stored,{'a/one':true,'a/two':true,'b/one':true});
x.boxes[0].checked=false;x.boxes[0].change();assert(x.steps[0].classes.has('is-current'));
x.elements['workflow-resume'].click();assert.deepEqual(x.scrolls,[1,0]);
x=run({'a/one':true,'a/two':true,'b/one':true});assert.deepEqual(x.scrolls,[]);
x=run({},true);x.boxes[0].checked=true;x.boxes[0].change();assert.match(x.elements['workflow-storage'].textContent,/저장할 수 없습니다/);
console.log(JSON.stringify({ok:true,checks:8,scope:'check persistence, resume, complete, uncheck, no jump and storage failure'}));
