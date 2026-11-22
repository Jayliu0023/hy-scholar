// Markdown text uses the same UTF-16 offsets as the selection and markup tools.
let marginSpec={notes:[],regions:[]}, marginMarks=[], marginFrame=0, textIndex=null;
const paper=()=>document.getElementById('paper');
function indexPaper() {
  if(textIndex) return textIndex;
  let offset=0;
  textIndex=textNodes(paper()).map(node=>{
    const start=offset;offset+=node.length;return {node,start,end:offset};
  });
  return textIndex;
}
function rangeAt(span) {
  const nodes=indexPaper();
  function covering(at) {
    let lo=0,hi=nodes.length;
    while(lo<hi){const mid=(lo+hi)>>>1;if(nodes[mid].end<=at) lo=mid+1;else hi=mid;}
    return nodes[lo];
  }
  const a=covering(span.start),end=span.start+span.length,b=covering(end-1);
  if(!a||!b||span.length<=0)return null;
  const r=document.createRange();r.setStart(a.node,span.start-a.start);r.setEnd(b.node,end-b.start);return r;
}
const bounds=r=>({x:r.left,y:r.top,w:r.width,h:r.height});
const visible=r=>r.width>0 && r.height>0 && r.bottom>0 && r.top<innerHeight && r.right>0 && r.left<innerWidth;
function webSpot(x,y) {
  const root=paper(), blocks=[...root.children];
  let block=document.elementFromPoint(x,y);
  while(block && block.parentElement!==root) block=block.parentElement;
  if(!block) block=blocks.reduce((best,b)=>{
    const r=b.getBoundingClientRect(),distance=Math.max(0,r.top-y,y-r.bottom);
    return !best||distance<best.distance?{b,distance}:best;
  },null)?.b;
  const rect=(block||root).getBoundingClientRect();
  return {block:blocks.indexOf(block),x:(x-rect.left)/Math.max(1,rect.width),y:(y-rect.top)/Math.max(1,rect.height)};
}
function viewportPoint(spot) {
  const block=paper().children[spot.block]||paper(),r=block.getBoundingClientRect();
  return {x:r.left+r.width*spot.x,y:r.top+r.height*spot.y};
}
function regionBounds(box) {
  const a=viewportPoint(box.start),b=viewportPoint(box.end);
  return new DOMRect(Math.min(a.x,b.x),Math.min(a.y,b.y),Math.abs(a.x-b.x),Math.abs(a.y-b.y));
}
function makeMarginBox(id,x1,y1,x2,y2) {
  if(id!==documentID)return null;
  const start=webSpot(Math.min(x1,x2),Math.min(y1,y2)),end=webSpot(Math.max(x1,x2),Math.max(y1,y2));
  const block=paper().children[start.block];
  const offset=block ? offsetIn(paper(),block,0)+Math.min(1,Math.max(0,start.y))*block.textContent.length : 0;
  return {start,end,offset};
}
function setMargins(id,spec) {
  if(id!==documentID)return;
  marginSpec=spec;queueMarginGeometry();
}
function queueMarginGeometry() {
  if(marginFrame)return;
  marginFrame=requestAnimationFrame(()=>{
    marginFrame=0;
    const notes={}, boxes={}, marks=[];
    for(const note of marginSpec.notes) {
      const rs=note.spans.flatMap(s=>[...(rangeAt(s)?.getClientRects()||[])]).filter(visible);
      if(rs.length)notes[note.id]=rs.map(bounds);
    }
    for(const box of marginSpec.regions){const r=regionBounds(box);if(visible(r))boxes[box.id]=bounds(r);}
    for(const mark of marginMarks){
      const range=rangeAt(mark.span);if(!range)continue;
      const rs=[...range.getClientRects()].filter(visible);
      if(rs.length)marks.push({start:mark.span.start,length:mark.span.length,text:range.toString(),rects:rs.map(bounds)});
    }
    webkit.messageHandlers.marginGeometry.postMessage({id:documentID,notes,boxes,marks});
  });
}
function revealMargin(id,note) {
  if(id!==documentID)return;
  const r=note.start ? regionBounds(note) : rangeAt(note.spans[0])?.getBoundingClientRect();
  if(r)window.scrollBy(0,r.top-innerHeight*0.32);
}
addEventListener('scroll',queueMarginGeometry,{passive:true});
addEventListener('resize',queueMarginGeometry);
new ResizeObserver(queueMarginGeometry).observe(paper());
