import AppKit
import PDFKit
import WebKit

enum OutlineTarget {
    case pdf(page:Int,point:CGPoint)
    case markdown(start:Int)
}
final class OutlineNode:NSObject {
    let title:String, target:OutlineTarget?
    var children=[OutlineNode]()
    init(_ title:String,target:OutlineTarget?=nil,children:[OutlineNode]=[]) {
        self.title=title;self.target=target;self.children=children;super.init()
    }
    var pageLabel:String {
        if case let .pdf(page,_)=target {return "\(page+1)"}
        return ""
    }
    static func pdf(_ document:PDFDocument)->[OutlineNode] {
        guard let root=document.outlineRoot else{return []}
        var visited=Set<ObjectIdentifier>()
        func children(_ parent:PDFOutline,_ depth:Int)->[OutlineNode] {
            guard depth<64,visited.insert(ObjectIdentifier(parent)).inserted else{return []}
            return (0..<parent.numberOfChildren).compactMap { index in
                guard let item=parent.child(at:index) else{return nil}
                let nested=children(item,depth+1)
                let title=oneLine(item.label ?? "")
                var target:OutlineTarget?
                if let destination=item.destination,let page=destination.page {
                    let index=document.index(for:page)
                    if index != NSNotFound,index>=0,index<document.pageCount {
                        let point=destination.point
                        target = .pdf(page:index,point:CGPoint(x:point.x.isFinite ? point.x:0,y:point.y.isFinite ? point.y:page.bounds(for:.cropBox).maxY))
                    }
                }
                return OutlineNode(title.isEmpty ? "未命名章节":title,target:target,children:nested)
            }
        }
        return children(root,0)
    }
    static func markdown(_ headings:[WebHeading])->[OutlineNode] {
        var roots=[OutlineNode](),stack=[(Int,OutlineNode)]()
        for heading in headings {
            let node=OutlineNode(heading.title,target:.markdown(start:heading.start))
            while let last=stack.last,last.0>=heading.level {stack.removeLast()}
            if let parent=stack.last?.1 {parent.children.append(node)} else {roots.append(node)}
            stack.append((heading.level,node))
        }
        return roots
    }
}
struct WebHeading:Decodable {let title:String,level:Int,start:Int}
final class OutlineList:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate {
    let tree=NSOutlineView()
    private let empty=NSTextField(wrappingLabelWithString:"")
    private var roots=[OutlineNode]()
    private var updating=false
    var jump:((OutlineNode)->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("section"))
        tree.addTableColumn(column);tree.outlineTableColumn=column
        tree.headerView=nil;tree.rowHeight=30;tree.indentationPerLevel=14
        tree.dataSource=self;tree.delegate=self;tree.focusRingType = .none
        tree.target=self;tree.action = #selector(pick)
        tree.setAccessibilityLabel("文章目录")
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        tree.backgroundColor = .clear;scroll.documentView=tree;pad(scroll,in:self)
        empty.font = .systemFont(ofSize:13);empty.textColor = .secondaryLabelColor
        addSubview(empty);empty.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([empty.topAnchor.constraint(equalTo:topAnchor,constant:12),empty.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),empty.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8)])
    }
    required init?(coder:NSCoder){fatalError()}
    func show(_ nodes:[OutlineNode],message:String) {
        updating=true
        roots=nodes;tree.reloadData()
        for node in roots {tree.expandItem(node)}
        tree.deselectAll(nil);updating=false
        empty.stringValue=message;empty.isHidden = !nodes.isEmpty
    }
    func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int {(item as? OutlineNode)?.children.count ?? roots.count}
    func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?)->Any {(item as? OutlineNode)?.children[index] ?? roots[index]}
    func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any)->Bool {!((item as? OutlineNode)?.children.isEmpty ?? true)}
    func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {
        guard let node=item as? OutlineNode else{return nil}
        let cell=NSTableCellView(),title=label(node.title,13),page=label(node.pageLabel,11)
        title.toolTip=node.title;page.textColor = .secondaryLabelColor;page.alignment = .right
        title.setAccessibilityLabel(node.title)
        let line=row([title,page]);pad(line,in:cell,2)
        title.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        page.widthAnchor.constraint(equalToConstant:28).isActive=true
        cell.textField=title;return cell
    }
    @objc private func pick() {
        guard tree.clickedRow>=0,let node=tree.item(atRow:tree.clickedRow) as? OutlineNode else{return}
        if node.target==nil {
            if tree.isItemExpanded(node) {tree.collapseItem(node)} else {tree.expandItem(node)}
        }
    }
    func outlineViewSelectionDidChange(_ notification:Notification) {
        guard !updating,tree.selectedRow>=0,let node=tree.item(atRow:tree.selectedRow) as? OutlineNode,node.target != nil else{return}
        jump?(node)
    }
}
