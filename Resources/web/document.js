let documentID = "";
function renderPaper(text, id, marks) {
  documentID = id;
  const fragment = DOMPurify.sanitize(marked.parse(text), {
    RETURN_DOM_FRAGMENT: true, ALLOW_DATA_ATTR: false, USE_PROFILES: {html:true},
    FORBID_TAGS: ['form','input','button','video','audio','style','base','meta','link'],
    FORBID_ATTR: ['style','srcset','id','name']
  });
  for (const img of fragment.querySelectorAll('img[src]')) {
    const src = img.getAttribute('src');
    if (/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)) continue;
    if (!/^(?:[a-z][a-z\d+.-]*:|\/)/i.test(src)) {
      img.src = new URL(src, 'reader-asset://local/').href;
    } else img.removeAttribute('src');
  }
  document.getElementById('paper').replaceChildren(fragment);
  window.getSelection().removeAllRanges();
  applyMarks(id, marks || []);
  window.scrollTo(0,0);
}
function offsetIn(root, node, offset) {
  const prefix = document.createRange();
  prefix.selectNodeContents(root);
  prefix.setEnd(node,offset);
  return prefix.toString().length;
}
function currentExcerpt() {
  const root=document.getElementById('paper'), sel=getSelection();
  if (!sel.rangeCount || sel.isCollapsed) return null;
  const r=sel.getRangeAt(0);
  if (!root.contains(r.commonAncestorContainer)) return null;
  const start=offsetIn(root,r.startContainer,r.startOffset), length=r.toString().length;
  const el=r.startContainer.nodeType===Node.ELEMENT_NODE ? r.startContainer : r.startContainer.parentElement;
  const block=el.closest('p,li,td,th,blockquote,h1,h2,h3,h4,pre') || root;
  const offset=offsetIn(block,r.startContainer,r.startOffset), content=block.textContent;
  const example=new Intl.Segmenter('en',{granularity:'sentence'}).segment(content).containing(offset)?.segment || '';
  return {start,length,text:sel.toString().trim(),example:example.trim()};
}
function textNodes(root) {
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT), nodes=[];
  while(walker.nextNode()) nodes.push(walker.currentNode);
  return nodes;
}
function applyMarks(id,marks) {
  if (id!==documentID) return;
  const root=document.getElementById('paper'), selected=currentExcerpt();
  for(const el of root.querySelectorAll('[data-wy-mark]')) el.replaceWith(...el.childNodes);
  root.normalize();
  let pos=0;
  const sorted=marks.slice().sort((a,b)=>a.span.start-b.span.start);
  for(const node of textNodes(root)) {
    const value=node.data, end=pos+value.length;
    const overlaps=sorted.filter(m=>m.span.start<end && m.span.start+m.span.length>pos);
    if(overlaps.length) {
      const cuts=new Set([pos,end]);
      for(const m of overlaps) {cuts.add(Math.max(pos,m.span.start)); cuts.add(Math.min(end,m.span.start+m.span.length));}
      const points=[...cuts].sort((a,b)=>a-b), frag=document.createDocumentFragment();
      for(let i=1;i<points.length;i++) {
        const a=points[i-1], b=points[i], text=value.slice(a-pos,b-pos);
        const styles=overlaps.filter(m=>m.span.start<=a && m.span.start+m.span.length>=b).map(m=>m.kind);
        if(!styles.length) {frag.append(text);continue;}
        const span=document.createElement('span');span.dataset.wyMark='';span.className=styles.map(k=>'wy-'+k).join(' ');span.textContent=text;frag.append(span);
      }
      node.replaceWith(frag);
    }
    pos=end;
  }
  if(selected) {
    const r=document.createRange(), start=selected.start, end=start+selected.length;
    let i=0,found=false;
    for(const node of textNodes(root)) {
      const j=i+node.length;
      if(!found && start<j) {r.setStart(node,start-i);found=true;}
      if(found && end<=j) {r.setEnd(node,end-i);const sel=getSelection();sel.removeAllRanges();sel.addRange(r);break;}
      i=j;
    }
  }
}
function publishSelection() {
  const sel=getSelection(), passage=currentExcerpt();
  const rects = sel.rangeCount ? [...sel.getRangeAt(0).getClientRects()] : [];
  const r = rects.reverse().find(r => r.height && r.bottom > 0 && r.top < innerHeight);
  webkit.messageHandlers.selection.postMessage({id:documentID, ...(passage || {text:''}), x:r?.x||0, y:r?.y||0, w:r?.width||0, h:r?.height||0});
}
document.addEventListener('mouseup',publishSelection);
document.addEventListener('keyup',publishSelection);
document.addEventListener('click', e => { if(e.target.closest('a')) e.preventDefault(); });
