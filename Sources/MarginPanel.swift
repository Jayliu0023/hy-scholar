import AppKit

private final class TopDownView:NSView { override var isFlipped:Bool {true} }

final class NoteCard:NSView,NSTextViewDelegate {
    override var isFlipped:Bool {true}
    let id:String
    let editor=NSTextView()
    let quote=NSButton(), palette=NSPopUpButton(), trash=NSButton()
    var edit:((String,String)->Void)?, recolor:((String,NoteInk)->Void)?, remove:((String)->Void)?, locate:((String)->Void)?
    init(_ note:MarginNote) {
        id=note.id
        super.init(frame:.zero)
        wantsLayer=true; layer?.cornerRadius=7; layer?.borderWidth=1
        quote.isBordered=false; quote.alignment = .left; quote.lineBreakMode = .byTruncatingTail
        quote.font = .systemFont(ofSize:12,weight:.medium); quote.target=self; quote.action=#selector(jump)
        quote.toolTip="定位到正文 · "+note.quote; quote.title=note.quote
        palette.controlSize = .small; palette.bezelStyle = .rounded
        palette.toolTip="批注连线颜色"; palette.setAccessibilityLabel("批注连线颜色")
        palette.addItems(withTitles:NoteInk.allCases.map(\.title)); palette.target=self;palette.action=#selector(colorChanged)
        trash.isBordered=false; trash.image=NSImage(systemSymbolName:"trash",accessibilityDescription:"删除批注")
        trash.toolTip="删除批注";trash.target=self;trash.action = #selector(deleteNote)
        editor.isRichText=false;editor.isEditable=true;editor.isSelectable=true;editor.allowsUndo=true
        editor.drawsBackground=false;editor.font = .systemFont(ofSize:14);editor.textColor = .labelColor
        editor.isHorizontallyResizable=false;editor.isVerticallyResizable=false
        editor.textContainer?.widthTracksTextView=true;editor.textContainer?.heightTracksTextView=false
        editor.textContainerInset=NSSize(width:0,height:3);editor.textContainer?.lineFragmentPadding=0
        editor.setAccessibilityLabel("批注内容");editor.string=note.text;editor.delegate=self
        for v in [quote,palette,trash,editor] {addSubview(v)}
        update(note)
    }
    required init?(coder:NSCoder){fatalError()}
    func update(_ note:MarginNote) {
        if editor.string != note.text && !editor.hasMarkedText() {editor.string=note.text}
        palette.selectItem(withTitle:note.ink.title);quote.contentTintColor=note.ink.color
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); tint()
    }
    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
            layer?.borderColor=NSColor.separatorColor.cgColor
        }
    }
    func arrange(width:CGFloat)->CGFloat {
        let inner=max(20,width-20)
        quote.frame=NSRect(x:10,y:7,width:max(20,inner-107),height:23)
        palette.frame=NSRect(x:width-111,y:7,width:83,height:22)
        trash.frame=NSRect(x:width-27,y:7,width:20,height:22)
        editor.setFrameSize(NSSize(width:inner,height:max(32,editor.frame.height)))
        if let t=editor.textContainer {editor.layoutManager?.ensureLayout(for:t)}
        let used=editor.textContainer.flatMap{editor.layoutManager?.usedRect(for:$0).height} ?? 0
        // Extra line fragment includes the editable line after a trailing return.
        let last=editor.layoutManager?.extraLineFragmentUsedRect.maxY ?? 0
        let h=max(36,ceil(max(used,last))+8)
        editor.frame=NSRect(x:10,y:35,width:inner,height:h)
        tint();return 43+h
    }
    func textDidChange(_ notification:Notification) {edit?(id,editor.string)}
    @objc private func colorChanged(){recolor?(id,NoteInk.allCases[palette.indexOfSelectedItem])}
    @objc private func deleteNote(){remove?(id)}
    @objc private func jump(){locate?(id)}
}

final class MarginPanel:NSView {
    let scroll=NSScrollView()
    private let list=TopDownView(), title=label("Note",15,.semibold)
    private let hint=NSTextField(wrappingLabelWithString:"右键选区添加 Note，或按住 Shift＋空格拖动框选。")
    private(set) var cards=[String:NoteCard]()
    private var ordered=[String]()
    var edit:((String,String)->Void)?, recolor:((String,NoteInk)->Void)?, remove:((String)->Void)?, locate:((String)->Void)?, reflow:(()->Void)?
    override init(frame:NSRect){
        super.init(frame:frame)
        hint.font = .systemFont(ofSize:12);hint.textColor = .secondaryLabelColor
        scroll.hasVerticalScroller=true;scroll.scrollerStyle = .overlay;scroll.autohidesScrollers=true;scroll.drawsBackground=false;scroll.documentView=list
        for v in [title,hint,scroll] {addSubview(v)}
    }
    required init?(coder:NSCoder){fatalError()}
    override func layout() {
        super.layout()
        title.frame=NSRect(x:13,y:bounds.height-33,width:max(0,bounds.width-26),height:23)
        hint.frame=NSRect(x:14,y:bounds.height-89,width:max(0,bounds.width-28),height:48)
        scroll.frame=NSRect(x:0,y:0,width:bounds.width,height:max(0,bounds.height-41))
        arrange()
    }
    func show(_ notes:[MarginNote]) {
        ordered=notes.enumerated().sorted {
            $0.element.order==$1.element.order ? $0.offset<$1.offset : $0.element.order<$1.element.order
        }.map{$0.element.id}
        let keep=Set(ordered)
        for id in Array(cards.keys) where !keep.contains(id) {cards.removeValue(forKey:id)?.removeFromSuperview()}
        for note in notes {
            if let c=cards[note.id] {c.update(note);continue}
            let c=NoteCard(note); cards[note.id]=c; list.addSubview(c)
            c.edit={ [weak self] id,text in self?.arrange();self?.edit?(id,text) }
            c.recolor={ [weak self] in self?.recolor?($0,$1) };c.remove={ [weak self] in self?.remove?($0) };c.locate={ [weak self] in self?.locate?($0) }
        }
        hint.isHidden = !notes.isEmpty; scroll.isHidden=notes.isEmpty
        layoutSubtreeIfNeeded();arrange()
    }
    private func arrange(){
        let width=scroll.contentSize.width
        guard width>30 else {return}
        var y:CGFloat=0
        for id in ordered {
            guard let c=cards[id] else {continue}
            let w=width-24, h=c.arrange(width:w)
            c.frame=NSRect(x:12,y:y,width:w,height:h); y += h+9
        }
        list.setFrameSize(NSSize(width:width,height:max(y,scroll.contentSize.height)))
        reflow?()
    }
    func focus(_ id:String) {
        guard let card=cards[id] else {return}
        list.scrollToVisible(card.frame); window?.makeFirstResponder(card.editor)
    }
}
