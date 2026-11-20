import AppKit

final class DragHeader: NSStackView {
    var drag: ((CGFloat,CGFloat)->Void)?
    private var previous:NSPoint?
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let hit=super.hitTest(point) else {return nil}
        var item:NSView?=hit
        while let v=item, v !== self {
            if v is NSButton {return hit}; item=v.superview
        }
        return self
    }
    override func resetCursorRects() {
        super.resetCursorRects(); addCursorRect(bounds,cursor:.openHand)
        for case let button as NSButton in arrangedSubviews { addCursorRect(button.frame,cursor:.arrow) }
    }
    override func mouseDown(with event:NSEvent) { previous=event.locationInWindow; NSCursor.closedHand.push() }
    override func mouseDragged(with event:NSEvent) {
        guard let p=previous else { return }; let q=event.locationInWindow
        drag?(q.x-p.x,q.y-p.y); previous=q
    }
    override func mouseUp(with event:NSEvent) { if previous != nil { NSCursor.pop() }; previous=nil }
}

func textArea(_ view:NSTextView,editable:Bool)->NSScrollView {
    let scroll=NSScrollView()
    scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true
    scroll.borderType = editable ? .bezelBorder : .noBorder
    scroll.drawsBackground=editable
    view.isEditable=editable; view.isSelectable=true; view.isRichText=false
    view.drawsBackground=editable; view.isVerticallyResizable=true; view.isHorizontallyResizable=false
    view.font = .systemFont(ofSize:15); view.textColor = .labelColor
    view.textContainerInset=NSSize(width:editable ? 7:0,height:7); view.textContainer?.widthTracksTextView=true
    view.textContainer?.lineFragmentPadding=0; view.autoresizingMask=[.width]
    view.isAutomaticQuoteSubstitutionEnabled=false; view.isAutomaticDashSubstitutionEnabled=false
    view.allowsUndo=editable
    scroll.documentView=view
    return scroll
}
struct Draft:Codable { var source="", result="", translatedFrom="" }
final class ManualPanel:NSView,NSTextViewDelegate {
    let input=NSTextView(), output=NSTextView()
    private let status=label("",11), spinner=NSProgressIndicator()
    private var button:NSButton!
    var submit:((String)->Void)?, edited:(()->Void)?
    var translatedFrom=""
    private var busy=false
    init() {
        super.init(frame:.zero)
        let sourceLabel=label("原文",14,.semibold), outputLabel=label("译文",14,.semibold)
        button=control("翻译","return","翻译（⌘↩）",self,#selector(run))
        button.keyEquivalent="\r"; button.keyEquivalentModifierMask=[.command]
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped=false
        status.textColor = .secondaryLabelColor
        let top=row([sourceLabel,NSView(),button]), divider=NSBox(), bottom=row([outputLabel,spinner,NSView(),status])
        divider.boxType = .separator
        let edit=textArea(input,editable:true), read=textArea(output,editable:false)
        let stack=NSStackView(views:[top,edit,divider,bottom,read]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=12
        pad(stack,in:self,15)
        for v in [top,edit,divider,bottom,read] { v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true }
        edit.heightAnchor.constraint(equalTo:stack.heightAnchor,multiplier:0.36).isActive=true
        read.setContentHuggingPriority(.defaultLow,for:.vertical)
        input.delegate=self; button.isEnabled=false
        input.setAccessibilityLabel("可编辑原文"); output.setAccessibilityLabel("手动翻译结果")
    }
    required init?(coder:NSCoder) { fatalError() }
    func restore(_ draft:Draft) {
        input.string=draft.source; output.string=draft.result; translatedFrom=draft.translatedFrom; refresh()
    }
    func replace(with text:String, translation:String?) {
        input.string=text; output.textColor = .labelColor; output.string=translation ?? ""; translatedFrom=translation == nil ? "" : text
        busy=false; refresh()
    }
    func textDidChange(_ notification:Notification) {
        busy=false; edited?(); refresh()
    }
    private func refresh() {
        let text=input.string.trimmingCharacters(in:.whitespacesAndNewlines)
        button.isEnabled = !text.isEmpty && !busy
        if busy {spinner.startAnimation(nil)} else {spinner.stopAnimation(nil)}
        status.stringValue=busy ? "翻译中…" : (!output.string.isEmpty && translatedFrom != input.string ? "原文已修改" : "")
    }
    @objc func run() {
        let text=input.string.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else {return}
        if text.count>5000 { status.stringValue="请分段输入，每次不超过 5,000 字符";return }
        output.string=""; busy=true; refresh(); submit?(text)
    }
    func show(_ text:String,done:Bool,error:Bool) {
        busy = !done; output.string=text; output.textColor=error ? .systemRed:.labelColor
        if done && !error { translatedFrom=input.string }
        refresh()
        if error {status.stringValue="可重新翻译"}
    }
}

private final class WordButton:NSButton { var wordID="" }
final class WordPanel:NSView {
    let table=NSTableView(), heading=label("收藏词汇",15,.semibold), empty=label("划选词汇后，右键选择「收藏词汇」。",12)
    var remove:((String)->Void)?, retry:((String)->Void)?
    private var words=[Word](), errors=[String:String]()
    init() {
        super.init(frame:.zero)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("words")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView=nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource=self; table.delegate=self; table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights=true; table.intercellSpacing=NSSize(width:0,height:8)
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.documentView=table
        empty.textColor = .secondaryLabelColor
        let s=NSStackView(views:[heading,empty,scroll]); s.orientation = .vertical; s.alignment = .leading; s.spacing=12
        pad(s,in:self,13); scroll.widthAnchor.constraint(equalTo:s.widthAnchor).isActive=true
        scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
    }
    required init?(coder:NSCoder) { fatalError() }
    func show(_ list:[Word],errors:[String:String]) {
        self.words=list; self.errors=errors; empty.isHidden = !list.isEmpty
        heading.stringValue=list.isEmpty ? "收藏词汇" : "收藏词汇  ·  \(list.count)"
        table.reloadData()
    }
    @objc private func unstar(_ button:WordButton) { remove?(button.wordID) }
    @objc private func retryWord(_ button:WordButton) { retry?(button.wordID) }
}
extension WordPanel:NSTableViewDataSource,NSTableViewDelegate {
    func numberOfRows(in tableView:NSTableView)->Int { words.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row i:Int)->NSView? {
        let w=words[i], cell=NSTableCellView()
        func wrapped(_ s:String,_ size:CGFloat,_ weight:NSFont.Weight = .regular)->NSTextField {
            let v=NSTextField(wrappingLabelWithString:s); v.font = .systemFont(ofSize:size,weight:weight)
            v.isSelectable=true; v.setContentCompressionResistancePriority(.required,for:.vertical)
            return v
        }
        let term=wrapped(w.term,16,.semibold)
        let button=WordButton(image:NSImage(systemSymbolName:"star.fill",accessibilityDescription:"取消收藏")!,target:self,action:#selector(unstar(_:)))
        button.isBordered=false; button.wordID=w.id; button.toolTip="取消收藏";button.contentTintColor = accent
        let head=row([term,NSView(),button])
        let definition=wrapped(w.meaning.isEmpty ? "等待译文…" : w.meaning,14)
        let context=wrapped(w.example.isEmpty ? "正在补全例句…" : w.example,13)
        let attribution=wrapped(w.generated ? "模型例句" : "原文例句 · "+w.document,11)
        attribution.textColor = .secondaryLabelColor; context.textColor = .secondaryLabelColor
        var views:[NSView]=[head,definition,context,attribution]
        if let error=errors[w.id] {
            let again=WordButton(title:"重试",target:self,action:#selector(retryWord(_:)))
            again.wordID=w.id; again.toolTip=error; views.append(again)
        }
        let stack=NSStackView(views:views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=6
        pad(stack,in:cell,6)
        for v in [head,definition,context,attribution] { v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true }
        return cell
    }
}
