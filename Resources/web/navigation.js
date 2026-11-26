let findQuery='', findRanges=[], findIndex=-1;
function refreshDocumentSearch() {
  const text=indexPaper().map(item=>item.node.data).join('');
  findRanges=[];
  if(findQuery.trim()) {
    const escaped=findQuery.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    for(const match of text.matchAll(new RegExp(escaped,'giu'))) {
      const range=rangeAt({start:match.index,length:match[0].length});
      if(range)findRanges.push(range);
    }
  }
  findIndex=findRanges.length ? Math.max(0,Math.min(findIndex,findRanges.length-1)) : -1;
  paintSearch();
}
function paintSearch() {
  const all=new Highlight();
  for(const range of findRanges)all.add(range);
  CSS.highlights.set('hy-find',all);
  CSS.highlights.set('hy-find-current',new Highlight(...(findIndex>=0 ? [findRanges[findIndex]] : [])));
}
function findInPaper(id,query) {
  if(id!==documentID)return 0;
  findQuery=query;findIndex=0;refreshDocumentSearch();return findRanges.length;
}
function revealSearchResult(id,index) {
  if(id!==documentID||index<0||index>=findRanges.length)return;
  findIndex=index;paintSearch();
  const rect=findRanges[index].getBoundingClientRect();
  window.scrollBy(0,rect.top-innerHeight*0.32);
}
function captureBookmark(id) {
  if(id!==documentID||!paper().children.length)return null;
  const spot=webSpot(innerWidth/2,Math.min(80,innerHeight/4));
  const block=paper().children[spot.block];
  spot.x=0;spot.y=Math.max(0,Math.min(1,spot.y));
  return {point:spot,title:(block?.textContent.replace(/\s+/g,' ').trim()||'当前位置').slice(0,70)};
}
function revealBookmark(id,point) {
  if(id!==documentID)return;
  const target=viewportPoint(point);window.scrollBy(0,target.y-Math.min(80,innerHeight/4));
}
