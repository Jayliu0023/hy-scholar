import AppKit
import PDFKit

final class MarginOverlay:NSView {
    var paint:((NSRect)->Void)?
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {paint?(dirtyRect)}
}

final class MarginController:NSObject {
    unowned let reader:Reader
    let store:NotebookStore, panel=MarginPanel(), overlay=MarginOverlay()
    private(set) var book=Notebook()
    private var documentID:String?
    private var observers=[NSObjectProtocol]()
    private var armed=false
    private var start:CGPoint?, end:CGPoint?, startPage:PDFPage?
    init(_ reader:Reader){
        self.reader=reader;store=NotebookStore(reader.library.base)
        super.init()
        overlay.wantsLayer=true
        overlay.paint={ [weak self] _ in self?.draw() }
        panel.reflow={ [weak self] in self?.invalidate() }
        panel.edit={ [weak self] id,text in self?.updateNote(id,render:false){$0.text=text} }
        panel.recolor={ [weak self] id,color in self?.updateNote(id){$0.ink=color} }
        panel.locate={ [weak self] id in self?.reveal(id) }
        panel.remove={ [weak self] id in self?.deleteNote(id) }
    }
    func install(in root:NSView){
        root.addSubview(overlay,positioned:.above,relativeTo:reader.navigationSplit); overlay.translatesAutoresizingMaskIntoConstraints=false
        let split=reader.split
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo:split.leadingAnchor),overlay.trailingAnchor.constraint(equalTo:split.trailingAnchor),
            overlay.topAnchor.constraint(equalTo:split.topAnchor),overlay.bottomAnchor.constraint(equalTo:split.bottomAnchor)])
    }
    func bind(){
        detach()
        documentID=reader.entry?.id
        do {book=try documentID.map{try store.read($0)} ?? Notebook()}
        catch {book=Notebook();reader.noteError(error)}
        if let pane=reader.markdown {pane.onGeometry={ [weak self] in self?.invalidate() }}
        func watch(_ name:Notification.Name,_ object:AnyObject){
            observers.append(NotificationCenter.default.addObserver(forName:name,object:object,queue:.main){ [weak self] _ in self?.invalidate() })
        }
        if let pdf=reader.pdf {
            watch(.PDFViewScaleChanged,pdf);watch(.PDFViewPageChanged,pdf)
            if let clip=pdf.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications=true;watch(NSView.boundsDidChangeNotification,clip)
            }
        }
        panel.scroll.contentView.postsBoundsChangedNotifications=true
        watch(NSView.boundsDidChangeNotification,panel.scroll.contentView)
        reader.canvas.postsFrameChangedNotifications=true;watch(NSView.frameDidChangeNotification,reader.canvas)
        refresh()
    }
    func detach(){
        cancelGesture()
        reader.markdown?.onGeometry=nil
        observers.forEach{NotificationCenter.default.removeObserver($0)};observers.removeAll()
    }
    func invalidate(){overlay.needsDisplay=true}
    private func refresh(){
        if let pane=reader.markdown {pane.notebook=book;pane.pushNotebook()}
        panel.show(book.notes);invalidate()
    }
    @discardableResult private func change(render:Bool=true,_ edit:(inout Notebook)->Void)->Bool {
        guard let id=documentID,id==reader.entry?.id else {return false}
        do {
            book=try store.change(id,edit)
            if render {refresh()} else {invalidate()}
            return true
        } catch {reader.noteError(error);return false}
    }
    func updateNote(_ id:String,render:Bool=true,_ edit:(inout MarginNote)->Void){
        change(render:render){ b in if let i=b.notes.firstIndex(where:{$0.id==id}) {edit(&b.notes[i])} }
    }
    private func deleteNote(_ id:String){
        guard let note=book.notes.first(where:{$0.id==id}) else{return}
        if note.text.isEmpty {change{$0.notes.removeAll{$0.id==id}};return}
        let doc=documentID, alert=NSAlert()
        alert.messageText="删除这条批注？";alert.addButton(withTitle:"取消");alert.addButton(withTitle:"删除")
        alert.beginSheetModal(for:reader.window){ [weak self] response in
            guard let self,response == .alertSecondButtonReturn,self.documentID==doc else{return}
            self.change{$0.notes.removeAll{$0.id==id}}
        }
    }
    private func add(_ note:MarginNote){
        guard change({$0.notes.append(note)}) else {return}
        if reader.side != .notes {reader.setSide(.notes)}
        panel.layoutSubtreeIfNeeded();panel.focus(note.id);invalidate()
    }
    func addText(_ passage:Excerpt) {
        guard let first=passage.spans.first else{return}
        var order=NoteOrder(page:first.page,offset:Double(first.start))
        if let pdf=reader.pdf,let page=pdf.document?.page(at:first.page),
           let sel=page.selection(for:first.range) {order=NoteOrder(page:first.page,offset:Double(-sel.bounds(for:page).maxY))}
        add(MarginNote(anchor:.text(passage.spans),quote:passage.text,order:order))
    }
    func addBoxNote(_ id:String){
        guard let region=book.regions.first(where:{$0.id==id}) else{return}
        let label:String
        if case let .pdf(page,_)=region.location {label="第 \(page+1) 页 · 框选区域"} else {label="框选区域"}
        add(MarginNote(anchor:.region(id),quote:label,order:region.order))
    }
    private var viewport:CGRect {reader.pageHost.convert(reader.pageHost.bounds,to:overlay).intersection(overlay.bounds)}
    private func rectForBox(_ region:MarkedRegion)->CGRect? {
        switch region.location {
        case let .pdf(index,rect):
            guard let pdf=reader.pdf,let page=pdf.document?.page(at:index) else{return nil}
            return overlay.convert(pdf.convert(rect,from:page),from:pdf)
        case .markdown:
            guard let md=reader.markdown,let b=md.geometry.boxes[region.id] else{return nil}
            return overlay.convert(md.rect(b),from:md.web)
        }
    }
    private func sourceRect(_ note:MarginNote)->CGRect? {
        switch note.anchor {
        case let .region(id):return book.regions.first{$0.id==id}.flatMap(rectForBox)
        case let .text(spans):
            if let pdf=reader.pdf,let doc=pdf.document {
                for span in spans {
                    guard let page=doc.page(at:span.page),pdf.visiblePages.contains(page),NSMaxRange(span.range)<=page.numberOfCharacters,
                          let selection=page.selection(for:span.range) else{continue}
                    for line in selection.selectionsByLine() {
                        let rect=overlay.convert(pdf.convert(line.bounds(for:page),from:page),from:pdf)
                        if rect.intersects(viewport) {return rect}
                    }
                }
            } else if let md=reader.markdown,let rects=md.geometry.notes[note.id] {
                return rects.map{overlay.convert(md.rect($0),from:md.web)}.first{$0.intersects(viewport)}
            }
            return nil
        }
    }
    func connector(_ note:MarginNote)->(CGPoint,CGPoint)? {
        guard reader.side == .notes, let raw=sourceRect(note),let card=panel.cards[note.id] else{return nil}
        let source=raw.intersection(viewport)
        let visible=card.visibleRect
        guard !source.isEmpty,!source.isNull,!visible.isEmpty else{return nil}
        let target=overlay.convert(CGPoint(x:card.bounds.minX,y:min(max(visible.minY+2,20),visible.maxY-2)),from:card)
        return (CGPoint(x:source.maxX,y:source.midY),target)
    }
    private func dash(_ path:NSBezierPath,_ ink:NoteInk){
        ink.color.setStroke();path.lineWidth=1.5;path.setLineDash([5,4],count:2,phase:0);path.stroke()
    }
    private func draw(){
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect:viewport).addClip()
        for box in book.regions {
            if let r=rectForBox(box),r.intersects(viewport){dash(NSBezierPath(rect:r),box.ink)}
        }
        if let a=start,let b=end {dash(NSBezierPath(rect:dragRect(a,b)),.gray)}
        NSGraphicsContext.restoreGraphicsState()
        guard reader.side == .notes else{return}
        for n in book.notes {
            guard let (from,to)=connector(n) else{continue}
            let span=max(12,(to.x-from.x)*0.38),p=NSBezierPath()
            p.move(to:from);p.curve(to:to,controlPoint1:CGPoint(x:from.x+span,y:from.y),controlPoint2:CGPoint(x:to.x-span,y:to.y))
            dash(p,n.ink)
            n.ink.color.setFill()
            NSBezierPath(ovalIn:CGRect(x:from.x-2,y:from.y-2,width:4,height:4)).fill()
            let arrow=NSBezierPath()
            arrow.move(to:to);arrow.line(to:CGPoint(x:to.x-5,y:to.y+2.8));arrow.line(to:CGPoint(x:to.x-5,y:to.y-2.8));arrow.close();arrow.fill()
        }
    }
    private func reveal(_ id:String){
        guard let note=book.notes.first(where:{$0.id==id}) else{return}
        if let md=reader.markdown {md.reveal(note);return}
        guard let pdf=reader.pdf,let doc=pdf.document else{return}
        switch note.anchor {
        case let .text(spans):
            if let s=spans.first,let page=doc.page(at:s.page),let sel=page.selection(for:s.range){pdf.go(to:sel)}
        case let .region(id):
            if let region=book.regions.first(where:{$0.id==id}),case let .pdf(i,rect)=region.location,let p=doc.page(at:i){pdf.go(to:rect,on:p)}
        }
        invalidate()
    }
    private func dragRect(_ a:CGPoint,_ b:CGPoint)->CGRect {
        CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
    }
    func cancelGesture(){
        if armed {NSCursor.pop()}
        armed=false;start=nil;end=nil;startPage=nil;invalidate()
    }
    func handle(_ e:NSEvent)->Bool {
        let flags=e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch e.type {
        case .keyDown where e.keyCode==49 && flags.contains(.shift) && flags.intersection([.command,.option,.control]).isEmpty:
            guard reader.activeTab != nil else{return false}
            if let responder=reader.window.firstResponder as? NSView,
               responder.isDescendant(of:reader.sideHost) || responder.isDescendant(of:reader.bubble) {return false}
            if !armed {armed=true;NSCursor.crosshair.push()};return true
        case .keyDown where e.keyCode==53 && (armed || start != nil):cancelGesture();return true
        case .keyUp where e.keyCode==49, .flagsChanged where !flags.contains(.shift):
            let consumed=armed && e.type == .keyUp
            if armed {armed=false;NSCursor.pop()}
            return consumed
        case .leftMouseDown where armed:
            guard reader.isDocumentClick(at:e.locationInWindow) else{return false}
            let pt=overlay.convert(e.locationInWindow,from:nil)
            if let pdf=reader.pdf {
                guard let p=pdf.page(for:pdf.convert(e.locationInWindow,from:nil),nearest:false) else{return false}
                startPage=p
            }
            reader.dismissBubble();start=pt;end=pt;invalidate();return true
        case .leftMouseDragged where start != nil:
            end=overlay.convert(e.locationInWindow,from:nil);invalidate();return true
        case .leftMouseUp where start != nil:
            finishBox(overlay.convert(e.locationInWindow,from:nil));return true
        default:return false
        }
    }
    private func finishBox(_ point:CGPoint){
        guard let a=start else{return}
        let rect=dragRect(a,point).intersection(viewport)
        let page=startPage
        start=nil;end=nil;startPage=nil;invalidate()
        guard !rect.isNull,rect.width>=5,rect.height>=5 else{return}
        if let pdf=reader.pdf,let doc=pdf.document,let page {
            let pageRect=pdf.convert(pdf.convert(rect,from:overlay),to:page).intersection(page.bounds(for:pdf.displayBox))
            guard !pageRect.isNull,!pageRect.isEmpty else{return}
            let index=doc.index(for:page)
            let area=MarkedRegion(location:.pdf(page:index,rect:pageRect),order:NoteOrder(page:index,offset:Double(-pageRect.maxY)))
            change{$0.regions.append(area)}
        } else if let md=reader.markdown {
            let id=documentID, a=md.cssPoint(rect.origin,from:overlay), b=md.cssPoint(CGPoint(x:rect.maxX,y:rect.maxY),from:overlay)
            md.newBox(from:a,to:b){[weak self] box in
                guard let self,self.documentID==id,let box else{return}
                self.change{$0.regions.append(box)}
            }
        }
    }
    func boxAt(_ windowPoint:CGPoint)->MarkedRegion? {
        let point=overlay.convert(windowPoint,from:nil)
        return book.regions.reversed().compactMap { box -> (MarkedRegion,CGFloat)? in
            guard let rect=rectForBox(box),rect.insetBy(dx:-3,dy:-3).contains(point) else{return nil}
            return (box,rect.width*rect.height)
        }.min{$0.1<$1.1}?.0
    }
    func boxMenu(_ box:MarkedRegion)->NSMenu {
        let menu=NSMenu(), doc=documentID
        func action(_ title:String,_ perform:@escaping ()->Void)->NSMenuItem {
            ActionItem(title){[weak self] in guard self?.documentID==doc else{return};perform()}
        }
        menu.addItem(action("添加 Note"){[weak self] in self?.addBoxNote(box.id)})
        let colors=NSMenuItem(title:"框线颜色",action:nil,keyEquivalent:"");let sub=NSMenu()
        for ink in NoteInk.allCases {
            let item=action(ink.title){[weak self] in self?.change{ b in
                if let i=b.regions.firstIndex(where:{$0.id==box.id}) {b.regions[i].ink=ink}
            }}
            item.state=ink==box.ink ? .on:.off;sub.addItem(item)
        }
        colors.submenu=sub;menu.addItem(colors)
        let discard=action("删除框选"){[weak self] in self?.change{ b in
            if !b.notes.contains(where:{if case .region(box.id)=$0.anchor{return true};return false}) {b.regions.removeAll{$0.id==box.id}}
        }}
        if book.notes.contains(where:{if case .region(box.id)=$0.anchor{return true};return false}) {discard.action=nil;discard.toolTip="请先删除此框关联的批注"}
        menu.addItem(discard);return menu
    }
    func markedExcerpt(at location:CGPoint)->Excerpt? {
        if let pdf=reader.pdf,let doc=pdf.document {
            let pt=pdf.convert(location,from:nil)
            guard let page=pdf.page(for:pt,nearest:false) else{return nil}
            let q=pdf.convert(pt,to:page),idx=doc.index(for:page)
            let marks=reader.notes.data.marks[documentID ?? ""] ?? []
            for m in marks.reversed() where m.span.page==idx {
                guard let s=page.selection(for:m.span.range),s.selectionsByLine().contains(where:{$0.bounds(for:page).contains(q)}) else{continue}
                return Excerpt(text:oneLine(s.string ?? ""),example:sentence(in:page.string ?? "",around:m.span.range),spans:[m.span])
            }
            if let ann=page.annotation(at:q),["highlight","underline","strikeout"].contains((ann.type ?? "").lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"/"))),
               let sel=page.selection(for:ann.bounds) {
                let ranges=(0..<sel.numberOfTextRanges(on:page)).map{sel.range(at:$0,on:page)}.filter{$0.location != NSNotFound && $0.length>0}
                if let first=ranges.first {return Excerpt(text:oneLine(sel.string ?? ""),example:sentence(in:page.string ?? "",around:first),spans:ranges.map{Passage(page:idx,start:$0.location,length:$0.length)})}
            }
        } else if let md=reader.markdown {
            let pt=md.web.convert(location,from:nil)
            if let m=md.geometry.marks.last(where:{$0.rects.contains{md.rect($0).contains(pt)}}) {
                return Excerpt(text:m.text,example:"",spans:[Passage(page:0,start:m.start,length:m.length)])
            }
        }
        return nil
    }
}
private final class ActionItem:NSMenuItem {
    private let handler:()->Void
    init(_ title:String,_ handler:@escaping ()->Void){
        self.handler=handler;super.init(title:title,action:#selector(runItem),keyEquivalent:"");target=self
    }
    required init(coder:NSCoder){fatalError()}
    @objc private func runItem(){handler()}
}
