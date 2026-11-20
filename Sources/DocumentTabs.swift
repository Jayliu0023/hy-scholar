import AppKit
import PDFKit

struct PagePosition: Codable {
    let page: Int
    let point: CGPoint
    let scale: CGFloat
    let fitsWidth: Bool

    init?(_ view: PDFView) {
        guard let document = view.document, let dest = view.currentDestination, let page = dest.page,
              dest.point.x.isFinite, dest.point.y.isFinite, view.scaleFactor > 0 else { return nil }
        self.page = document.index(for: page)
        point = dest.point
        scale = view.scaleFactor
        fitsWidth = view.autoScales
    }
}

struct SavedTab: Codable {
    let id: String
    var position: PagePosition?
}

struct TabSession: Codable {
    let tabs: [SavedTab]
    let activeID: String?
}

final class ReadingTab {
    let entry: DocumentEntry
    var pdf: PDFView?
    var markdown: MarkdownPane?
    var annotations = [PDFAnnotation]()
    var position: PagePosition?
    var view: NSView? { pdf ?? markdown?.web }

    init(_ entry: DocumentEntry, position: PagePosition? = nil) {
        self.entry = entry
        self.position = position
    }
}

private final class TabChip: NSView {
    let id: String
    let nameButton: NSButton
    private let closeButton: NSButton
    private let select: (String) -> Void
    private let close: (String) -> Void
    let active: Bool

    init(_ item: DocumentEntry, active: Bool, select: @escaping (String)->Void, close: @escaping (String)->Void) {
        id = item.id
        self.active = active
        self.select = select
        self.close = close
        nameButton = NSButton(title: item.name, target: nil, action: nil)
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: nil, action: nil)
        let font = NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        let textWidth = (item.name as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: NSRect(x: 0,y: 3,width: min(208,max(108,ceil(textWidth)+43)),height: 27))
        wantsLayer = true
        layer?.cornerRadius = 6
        nameButton.font = font
        nameButton.isBordered = false
        nameButton.alignment = .left
        nameButton.lineBreakMode = .byTruncatingMiddle
        nameButton.toolTip = item.original.path
        nameButton.setAccessibilityLabel(item.name + (active ? "，当前标签页" : ""))
        nameButton.target = self; nameButton.action = #selector(pick)
        closeButton.isBordered = false
        closeButton.image?.size = NSSize(width:10,height:10)
        closeButton.toolTip = "关闭 " + item.name
        closeButton.setAccessibilityLabel("关闭 " + item.name)
        closeButton.target = self; closeButton.action = #selector(removeTab)
        addSubview(nameButton); addSubview(closeButton)
        tint()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        nameButton.frame = NSRect(x:8,y:0,width:bounds.width-33,height:bounds.height)
        closeButton.frame = NSRect(x:bounds.width-25,y:2,width:22,height:bounds.height-4)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); tint() }
    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (active ? accent.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor.withAlphaComponent(0.07)).cgColor
        }
    }
    override func mouseDown(with event:NSEvent) { pick() }
    @objc private func pick() { select(id) }
    @objc private func removeTab() { close(id) }
}

private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event:NSEvent) {
        guard abs(event.scrollingDeltaY)>abs(event.scrollingDeltaX), let doc=documentView,
              doc.bounds.width>contentView.bounds.width else { super.scrollWheel(with:event); return }
        let step=event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 14)
        let x=max(0,min(doc.bounds.width-contentView.bounds.width,contentView.bounds.minX-step))
        contentView.scroll(to:NSPoint(x:x,y:0)); reflectScrolledClipView(contentView)
    }
}

final class DocumentTabBar: NSView {
    private let scroll=TabScrollView(), strip=NSView()
    private let addButton = NSButton(image:NSImage(systemSymbolName:"plus",accessibilityDescription:nil)!,target:nil,action:nil)
    var select: ((String)->Void)?
    var close: ((String)->Void)?
    var add: (() -> Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        scroll.drawsBackground=false
        scroll.hasHorizontalScroller=true; scroll.autohidesScrollers=true; scroll.scrollerStyle = .overlay
        scroll.documentView=strip
        addButton.isBordered=false; addButton.toolTip="打开新标签页（⌘T）"
        addButton.setAccessibilityLabel("打开新标签页")
        addButton.target=self; addButton.action = #selector(openTab)
        addSubview(scroll); addSubview(addButton)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        scroll.frame=NSRect(x:10,y:0,width:max(0,bounds.width-52),height:bounds.height)
        addButton.frame=NSRect(x:bounds.width-38,y:2,width:28,height:max(0,bounds.height-4))
    }
    func show(_ entries:[DocumentEntry], activeID:String?) {
        strip.subviews.forEach{$0.removeFromSuperview()}
        var x:CGFloat=0
        var selected:TabChip?
        for entry in entries {
            let chip=TabChip(entry,active:entry.id==activeID,select:{[weak self] in self?.select?($0)},close:{[weak self] in self?.close?($0)})
            chip.setFrameOrigin(NSPoint(x:x,y:3))
            x += chip.frame.width+4
            strip.addSubview(chip)
            if chip.active {selected=chip}
        }
        strip.setFrameSize(NSSize(width:x,height:33))
        layoutSubtreeIfNeeded()
        if let selected {strip.scrollToVisible(selected.frame)}
    }
    @objc private func openTab() { add?() }
}
