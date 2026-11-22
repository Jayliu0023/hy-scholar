import AppKit
import PDFKit
import UniformTypeIdentifiers

let accent = NSColor(calibratedRed:0.09, green:0.46, blue:0.32, alpha:1)
func pad(_ child: NSView, in parent: NSView, _ inset: CGFloat = 0) {
    parent.addSubview(child)
    child.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),
        child.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),
        child.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),
        child.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
}
func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSTextField {
    let v = NSTextField(labelWithString:text); v.font = .systemFont(ofSize:size,weight:weight); v.lineBreakMode = .byTruncatingMiddle
    return v
}
func control(_ title: String, _ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title:title,target:target,action:action)
    b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
    b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading; b.bezelStyle = .rounded
    b.toolTip = tip; b.setAccessibilityLabel(tip); return b
}
func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views:views); s.orientation = .horizontal; s.alignment = .centerY; s.spacing = spacing; return s
}
func fill(_ view:NSView,in parent:NSView) {
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = parent.bounds; view.autoresizingMask = [.width,.height]; parent.addSubview(view)
}

final class Card: NSView {
    let original = label("",12), title = label("划词翻译",13,.semibold)
    let output = NSTextView()
    let spinner = NSProgressIndicator()
    var pin: (() -> Void)?, dismiss: (() -> Void)?
    let head = DragHeader()
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1
        do {
            let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width:0,height:-2); self.shadow = shadow
        }
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        output.isEditable = false; output.isSelectable = true; output.drawsBackground = false
        output.font = .systemFont(ofSize:16); output.textColor = .labelColor
        output.textContainerInset = NSSize(width:0,height:2); output.textContainer?.lineFragmentPadding = 0
        output.isVerticallyResizable = true; output.isHorizontallyResizable = false
        output.textContainer?.widthTracksTextView = true; output.autoresizingMask = [.width]
        scroll.documentView = output
        original.textColor = .secondaryLabelColor; original.lineBreakMode = .byTruncatingTail
        original.setContentCompressionResistancePriority(.defaultLow, for:.horizontal)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let glyph = NSImageView(image:NSImage(systemSymbolName:"character.book.closed",accessibilityDescription:nil)!)
        glyph.contentTintColor = accent
        let space = NSView()
        var actions: [NSView] = [glyph,title,spinner,space]
        actions.append(control("", "sidebar.right","将此原文送到右侧翻译",self,#selector(pinNow)))
        actions.append(control("", "xmark","关闭译文",self,#selector(closeNow)))
        head.orientation = .horizontal; head.alignment = .centerY; head.spacing=7
        actions.forEach {head.addArrangedSubview($0)}
        head.toolTip="拖动此处移动浮窗"
        let stack = NSStackView(views:[head,original,scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        pad(stack,in:self,14)
        for v in [head,original,scroll] { v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow,for:.vertical)
        updateColors()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    func show(_ source:String,_ result:String,_ busy:Bool,_ error:Bool) {
        original.stringValue = source; original.toolTip = source; original.isHidden = source.isEmpty
        let str = source.isEmpty ? "选中正文中的英文，即可在这里查看译文。" : (busy && result.isEmpty ? "正在本机翻译…" : result)
        if output.string != str { output.string = str }
        output.textColor = error ? .systemRed : (source.isEmpty || (busy && result.isEmpty) ? .secondaryLabelColor : .labelColor)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    @objc func pinNow() { pin?() }
    @objc func closeNow() { dismiss?() }
}

struct DocumentEntry: Codable {
    let id: String
    let name: String
    let original: URL
}
final class Library {
    let base: URL
    private(set) var entries: [DocumentEntry] = []
    init(root:URL? = nil) {
        base = root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("文译阅读器",isDirectory:true)
        if let d = try? Data(contentsOf:base.appendingPathComponent("library.json")) {
            entries = (try? JSONDecoder().decode([DocumentEntry].self,from:d)) ?? []
        }
    }
    func url(_ entry: DocumentEntry) -> URL { base.appendingPathComponent("files").appendingPathComponent(entry.id).appendingPathComponent(entry.name) }
    func add(_ original:URL) throws -> DocumentEntry {
        if let existing=entries.first(where:{ item in
            let copy=url(item).standardizedFileURL
            return original.standardizedFileURL==copy || (item.original.standardizedFileURL==original.standardizedFileURL && FileManager.default.contentsEqual(atPath:original.path,andPath:copy.path))
        }) {try remember(existing); return existing}
        let entry = DocumentEntry(id:UUID().uuidString,name:original.lastPathComponent,original:original)
        let dest = url(entry), folder = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            try FileManager.default.copyItem(at:original,to:dest)
            try remember(entry)
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
        return entry
    }
    func remember(_ entry:DocumentEntry) throws {
        let next = [entry] + entries.filter{$0.id != entry.id}
        try JSONEncoder().encode(next).write(to:base.appendingPathComponent("library.json"),options:.atomic)
        entries = next
    }
}

final class DropWindow: NSWindow, NSDraggingDestination {
    var drop: (([URL])->Void)?
    func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { dragURLs(sender).isEmpty ? [] : .copy }
    func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        let files=dragURLs(sender)
        guard !files.isEmpty else {return false}
        drop?(files); return true
    }
    private func dragURLs(_ sender:NSDraggingInfo)->[URL] {
        let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        return urls.filter{["pdf","md","markdown"].contains($0.pathExtension.lowercased())}
    }
}

final class Reader: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    enum Side { case none, translation, words, notes, terminal }
    let window: DropWindow, library: Library
    let tabBar = DocumentTabBar()
    private var tabHeight:NSLayoutConstraint!
    private(set) var tabs=[ReadingTab]()
    private(set) var activeTab:ReadingTab?
    var entry:DocumentEntry? { activeTab?.entry }
    var pdf:PDFView? { activeTab?.pdf }
    var markdown:MarkdownPane? { activeTab?.markdown }
    let canvas = NSView(), pageHost = NSView(), split = NSSplitView(), sideHost = NSView()
    let empty = NSView(), manual=ManualPanel(), bubble=Card(), wordsPanel=WordPanel()
    let notes:ReadingNotes
    lazy var margins=MarginController(self)
    var pendingWords=Set<String>(), wordErrors=[String:String]()
    private var draggedTop:NSPoint?
    let metadata = label("",11)
    let engine = Translator()
    private var translateButton: NSButton!, terminalButton: NSButton!, wordsButton:NSButton!, notesButton:NSButton!
    private(set) var terminal: TerminalPane?
    private(set) var side: Side = .none
    private(set) var source = "", result = "", busy = false, failed = false
    private var anchor = NSRect.zero
    private var pending: DispatchWorkItem?
    private var sidebarWidth: CGFloat = 366
    private var revision = 0
    private var lastNotified = ""
    private var lastRanges=[Passage]()
    private(set) var translatedRanges=[Passage]()
    private var keyMonitor:Any?
    var recentChanged: (() -> Void)?

    init(library:Library = Library()) {
        self.library = library; notes=ReadingNotes(base:library.base)
        window = DropWindow(contentRect:NSRect(x:0,y:0,width:1100,height:730),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "文译阅读器"; window.minSize = NSSize(width:740,height:440)
        window.isReleasedWhenClosed=false; window.delegate=self
        window.setFrameAutosaveName("WenyiMain"); if window.frame.origin == .zero { window.center() }
        window.registerForDraggedTypes([.fileURL]); window.drop = { [weak self] in self?.openFiles($0) }
        let root=NSView(); window.contentView=root
        let openButton=control("打开","folder","打开 PDF 或 Markdown（⌘O）",self,#selector(choose))
        translateButton=control("翻译","text.cursor","独立翻译",self,#selector(toggleTranslation))
        wordsButton=control("收藏","star","收藏词汇",self,#selector(toggleWords))
        notesButton=control("Note","note.text","文献笔记 · Shift＋空格拖动框选",self,#selector(toggleNotes))
        terminalButton=control("终端","terminal","右侧终端（⌃\u{60}）",self,#selector(toggleTerminal))
        metadata.textColor = .secondaryLabelColor
        let toolbar=row([openButton,metadata,NSView(),translateButton,wordsButton,notesButton,terminalButton],spacing:12)
        toolbar.edgeInsets=NSEdgeInsets(top:0,left:14,bottom:0,right:14)
        toolbar.translatesAutoresizingMaskIntoConstraints=false; root.addSubview(toolbar)
        tabBar.translatesAutoresizingMaskIntoConstraints=false; root.addSubview(tabBar)
        tabBar.select = { [weak self] id in self?.selectTab(id) }
        tabBar.close = { [weak self] id in self?.closeTab(id) }
        tabBar.add = { [weak self] in self?.choose() }
        tabHeight=tabBar.heightAnchor.constraint(equalToConstant:0)
        tabBar.isHidden=true
        let rule=NSBox(); rule.boxType = .separator; root.addSubview(rule); rule.translatesAutoresizingMaskIntoConstraints=false
        split.isVertical=true; split.dividerStyle = .thin; split.delegate=self; root.addSubview(split); split.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo:root.topAnchor),toolbar.leadingAnchor.constraint(equalTo:root.leadingAnchor),toolbar.trailingAnchor.constraint(equalTo:root.trailingAnchor),toolbar.heightAnchor.constraint(equalToConstant:50),tabBar.topAnchor.constraint(equalTo:toolbar.bottomAnchor),tabBar.leadingAnchor.constraint(equalTo:root.leadingAnchor),tabBar.trailingAnchor.constraint(equalTo:root.trailingAnchor),tabHeight,rule.topAnchor.constraint(equalTo:tabBar.bottomAnchor),rule.leadingAnchor.constraint(equalTo:root.leadingAnchor),rule.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.topAnchor.constraint(equalTo:rule.bottomAnchor),split.bottomAnchor.constraint(equalTo:root.bottomAnchor),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor)])
        split.addArrangedSubview(canvas); fill(pageHost,in:canvas)
        canvas.wantsLayer=true; canvas.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
        let symbol=NSImageView(image:NSImage(systemSymbolName:"book.pages",accessibilityDescription:nil) ?? NSImage())
        symbol.contentTintColor=accent; symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:44,weight:.light)
        let heading=label("打开文献",25,.semibold), hint=label("将 PDF 或 Markdown 拖到这里",14)
        hint.textColor = .secondaryLabelColor
        let pick=control("选择文件…","folder","选择文件",self,#selector(choose)); pick.controlSize = .large
        let intro=NSStackView(views:[symbol,heading,hint,pick]); intro.orientation = .vertical; intro.spacing=13; intro.alignment = .centerX
        empty.addSubview(intro); intro.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([intro.centerXAnchor.constraint(equalTo:empty.centerXAnchor),intro.centerYAnchor.constraint(equalTo:empty.centerYAnchor,constant:-14)])
        fill(empty,in:pageHost)
        margins.install(in:root)
        NotificationCenter.default.addObserver(self,selector:#selector(pdfSelection(_:)),name:.PDFViewSelectionChanged,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(pdfPageChanged(_:)),name:.PDFViewPageChanged,object:nil)
        bubble.head.drag = { [weak self] dx,dy in
            guard let self else {return}
            self.draggedTop=NSPoint(x:self.bubble.frame.minX+dx,y:self.bubble.frame.maxY+dy); self.placeBubble()
        }
        bubble.pin = { [weak self] in
            guard let self,!self.source.isEmpty else {return}
            let source=self.source, translated = !self.busy && !self.failed && !self.result.isEmpty ? self.result:nil
            self.engine.cancel("manual"); self.manual.replace(with:source,translation:translated)
            self.setSide(.translation); self.dismissBubble()
            if translated==nil {self.manual.run()} else {self.saveDraft()}
        }
        bubble.dismiss = { [weak self] in self?.draggedTop=nil; self?.dismissBubble() }
        manual.submit = { [weak self] in self?.translateManual($0) }
        manual.edited = { [weak self] in self?.engine.cancel("manual") }
        if let d=try? Data(contentsOf:library.base.appendingPathComponent("draft.json")),
           let draft=try? JSONDecoder().decode(Draft.self,from:d) {manual.restore(draft)}
        wordsPanel.remove = { [weak self] in self?.removeWord($0) }
        wordsPanel.retry = { [weak self] in self?.completeWord($0) }
        keyMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseDragged,.leftMouseUp,.rightMouseDown]) { [weak self] e in
            guard let r=self, e.window === r.window else { return e }
            if r.margins.handle(e) {return nil}
            if (e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))) && r.popupSelection(e) {return nil}
            if e.type == .keyDown && e.keyCode==48 && e.modifierFlags.contains(.control) && !r.tabs.isEmpty {
                r.stepTab(e.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            }
            if e.type == .keyDown && e.keyCode==53 && r.bubble.superview != nil { r.dismissBubble(); return nil }
            if e.type == .leftMouseDown, r.bubble.superview != nil || r.pending != nil,
               r.isDocumentClick(at:e.locationInWindow) {
                r.dismissBubble()
            }
            return e
        }


    }

    @objc func choose() {
        let p=NSOpenPanel(); p.allowedContentTypes=[.pdf, UTType(filenameExtension:"md") ?? .plainText, UTType(filenameExtension:"markdown") ?? .plainText]
        p.canChooseDirectories=false; p.allowsMultipleSelection=true
        p.beginSheetModal(for:window) { [weak self] response in
            if response == .OK { self?.openFiles(p.urls) }
        }
    }
    func open(_ url:URL) { openFiles([url]) }

    private func ensureTab(_ item:DocumentEntry)->ReadingTab {
        if let existing=tabs.first(where:{$0.entry.id==item.id}) {return existing}
        let tab=ReadingTab(item); tabs.append(tab); return tab
    }
    func openFiles(_ urls:[URL]) {
        var first:ReadingTab?, errors=[String]()
        for url in urls {
            do {
                switch url.pathExtension.lowercased() {
                case "pdf":
                    guard let doc=PDFDocument(url:url), doc.pageCount>0, !doc.isLocked else {
                        throw problem("无法读取该 PDF，请检查文件是否损坏或已加密。")
                    }
                case "md","markdown": _ = try String(contentsOf:url,encoding:.utf8)
                default: throw problem("请选择 PDF 或 Markdown 文件。")
                }
                let tab=ensureTab(try library.add(url))
                if first==nil {first=tab}
            } catch {errors.append(url.lastPathComponent+" · "+error.localizedDescription)}
        }
        if let first { selectTab(first.entry.id); recentChanged?() }
        if !errors.isEmpty {alert(errors.joined(separator:"\n"))}
    }

    func restore(_ item:DocumentEntry) {
        do {
            try library.remember(item)
            let tab=ensureTab(item); selectTab(tab.entry.id); recentChanged?()
        } catch {alert(error.localizedDescription)}
    }
    private var sessionURL:URL { library.base.appendingPathComponent("tabs.json") }

    func restoreSession(openLast:Bool=true) {
        guard let bytes=try? Data(contentsOf:sessionURL),
              let session=try? JSONDecoder().decode(TabSession.self,from:bytes) else {
            if openLast, let last=library.entries.first {restore(last)}
            return
        }
        var seen=Set<String>()
        let items=Dictionary(library.entries.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        tabs=session.tabs.compactMap { state in
            guard seen.insert(state.id).inserted, let item=items[state.id],
                  FileManager.default.fileExists(atPath:library.url(item).path) else {return nil}
            return ReadingTab(item,position:state.position)
        }
        let index=tabs.firstIndex(where:{$0.entry.id==session.activeID}) ?? 0
        activateNeighbor(at:index)
        updateTabBar()
    }
    private func saveSession() {
        if let tab=activeTab,let view=tab.pdf {tab.position=PagePosition(view) ?? tab.position}
        let session=TabSession(tabs:tabs.map{SavedTab(id:$0.entry.id,position:$0.position)},activeID:entry?.id)
        do {
            try FileManager.default.createDirectory(at:library.base,withIntermediateDirectories:true)
            try JSONEncoder().encode(session).write(to:sessionURL,options:.atomic)
        } catch {noteError(error)}
    }
    private func layoutTabBar() {
        tabBar.isHidden=tabs.isEmpty
        tabHeight.constant=tabs.isEmpty ? 0 : 34
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func updateTabBar() {
        layoutTabBar()
        tabBar.show(tabs.map(\.entry),activeID:entry?.id)
    }
    func selectTab(_ id:String) {
        guard let tab=tabs.first(where:{$0.entry.id==id}) else {return}
        do { try activate(tab) }
        catch {
            tabs.removeAll{$0 === tab}
            if activeTab==nil {activateNeighbor(at:0)}
            alert(error.localizedDescription)
        }
        updateTabBar(); saveSession()
    }
    func stepTab(_ offset:Int) {
        guard !tabs.isEmpty,let index=tabs.firstIndex(where:{$0 === activeTab}) else {return}
        selectTab(tabs[(index+offset+tabs.count)%tabs.count].entry.id)
    }
    @objc func nextTab() {stepTab(1)}
    @objc func previousTab() {stepTab(-1)}
    @objc func closeCurrentTab() {
        if let id=entry?.id {closeTab(id)} else {window.performClose(nil)}
    }
    func closeTab(_ id:String) {
        guard let index=tabs.firstIndex(where:{$0.entry.id==id}) else {return}
        let removed=tabs.remove(at:index)
        removed.view?.removeFromSuperview()
        if removed === activeTab {activateNeighbor(at:index)}
        updateTabBar(); saveSession()
    }
    private func activateNeighbor(at index:Int) {
        while !tabs.isEmpty {
            let next=min(index,tabs.count-1)
            do {try activate(tabs[next]); return} catch {tabs.remove(at:next)}
        }
        clear(); activeTab=nil; draggedTop=nil; margins.bind()
        empty.isHidden=false; metadata.stringValue=""; window.title="文译阅读器"
    }
    private func activate(_ tab:ReadingTab) throws {
        if activeTab === tab {return}
        layoutTabBar()
        let firstVisit=tab.view==nil
        if firstVisit {
            let url=library.url(tab.entry)
            if url.pathExtension.lowercased()=="pdf" {
                guard let doc=PDFDocument(url:url),doc.pageCount>0,!doc.isLocked else {throw problem("无法读取 "+tab.entry.name)}
                let view=PDFView(frame:pageHost.bounds)
                view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.displaysPageBreaks=true
                view.autoScales=true; view.document=doc; tab.pdf=view
            } else {
                let text=try String(contentsOf:url,encoding:.utf8), pane=MarkdownPane()
                pane.selection = { [weak self,weak pane] text,rect in
                    guard let self,let pane,self.markdown === pane else {return}
                    self.selected(text,pane.web.convert(rect,to:self.canvas))
                }
                pane.set(text,directory:tab.entry.original.deletingLastPathComponent(),marks:notes.data.marks[tab.entry.id] ?? [])
                tab.markdown=pane
            }
        }
        if let old=activeTab,let view=old.pdf {old.position=PagePosition(view) ?? old.position}
        // A tab click leaves the visible translation, including its stream, on screen.
        resetSelectionTracking()
        translatedRanges=[]
        if bubble.superview == nil { draggedTop=nil }
        margins.detach()
        activeTab?.view?.isHidden=true; empty.isHidden=true; activeTab=tab
        let view=tab.view!
        if firstVisit {fill(view,in:pageHost)}
        view.isHidden=false
        if let pdf=tab.pdf,let doc=pdf.document {
            if firstVisit {
                window.contentView?.layoutSubtreeIfNeeded(); pdf.autoScales=true; pdf.layoutDocumentView()
                let position=tab.position
                if let position,!position.fitsWidth,position.scale.isFinite,position.scale>0 {
                    pdf.autoScales=false; pdf.scaleFactor=position.scale; pdf.layoutDocumentView()
                }
                let index=min(max(0,position?.page ?? 0),doc.pageCount-1)
                if let page=doc.page(at:index) {
                    let box=page.bounds(for:pdf.displayBox)
                    pdf.go(to:PDFDestination(page:page,at:position?.point ?? NSPoint(x:box.minX,y:box.maxY)))
                }
                redrawMarks()
            }
            updatePageLabel()
        } else {metadata.stringValue="Markdown"}
        window.title=tab.entry.name+" · 文译阅读器"
        window.makeFirstResponder(view)
        margins.bind()
    }
    private func problem(_ msg:String)->NSError { NSError(domain:"Wenyi",code:1,userInfo:[NSLocalizedDescriptionKey:msg]) }
    private func alert(_ message:String) { let a=NSAlert(); a.messageText="无法打开文献"; a.informativeText=message; a.beginSheetModal(for:window) }
    @objc private func pdfPageChanged(_ note:Notification) {
        if let view=note.object as? PDFView,view === pdf {updatePageLabel()}
    }
    private func updatePageLabel() {
        if let pdf,let d=pdf.document,let p=pdf.currentPage {
            let scan=(p.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            metadata.stringValue="\(d.index(for:p)+1) / \(d.pageCount)" + (scan ? " · 本页无可选文字" : "")
        }
    }
    @objc func pdfSelection(_ note:Notification) {
        guard let pdf,let sender=note.object as? PDFView,sender === pdf else {return}
        guard let s=pdf.currentSelection, let text=s.string, !text.isEmpty else { selected("",.zero); return }
        let lines = s.selectionsByLine()
        let line = lines.reversed().first(where:{ part in
            guard let p=part.pages.last else {return false}
            return pdf.bounds.intersects(pdf.convert(part.bounds(for:p),from:p))
        }) ?? s
        guard let page=line.pages.last else { return }
        let r=pdf.convert(line.bounds(for:page),from:page); selected(text,pdf.convert(r,to:canvas))
    }
    func selected(_ raw:String,_ rect:NSRect) {
        let text=raw.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.rangeOfCharacter(from:.letters) != nil,
              !text.lowercased().hasPrefix("https://"), !text.lowercased().hasPrefix("http://"),
              text.range(of:"^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$",options:.regularExpression)==nil else {
            // PDFKit can clear its selection during focus and viewport changes.
            resetSelectionTracking()
            return
        }
        let excerpt = text.count<=120 ? currentExcerpt : nil
        let ranges = excerpt?.spans ?? []
        if text == lastNotified && ranges==lastRanges {return}
        pending?.cancel(); lastNotified=text; lastRanges=ranges
        let documentID=entry?.id
        func schedule() {
            let task=DispatchWorkItem { [weak self] in
                guard let self, self.entry?.id==documentID else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 { schedule(); return }
                self.pending=nil
                self.revision += 1
                let version=self.revision
                self.translatedRanges=ranges
                self.source=text; self.anchor=rect; self.result=""; self.busy=true; self.failed=false
                self.placeBubble()
                if text.count > 5000 { self.engine.cancel("follow"); self.busy=false; self.failed=true; self.result="选区超过 5,000 字符，请分段划选。" }
                self.paint()
                if !self.failed {
                    let context=excerpt?.text==text ? excerpt?.termContext ?? "" : ""
                    self.engine.translate(text,lane:"follow",context:context) { [weak self] str,done,error in
                        guard let self,self.revision==version else {return}
                        self.result=str; self.busy = !done; self.failed=error; self.paint()
                    }
                }
            }
            pending=task; DispatchQueue.main.asyncAfter(deadline:.now()+0.38,execute:task)
        }
        schedule()
    }
    private func paint() {
        bubble.show(source,result,busy,failed)
        if bubble.superview != nil { placeBubble() }
    }
    private func placeBubble() {
        let w=min(384,canvas.bounds.width-16)
        guard w > 40, canvas.bounds.height > 40 else { return }
        let block = (result as NSString).boundingRect(with:NSSize(width:w-32,height:10000),
            options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:16)])
        let h=min(canvas.bounds.height-16,min(240,max(118,ceil(block.height)+92)))
        let x=max(8,min(canvas.bounds.width-w-8,draggedTop?.x ?? (anchor.midX-w/2)))
        let below=anchor.minY-h-5
        let idealY=draggedTop.map{$0.y-h} ?? (below >= 8 ? below : anchor.maxY+5)
        let y=max(8,min(canvas.bounds.height-h-8,idealY))
        if draggedTop != nil { draggedTop=NSPoint(x:x,y:y+h) }
        bubble.frame=NSRect(x:x,y:y,width:w,height:h)
        if bubble.superview == nil { canvas.addSubview(bubble,positioned:.above,relativeTo:pageHost) }
    }
    func isDocumentClick(at windowPoint:NSPoint)->Bool {
        guard let surface=activeTab?.view, let parent=canvas.superview,
              let hit=canvas.hitTest(parent.convert(windowPoint,from:nil)),
              hit.isDescendant(of:surface) else {return false}
        var node:NSView?=hit
        while let view=node, view !== surface {
            if view is NSScroller {return false}
            node=view.superview
        }
        guard let pdf else {return true}
        let point=pdf.convert(windowPoint,from:nil)
        guard let page=pdf.page(for:point,nearest:false) else {return false}
        return page.bounds(for:pdf.displayBox).contains(pdf.convert(point,to:page))
    }
    private func resetSelectionTracking() {
        pending?.cancel(); pending=nil; lastNotified=""; lastRanges=[]
    }
    private func clear() {
        revision += 1; resetSelectionTracking(); engine.cancel("follow"); translatedRanges=[]; source=""; result=""; busy=false; failed=false
        bubble.removeFromSuperview(); paint()
    }
    func dismissBubble() {
        clear()
    }
    @objc func toggleTranslation() { setSide(side == .translation ? .none : .translation) }
    @objc func toggleWords() { setSide(side == .words ? .none : .words) }
    @objc func toggleNotes() { setSide(side == .notes ? .none : .notes) }
    @objc func toggleTerminal() { setSide(side == .terminal ? .none : .terminal) }
    func setSide(_ next:Side) {
        if side != .none && sideHost.frame.width>=240 { sidebarWidth=sideHost.frame.width }
        side=next; sideHost.subviews.forEach{$0.removeFromSuperview()}
        if next == .none {
            if sideHost.superview != nil { split.removeArrangedSubview(sideHost); sideHost.removeFromSuperview() }
        } else {
            if sideHost.superview == nil {
                let width=min(split.bounds.width-340,max(275,min(720,sidebarWidth)))
                let left=split.bounds.width-width-split.dividerThickness
                canvas.frame=NSRect(x:0,y:0,width:left,height:split.bounds.height)
                sideHost.frame=NSRect(x:left+split.dividerThickness,y:0,width:width,height:split.bounds.height)
                split.addArrangedSubview(sideHost)
                split.setPosition(left,ofDividerAt:0)
            }
            if next == .translation { fill(manual,in:sideHost) }
            else if next == .notes {fill(margins.panel,in:sideHost)}
            else if next == .words {
                fill(wordsPanel,in:sideHost); refreshWords()
                for word in notes.data.words where wordErrors[word.id] == nil && (word.meaning.isEmpty || word.example.isEmpty) {completeWord(word.id)}
            }
            else {
                if terminal == nil {
                    terminal=TerminalPane()
                    if let dir=entry?.original.deletingLastPathComponent(),FileManager.default.fileExists(atPath:dir.path) { terminal?.directory=dir }
                }
                fill(terminal!.web,in:sideHost); terminal?.focus()
            }
        }
        translateButton.contentTintColor=next == .translation ? accent:nil
        wordsButton.contentTintColor=next == .words ? accent:nil
        notesButton.contentTintColor=next == .notes ? accent:nil
        terminalButton.contentTintColor=next == .terminal ? accent:nil
        split.adjustSubviews()
        margins.invalidate()
        if bubble.superview != nil {placeBubble()}
    }
    func splitView(_ splitView:NSSplitView,constrainMinCoordinate proposedMinimumPosition:CGFloat,ofSubviewAt offset:Int)->CGFloat { max(340,splitView.bounds.width-720) }
    func splitView(_ splitView:NSSplitView,constrainMaxCoordinate proposedMaximumPosition:CGFloat,ofSubviewAt offset:Int)->CGFloat { splitView.bounds.width-275 }
    func splitView(_ splitView:NSSplitView,shouldAdjustSizeOfSubview view:NSView)->Bool { view === canvas }
    func windowDidResize(_ notification:Notification) { margins.invalidate(); if bubble.superview != nil { placeBubble() } }
    func windowDidResignKey(_ notification:Notification) {margins.cancelGesture()}
    func stop() {
        margins.detach()
        if let keyMonitor {NSEvent.removeMonitor(keyMonitor); self.keyMonitor=nil}
        saveSession(); saveDraft(); pending?.cancel(); engine.stop(); terminal?.stop()
    }
}
