import WebKit

struct WebBounds:Decodable {let x,y,w,h:CGFloat}
struct WebMarkedText:Decodable {let start,length:Int;let text:String;let rects:[WebBounds]}
struct WebNoteGeometry:Decodable {
    var notes=[String:[WebBounds]](), boxes=[String:WebBounds](), marks=[WebMarkedText]()
}
private struct WebBoxResult:Decodable {let start,end:BlockPoint;let offset:Double}
private func object(_ point:BlockPoint)->[String:Any] {["block":point.block,"x":point.x,"y":point.y]}
extension MarkdownPane {
    func receiveGeometry(_ body:Any) {
        guard let dict=body as? [String:Any],dict["id"] as? String==revision,
              let data=try? JSONSerialization.data(withJSONObject:dict),
              let result=try? JSONDecoder().decode(WebNoteGeometry.self,from:data) else {return}
        geometry=result; onGeometry?()
    }
    func rect(_ b:WebBounds)->CGRect {
        CGRect(x:b.x,y:web.isFlipped ? b.y : web.bounds.height-b.y-b.h,width:b.w,height:b.h)
    }
    func cssPoint(_ p:CGPoint,from view:NSView)->CGPoint {
        let pt=web.convert(p,from:view)
        return CGPoint(x:pt.x,y:web.isFlipped ? pt.y : web.bounds.height-pt.y)
    }
    func pushNotebook(){
        guard rendered else {return}
        let notes:[[String:Any]]=notebook.notes.compactMap{
            guard case let .text(spans)=$0.anchor else {return nil}
            return ["id":$0.id,"spans":spans.map{["start":$0.start,"length":$0.length]}]
        }
        let boxes:[[String:Any]]=notebook.regions.compactMap{
            guard case let .markdown(a,b)=$0.location else {return nil}
            return ["id":$0.id,"start":object(a),"end":object(b)]
        }
        web.callAsyncJavaScript("setMargins(id,spec)",arguments:["id":revision,"spec":["notes":notes,"regions":boxes]],in:nil,in:.page){_ in}
    }
    func newBox(from a:CGPoint,to b:CGPoint,completion:@escaping (MarkedRegion?)->Void){
        let id=revision
        web.callAsyncJavaScript("return makeMarginBox(id,x1,y1,x2,y2)",arguments:["id":id,"x1":a.x,"y1":a.y,"x2":b.x,"y2":b.y],in:nil,in:.page){ [weak self] result in
            guard self?.revision==id,case let .success(value)=result,let dict=value as? [String:Any],
                  let d=try? JSONSerialization.data(withJSONObject:dict),let box=try? JSONDecoder().decode(WebBoxResult.self,from:d) else {completion(nil);return}
            completion(MarkedRegion(location:.markdown(box.start,box.end),order:NoteOrder(page:0,offset:box.offset)))
        }
    }
    func reveal(_ note:MarginNote) {
        var args:[String:Any]
        switch note.anchor {
        case let .text(spans):args=["spans":spans.map{["start":$0.start,"length":$0.length]}]
        case let .region(id):
            guard let box=notebook.regions.first(where:{$0.id==id}),case let .markdown(a,b)=box.location else {return}
            args=["start":object(a),"end":object(b)]
        }
        web.callAsyncJavaScript("revealMargin(id,note)",arguments:["id":revision,"note":args],in:nil,in:.page){_ in}
    }
}
