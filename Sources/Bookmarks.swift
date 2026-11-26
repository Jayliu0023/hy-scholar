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
    let tabs=NSSegmentedControl(labels:["目录","我的书签"],trackingMode:.selectOne,target:nil,action:nil)
    let directory=OutlineList()
    private let bookmarkView=NSView(),content=NSView()
    private let list=NSStackView(),empty=label("还没有书签",13)
    var create:(()->Void)?, jump:((String)->Void)?, remove:((String)->Void)?
    override func loadView() {
        view=NSView(frame:NSRect(x:0,y:0,width:360,height:480))
        let heading=label("书签与目录",15,.semibold)
        add.bezelStyle = .rounded;add.image=NSImage(systemSymbolName:"bookmark.badge.plus",accessibilityDescription:nil)
        add.target=self;add.action = #selector(createNow)
        let head=row([heading,NSView()])
        tabs.target=self;tabs.action = #selector(selectTab);tabs.selectedSegment=0
        tabs.setAccessibilityLabel("目录与我的书签")
        let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
        list.orientation = .vertical;list.alignment = .leading;list.spacing=2;list.translatesAutoresizingMaskIntoConstraints=false
        let container=BookmarkListView();scroll.documentView=container;container.translatesAutoresizingMaskIntoConstraints=false
        container.addSubview(list)
        NSLayoutConstraint.activate([container.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo:container.leadingAnchor),list.trailingAnchor.constraint(equalTo:container.trailingAnchor),
            list.topAnchor.constraint(equalTo:container.topAnchor),list.bottomAnchor.constraint(equalTo:container.bottomAnchor)])
        let manual=NSStackView(views:[row([NSView(),add]),scroll]);manual.orientation = .vertical;manual.spacing=8
        pad(manual,in:bookmarkView)
        for v in manual.arrangedSubviews {v.widthAnchor.constraint(equalTo:manual.widthAnchor).isActive=true}
        pad(directory,in:content);pad(bookmarkView,in:content)
        let stack=NSStackView(views:[head,tabs,content]);stack.orientation = .vertical;stack.spacing=10
        pad(stack,in:view,12)
        for v in [head,tabs,content] {v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        empty.textColor = .secondaryLabelColor
        selectTab()
    }
    func openDirectory(){loadViewIfNeeded();tabs.selectedSegment=0;selectTab()}
    @objc func selectTab(){directory.isHidden=tabs.selectedSegment != 0;bookmarkView.isHidden=tabs.selectedSegment != 1}
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
    let store:BookmarkStore, panel=BookmarkPanel()
    private(set) var items=[ReadingBookmark]()
    private(set) var outline=[OutlineNode]()
    private var document:String?
    private var outlineRevision=0
    init(_ reader:Reader) {
        self.reader=reader;store=BookmarkStore(reader.library.base)
        super.init()
        panel.create={ [weak self] in self?.addCurrent() }
        panel.jump={ [weak self] in self?.reveal($0) }
        panel.remove={ [weak self] in self?.remove($0) }
        panel.directory.jump={ [weak self] in self?.revealSection($0) }
    }
    func bind() {
        document=reader.entry?.id;reload();loadOutline()
    }
    private func reload() {
        do {items=try document.map{try store.read($0)} ?? [];panel.show(items)}
        catch {items=[];panel.show([]);reader.noteError(error)}
    }
    func openDirectory() {reload();panel.openDirectory();loadOutline()}
    private func loadOutline() {
        outlineRevision += 1
        let version=outlineRevision,id=document
        outline=[]
        if let pdf=reader.pdf,let doc=pdf.document {
            outline=OutlineNode.pdf(doc)
            panel.directory.show(outline,message:"此 PDF 未包含文档目录。可在「我的书签」中保存阅读位置。")
        } else if let md=reader.markdown {
            panel.directory.show([],message:md.contentReady ? "正在读取目录…":"正在加载文档…")
            guard md.contentReady else{return}
            md.web.callAsyncJavaScript("return documentOutline(id)",arguments:["id":md.revision],in:nil,in:.page){ [weak self] result in
                guard let self,self.document==id,self.outlineRevision==version else{return}
                guard case let .success(value)=result,let data=try? JSONSerialization.data(withJSONObject:value as Any),
                      let headings=try? JSONDecoder().decode([WebHeading].self,from:data) else {
                    self.panel.directory.show([],message:"无法读取文档目录。");return
                }
                self.outline=OutlineNode.markdown(headings)
                self.panel.directory.show(self.outline,message:"此文档没有标题。可在「我的书签」中保存阅读位置。")
            }
        } else {panel.directory.show([],message:"打开文档后查看目录。")}
    }
    func contentReady(){if reader.markdown != nil {loadOutline()}}
    func revealSection(_ section:OutlineNode) {
        guard document==reader.entry?.id else{return}
        func contains(_ nodes:[OutlineNode])->Bool {nodes.contains{$0 === section || contains($0.children)}}
        guard contains(outline),let target=section.target else{return}
        reader.dismissBubble()
        switch target {
        case let .pdf(index,point):
            guard let pdf=reader.pdf,let doc=pdf.document,index>=0,index<doc.pageCount,let page=doc.page(at:index) else{return}
            pdf.go(to:PDFDestination(page:page,at:point))
        case let .markdown(start):
            guard let md=reader.markdown else{return}
            md.web.callAsyncJavaScript("revealOutline(id,start)",arguments:["id":md.revision,"start":start],in:nil,in:.page){_ in}
        }
        if let view=reader.activeTab?.view {reader.window.makeFirstResponder(view)}
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
        reader.dismissBubble()
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
