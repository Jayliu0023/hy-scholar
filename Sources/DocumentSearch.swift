import AppKit
import PDFKit
import WebKit

final class DocumentFindBar:NSView {
    let field=NSSearchField(), status=label("",12), previous=NSButton(), next=NSButton()
    var move:((Int)->Void)?, dismiss:(()->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        field.placeholderString="搜索当前文档";field.setAccessibilityLabel("搜索当前文档")
        field.sendsSearchStringImmediately=true;field.sendsWholeSearchString=false
        status.textColor = .secondaryLabelColor;status.alignment = .right
        for (button,symbol,title,action) in [(previous,"chevron.up","上一个结果（⇧Return）",#selector(back)),(next,"chevron.down","下一个结果（Return）",#selector(forward))] {
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:title)
            button.bezelStyle = .rounded;button.toolTip=title;button.target=self;button.action=action
        }
        let close=control("","xmark","关闭搜索（Esc）",self,#selector(closeNow))
        let line=row([field,status,previous,next,close],spacing:7);pad(line,in:self,7)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant:130).isActive=true
        status.widthAnchor.constraint(equalToConstant:120).isActive=true
        previous.widthAnchor.constraint(equalToConstant:30).isActive=true
        next.widthAnchor.constraint(equalToConstant:30).isActive=true
    }
    required init?(coder:NSCoder){fatalError()}
    @objc private func back(){move?(-1)}
    @objc private func forward(){move?(1)}
    @objc private func closeNow(){dismiss?()}
}
final class DocumentSearch:NSObject,NSSearchFieldDelegate {
    unowned let reader:Reader
    let bar=DocumentFindBar()
    private(set) var isVisible=false, isSearching=false, count=0, index = -1
    var visibility:((Bool)->Void)?
    private var pending:DispatchWorkItem?, generation=0
    private var observers=[NSObjectProtocol]()
    private weak var pdf:PDFView?, markdown:MarkdownPane?
    private var matches=[PDFSelection]()
    init(_ reader:Reader) {
        self.reader=reader
        super.init()
        bar.field.delegate=self
        bar.move={ [weak self] in self?.step($0) }
        bar.dismiss={ [weak self] in self?.close() }
    }
    func open() {
        guard reader.activeTab != nil else{return}
        reader.dismissBubble()
        isVisible=true;visibility?(true)
        reader.window.makeFirstResponder(bar.field);bar.field.selectText(nil)
        run()
    }
    func close() {
        cancel();isVisible=false;visibility?(false)
        if let view=reader.activeTab?.view {reader.window.makeFirstResponder(view)}
    }
    func bind() {
        cancel()
        if reader.activeTab==nil {isVisible=false;visibility?(false)}
        else if isVisible {run()}
    }
    func cancel() {
        generation += 1;pending?.cancel();pending=nil
        observers.forEach{NotificationCenter.default.removeObserver($0)};observers=[]
        pdf?.document?.cancelFindString();pdf?.highlightedSelections=nil
        if let md=markdown {md.web.callAsyncJavaScript("findInPaper(id,query)",arguments:["id":md.revision,"query":""],in:nil,in:.page){_ in}}
        pdf=nil;markdown=nil;matches=[];count=0;index = -1;isSearching=false;updateStatus()
    }
    func controlTextDidChange(_ notification:Notification) {
        guard isVisible else{return}
        cancel()
        let work=DispatchWorkItem{[weak self] in self?.run()};pending=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:work)
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy command:Selector)->Bool {
        if command == #selector(NSResponder.insertNewline(_:)) {step(NSEvent.modifierFlags.contains(.shift) ? -1:1);return true}
        if command == #selector(NSResponder.cancelOperation(_:)) {close();return true}
        return false
    }
    func run() {
        cancel()
        let query=bar.field.stringValue
        guard isVisible,!query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,reader.activeTab != nil else{return}
        let version=generation,id=reader.entry?.id
        isSearching=true;updateStatus()
        if let view=reader.pdf,let doc=view.document {
            pdf=view
            let center=NotificationCenter.default
            observers.append(center.addObserver(forName:.PDFDocumentDidFindMatch,object:doc,queue:.main){[weak self] note in
                guard let self,self.generation==version,self.reader.entry?.id==id,
                      let selection=note.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection else{return}
                selection.color=NSColor.systemYellow.withAlphaComponent(0.45)
                self.matches.append(selection);self.count=self.matches.count;self.updateStatus()
            })
            observers.append(center.addObserver(forName:.PDFDocumentDidEndFind,object:doc,queue:.main){[weak self] _ in
                guard let self,self.generation==version,self.reader.entry?.id==id else{return}
                self.isSearching=false;self.count=self.matches.count
                if self.count>0 {
                    let page=view.currentPage.map{doc.index(for:$0)} ?? 0
                    self.index=self.matches.firstIndex{($0.pages.first.map{doc.index(for:$0)} ?? 0)>=page} ?? 0
                    self.reveal()
                }
                self.updateStatus()
            })
            doc.beginFindString(query,withOptions:.caseInsensitive)
        } else if let md=reader.markdown {
            markdown=md
            guard md.contentReady else{return}
            md.web.callAsyncJavaScript("return findInPaper(id,query)",arguments:["id":md.revision,"query":query],in:nil,in:.page){[weak self] result in
                guard let self,self.generation==version,self.reader.entry?.id==id else{return}
                self.isSearching=false
                switch result {
                case let .success(value):self.count=(value as? Int) ?? 0;self.index=self.count>0 ? 0:-1;self.reveal();self.updateStatus()
                case .failure:self.bar.status.stringValue="搜索失败";self.bar.next.isEnabled=false;self.bar.previous.isEnabled=false
                }
            }
        }
    }
    func step(_ delta:Int) {
        guard isVisible else{open();return}
        if pending != nil {run();return}
        guard !isSearching,count>0 else{return}
        index=(index+delta+count)%count;reveal();updateStatus()
    }
    private func reveal() {
        guard index>=0,index<count else{return}
        if let pdf,index<matches.count {
            for (i,selection) in matches.enumerated() {selection.color=(i==index ? NSColor.systemOrange:NSColor.systemYellow).withAlphaComponent(0.45)}
            pdf.highlightedSelections=matches;pdf.go(to:matches[index])
        } else if let md=markdown {
            md.web.callAsyncJavaScript("revealSearchResult(id,index)",arguments:["id":md.revision,"index":index],in:nil,in:.page){_ in}
        }
    }
    private func updateStatus() {
        let empty=bar.field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        bar.status.stringValue=empty ? "" : (isSearching ? "搜索中…" : (count==0 ? "没有匹配结果":"\(max(0,index)+1) / \(count)"))
        bar.next.isEnabled = !isSearching && count>0;bar.previous.isEnabled=bar.next.isEnabled
    }
}
