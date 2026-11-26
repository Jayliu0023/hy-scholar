import AppKit
import PDFKit
import WebKit

enum BookmarkDestination:Codable {
    case pdf(PagePosition)
    case markdown(BlockPoint)
}
struct ReadingBookmark:Codable {
    var id=UUID().uuidString
    let title:String, destination:BookmarkDestination
    var order:Double {
        switch destination {
        case let .pdf(position):return Double(position.page)
        case let .markdown(point):return Double(point.block)+min(0.999,max(0,point.y))
        }
    }
    func sharesLocation(with other:Self)->Bool {
        switch (destination,other.destination) {
        case let (.pdf(a),.pdf(b)):return a.page==b.page
        case let (.markdown(a),.markdown(b)):return a.block==b.block
        default:return false
        }
    }
}
final class BookmarkStore {
    let folder:URL
    init(_ base:URL) {folder=base.appendingPathComponent("bookmarks",isDirectory:true)}
    private func file(_ document:String)->URL {folder.appendingPathComponent(document+".json")}
    func read(_ document:String)throws->[ReadingBookmark] {
        let url=file(document)
        do {return try JSONDecoder().decode([ReadingBookmark].self,from:Data(contentsOf:url))}
        catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError {return []}
    }
    @discardableResult func change(_ document:String,_ edit:(inout [ReadingBookmark])->Void)throws->[ReadingBookmark] {
        var items=try read(document);edit(&items)
        items.sort{$0.order<$1.order}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try JSONEncoder().encode(items).write(to:file(document),options:.atomic)
        return items
    }
}
private final class BookmarkRow:NSView {
    let bookmark:ReadingBookmark
    var jump:((String)->Void)?, remove:((String)->Void)?
    init(_ bookmark:ReadingBookmark) {
        self.bookmark=bookmark
        super.init(frame:.zero)
        let button=NSButton(title:bookmark.title,target:self,action:#selector(go))
        button.alignment = .left;button.isBordered=false;button.lineBreakMode = .byTruncatingTail
        button.toolTip=bookmark.title;button.setAccessibilityLabel("跳转书签："+bookmark.title)
        let trash=NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"删除书签")!,target:self,action:#selector(discard))
        trash.isBordered=false;trash.toolTip="删除书签"
        let line=row([button,NSView(),trash]);pad(line,in:self,3)
        trash.widthAnchor.constraint(equalToConstant:24).isActive=true
        heightAnchor.constraint(equalToConstant:34).isActive=true
    }
    required init?(coder:NSCoder){fatalError()}
    @objc private func go(){jump?(bookmark.id)}
    @objc private func discard(){remove?(bookmark.id)}
}
private final class BookmarkListView:NSView {override var isFlipped:Bool{true}}
final class BookmarkPanel:NSViewController {
    let add=NSButton(title:"添加当前位置",target:nil,action:nil)
    private let list=NSStackView(),empty=label("还没有书签",13)
    var create:(()->Void)?, jump:((String)->Void)?, remove:((String)->Void)?
    override func loadView() {
        view=NSView(frame:NSRect(x:0,y:0,width:300,height:350))
        let heading=label("书签",15,.semibold)
        add.bezelStyle = .rounded;add.image=NSImage(systemSymbolName:"bookmark.badge.plus",accessibilityDescription:nil)
        add.target=self;add.action = #selector(createNow)
        let head=row([heading,NSView(),add])
        let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        list.orientation = .vertical;list.alignment = .leading;list.spacing=2;list.translatesAutoresizingMaskIntoConstraints=false
        let container=BookmarkListView();scroll.documentView=container;container.translatesAutoresizingMaskIntoConstraints=false
        container.addSubview(list)
        NSLayoutConstraint.activate([container.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo:container.leadingAnchor),list.trailingAnchor.constraint(equalTo:container.trailingAnchor),
            list.topAnchor.constraint(equalTo:container.topAnchor),list.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        let stack=NSStackView(views:[head,scroll]);stack.orientation = .vertical;stack.spacing=10
        pad(stack,in:view,12)
        for v in [head,scroll] {v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        empty.textColor = .secondaryLabelColor
    }
    func show(_ bookmarks:[ReadingBookmark]) {
        loadViewIfNeeded()
        list.arrangedSubviews.forEach{list.removeArrangedSubview($0);$0.removeFromSuperview()}
        if bookmarks.isEmpty {list.addArrangedSubview(empty)}
        for bookmark in bookmarks {
            let line=BookmarkRow(bookmark)
            line.jump={ [weak self] in self?.jump?($0) };line.remove={ [weak self] in self?.remove?($0) }
            list.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:list.widthAnchor).isActive=true
        }
    }
    @objc private func createNow(){create?()}
}
final class BookmarkController:NSObject {
    unowned let reader:Reader
    let store:BookmarkStore, panel=BookmarkPanel(), popover=NSPopover()
    private(set) var items=[ReadingBookmark]()
    private var document:String?
    init(_ reader:Reader) {
        self.reader=reader;store=BookmarkStore(reader.library.base)
        super.init()
        popover.contentViewController=panel;popover.contentSize=NSSize(width:300,height:350);popover.behavior = .transient
        panel.create={ [weak self] in self?.addCurrent() }
        panel.jump={ [weak self] in self?.reveal($0) }
        panel.remove={ [weak self] in self?.remove($0) }
    }
    func bind() {
        popover.close();document=reader.entry?.id;reload()
    }
    private func reload() {
        do {items=try document.map{try store.read($0)} ?? [];panel.show(items)}
        catch {items=[];panel.show([]);reader.noteError(error)}
    }
    func toggle(from button:NSButton) {
        guard reader.entry != nil else{return}
        if popover.isShown {popover.close();return}
        reload();popover.show(relativeTo:button.bounds,of:button,preferredEdge:.maxY)
    }
    private func insert(_ bookmark:ReadingBookmark,document id:String) {
        guard document==id,reader.entry?.id==id else{return}
        do {
            items=try store.change(id){ items in
                if !items.contains(where:{$0.sharesLocation(with:bookmark)}) {items.append(bookmark)}
            }
            panel.show(items)
        } catch {reader.noteError(error)}
    }
    func addCurrent() {
        guard let id=document,id==reader.entry?.id else{return}
        if let pdf=reader.pdf,let position=PagePosition(bookmarking:pdf) {
            insert(ReadingBookmark(title:"第 \(position.page+1) 页",destination:.pdf(position)),document:id)
        } else if let md=reader.markdown {
            let revision=md.revision
            md.web.callAsyncJavaScript("return captureBookmark(id)",arguments:["id":revision],in:nil,in:.page){ [weak self,weak md] result in
                guard let self,md?.revision==revision,case let .success(value)=result,
                      let object=value as? [String:Any],let point=object["point"],let title=object["title"] as? String,
                      let data=try? JSONSerialization.data(withJSONObject:point),let anchor=try? JSONDecoder().decode(BlockPoint.self,from:data) else{return}
                self.insert(ReadingBookmark(title:title,destination:.markdown(anchor)),document:id)
            }
        }
    }
    func reveal(_ id:String) {
        guard let bookmark=items.first(where:{$0.id==id}),document==reader.entry?.id else{return}
        popover.close();reader.dismissBubble()
        switch bookmark.destination {
        case let .pdf(position):
            guard let pdf=reader.pdf,let doc=pdf.document,position.page>=0,position.page<doc.pageCount,let page=doc.page(at:position.page) else{return}
            pdf.autoScales=position.fitsWidth
            if !position.fitsWidth,position.scale.isFinite,position.scale>0 {pdf.scaleFactor=position.scale}
            pdf.layoutDocumentView();pdf.go(to:PDFDestination(page:page,at:position.point))
        case let .markdown(point):
            guard let md=reader.markdown,let data=try? JSONEncoder().encode(point),let object=try? JSONSerialization.jsonObject(with:data) else{return}
            md.web.callAsyncJavaScript("revealBookmark(id,point)",arguments:["id":md.revision,"point":object],in:nil,in:.page){_ in}
        }
        if let view=reader.activeTab?.view {reader.window.makeFirstResponder(view)}
    }
    func remove(_ id:String) {
        guard let document,document==reader.entry?.id else{return}
        do {items=try store.change(document){$0.removeAll{$0.id==id}};panel.show(items)}
        catch {reader.noteError(error)}
    }
}
