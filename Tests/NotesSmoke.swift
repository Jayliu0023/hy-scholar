import AppKit
import PDFKit
import WebKit

private enum Failure:Error {case check(String)}
@MainActor private func check(_ value:Bool,_ message:String)throws {
    guard value else {throw Failure.check(message)}
    print("PASS",message);fflush(stdout)
}
@MainActor private func pause() async {try? await Task.sleep(nanoseconds:200_000_000)}
@MainActor private func wait(_ message:String,_ condition:()->Bool)async throws {
    let deadline=Date().addingTimeInterval(15)
    while !condition() {
        if Date()>deadline {throw Failure.check("Timeout: "+message)}
        try? await Task.sleep(nanoseconds:50_000_000)
    }
}
@MainActor private func mouse(_ type:NSEvent.EventType,_ point:CGPoint,_ reader:Reader)->NSEvent {
    NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:reader.window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
}
@MainActor private func key(_ type:NSEvent.EventType,_ code:UInt16,_ flags:NSEvent.ModifierFlags,_ reader:Reader)->NSEvent {
    NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:reader.window.windowNumber,
        context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:code)!
}
@MainActor private func javascript(_ pane:MarkdownPane,_ script:String)async throws->Any? {
    try await pane.web.evaluateJavaScript(script)
}
@MainActor private func chooseNote(_ reader:Reader,_ passage:Excerpt)throws {
    let menu=reader.selectionMenu(for:passage)
    guard let item=menu.items.first(where:{$0.title=="添加 Note"}) else {throw Failure.check("Note menu missing")}
    reader.contextAction(item)
}
@MainActor private func box(_ reader:Reader,_ a:CGPoint,_ b:CGPoint)async throws {
    reader.window.makeFirstResponder(reader.activeTab?.view)
    // Exercise the application's local event monitor, as a real keyboard/mouse drag does.
    for event in [key(.keyDown,49,[.shift],reader),mouse(.leftMouseDown,a,reader),
                  mouse(.leftMouseDragged,b,reader),mouse(.leftMouseUp,b,reader),key(.keyUp,49,[],reader)] {
        NSApp.postEvent(event,atStart:false)
    }
    await pause()
}
@main enum NotesSmoke {
    static var retainedReader:Reader?
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        Task {@MainActor in
            let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            let library=Library(root:folder.appendingPathComponent("library-"+UUID().uuidString))
            let r=Reader(library:library)
            r.window.setFrame(NSRect(x:40,y:60,width:1180,height:790),display:true)
            r.window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
            do {
                let pdfURL=folder.appendingPathComponent("Notes.pdf")
                let data=NSMutableData();let consumer=CGDataConsumer(data:data)!
                let ctx=CGContext(consumer:consumer,mediaBox:nil,nil)!
                for i in 0..<3 {
                    let rect=CGRect(x:0,y:0,width:612,height:792)
                    ctx.beginPDFPage([kCGPDFContextMediaBox:rect] as CFDictionary)
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false)
                    ("RNA catalysis emerges from dynamic ensembles.\n正文内容也可以添加笔记。\nPage \(i+1)" as NSString).draw(at:CGPoint(x:60,y:640),withAttributes:[.font:NSFont.systemFont(ofSize:17)])
                    NSGraphicsContext.restoreGraphicsState();ctx.endPDFPage()
                }
                ctx.closePDF();try data.write(to:pdfURL)
                let mdURL=folder.appendingPathComponent("Notes.md")
                try ("# Note test\n\n正文中的中文和 English text 都可以选中。\n\n"+String(repeating:"A paragraph to test document scrolling and note anchors.\n\n",count:25)).write(to:mdURL,atomically:true,encoding:.utf8)
                r.openFiles([pdfURL,mdURL]);await pause()
                let pdfTab=r.activeTab!, pdf=r.pdf!, page=pdf.document!.page(at:0)!
                let selection=pdf.document!.findString("RNA catalysis",withOptions:[]).first!
                let passage:Excerpt
                pdf.setCurrentSelection(selection,animate:false)
                passage=pdf.excerpt()!
                try chooseNote(r,passage);await pause()
                try check(r.side == .notes && r.margins.book.notes.count==1,"text menu opens Note sidebar with editor")
                let first=r.margins.book.notes[0],card=r.margins.panel.cards[first.id]!
                try check(r.window.firstResponder === card.editor,"new note receives keyboard focus")
                let small=card.frame.height
                card.editor.string=String(repeating:"Long note grows without covering its neighbors. 中文批注。\n",count:8)
                card.textDidChange(Notification(name:NSText.didChangeNotification));await pause()
                try check(card.frame.height>small+100,"note card grows with text")
                try check(r.margins.connector(r.margins.book.notes[0]) != nil,"visible PDF passage connects to its card")
                card.palette.selectItem(withTitle:NoteInk.blue.title)
                _=card.palette.sendAction(card.palette.action!,to:card.palette.target)
                try check(r.margins.book.notes[0].ink == .blue,"connector color updates")
                try r.notes.mark(.underline,ranges:passage.spans,document:pdfTab.entry.id);r.redrawMarks();pdf.clearSelection()
                let source=selection.selectionsByLine()[0].bounds(for:page)
                let sourceWindow=pdf.convert(pdf.convert(CGPoint(x:source.midX,y:source.midY),from:page),to:nil)
                let marked=r.margins.markedExcerpt(at:sourceWindow)
                try check(marked?.text==passage.text,"right-click hit resolves underline without a selection")
                try chooseNote(r,marked!);await pause()
                let chinese=pdf.document!.findString("内容",withOptions:[]).first!
                pdf.setCurrentSelection(chinese,animate:false);try chooseNote(r,pdf.excerpt()!);await pause()
                try check(r.margins.book.notes.count==3,"Chinese body selection also creates a note")
                let a=pdf.convert(pdf.convert(CGPoint(x:70,y:480),from:page),to:nil)
                let b=pdf.convert(pdf.convert(CGPoint(x:280,y:560),from:page),to:nil)
                try await box(r,a,b)
                try check(r.margins.book.regions.count==1,"PDF box is persisted in page coordinates")
                let region=r.margins.book.regions[0],hit=r.margins.boxAt(CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2))
                try check(hit?.id==region.id,"box right-click hit testing works")
                let boxMenu=r.margins.boxMenu(region)
                let add=boxMenu.items[0];_ = NSApp.sendAction(add.action!,to:add.target,from:add);await pause()
                try check(r.margins.book.notes.count==4,"box menu creates an anchored note")
                let color=boxMenu.items.first(where:{$0.title=="框线颜色"})!.submenu!.items.first(where:{$0.title=="紫色"})!
                _=NSApp.sendAction(color.action!,to:color.target,from:color)
                try check(r.margins.book.regions[0].ink == .purple,"box color updates independently")
                let ordered=r.margins.book.notes.sorted{$0.order<$1.order}
                try check(zip(ordered,ordered.dropFirst()).allSatisfy{ pair in
                    let a=r.margins.panel.cards[pair.0.id]!,b=r.margins.panel.cards[pair.1.id]!
                    return a.frame.maxY<=b.frame.minY
                },"notes follow document order without overlapping")
                pdf.autoScales=false;pdf.scaleFactor *= 1.15;await pause()
                if case let .pdf(_,rect)=region.location {
                    let point=pdf.convert(pdf.convert(CGPoint(x:rect.midX,y:rect.midY),from:page),to:nil)
                    try check(r.margins.boxAt(point)?.id==region.id,"zoom keeps region hit testing aligned with its PDF page")
                }
                pdf.go(to:pdf.document!.page(at:2)!);await pause()
                try check(r.margins.connector(first)==nil,"offscreen PDF source does not leave a dangling connector")
                pdf.go(to:selection);r.margins.panel.focus(first.id);await pause()
                try check(r.margins.connector(first) != nil,"scrolling back restores the source connector")
                let regionCount=r.margins.book.regions.count
                r.window.makeFirstResponder(pdf)
                _=r.margins.handle(key(.keyDown,49,[.shift],r))
                _=r.margins.handle(mouse(.leftMouseDown,sourceWindow,r))
                _=r.margins.handle(mouse(.leftMouseDragged,CGPoint(x:sourceWindow.x+80,y:sourceWindow.y-40),r))
                _=r.margins.handle(key(.keyDown,53,[],r))
                _=r.margins.handle(mouse(.leftMouseUp,sourceWindow,r))
                try check(r.margins.book.regions.count==regionCount,"Escape cancels a region before it is saved")
                r.selectTab(r.tabs[1].entry.id);await pause()
                try check(r.margins.book.notes.isEmpty,"another tab has a separate notebook")
                let md=r.markdown!
                try await wait("Markdown load"){md.rendered}
                _=try await javascript(md,"(() => {const r=rangeAt({start:9,length:12});const s=getSelection();s.removeAllRanges();s.addRange(r);publishSelection();})()")
                try await wait("Markdown selection"){md.excerpt != nil}
                try chooseNote(r,md.excerpt!);await pause()
                try await wait("Markdown connector"){r.margins.connector(r.margins.book.notes[0]) != nil}
                let mdNote=r.margins.book.notes[0]
                try check(!mdNote.quote.isEmpty,"Markdown body selection creates connected note")
                try r.notes.mark(.highlight,ranges:md.excerpt!.spans,document:r.entry!.id);r.redrawMarks()
                _=try await javascript(md,"getSelection().removeAllRanges();publishSelection()")
                try await wait("Markdown mark geometry"){!md.geometry.marks.isEmpty}
                let rect=md.rect(md.geometry.marks[0].rects[0]);let p=md.web.convert(CGPoint(x:rect.midX,y:rect.midY),to:nil)
                try check(r.margins.markedExcerpt(at:p) != nil,"Markdown highlight can be annotated without reselection")
                let mdA=md.web.convert(CGPoint(x:120,y:140),to:nil),mdB=md.web.convert(CGPoint(x:360,y:200),to:nil)
                try await box(r,mdA,mdB)
                try await wait("Markdown region"){r.margins.book.regions.count==1}
                try check(!md.geometry.notes.isEmpty,"Markdown keeps text anchor after markup changes")
                r.window.makeFirstResponder(r.margins.panel.cards[mdNote.id]!.editor)
                try check(!r.margins.handle(key(.keyDown,49,[.shift],r)),"typing Shift + Space in note editor is preserved")
                r.selectTab(pdfTab.entry.id);await pause()
                try check(r.margins.book.notes.count==4 && r.margins.book.regions[0].ink == .purple,"tab switching restores notes and region color")
                let restored=try NotebookStore(library.base).read(pdfTab.entry.id)
                try check(restored.notes.count==4 && restored.notes.first(where:{$0.id==first.id})?.text.contains("Long note")==true,"fresh store reloads saved note text and anchors")
                let staleMenu=r.selectionMenu(for:passage), staleItem=staleMenu.items.first(where:{$0.title=="添加 Note"})!
                r.selectTab(r.tabs[1].entry.id);r.contextAction(staleItem)
                try check(r.margins.book.notes.count==1,"stale context menu cannot add a note to another document")
                r.selectTab(pdfTab.entry.id);r.setSide(.notes);await pause()
                // Keep all cards visible for the screenshot.
                if let c=r.margins.panel.cards[first.id] {c.editor.string="记录催化构象之间的转换，结合图 2 核对。";c.textDidChange(Notification(name:NSText.didChangeNotification))}
                await pause();r.window.contentView?.layoutSubtreeIfNeeded()
                print("NOTES SMOKE OK");fflush(stdout)
                if CommandLine.arguments.contains("--preview") {retainedReader=r}
                else {r.stop();app.terminate(nil)}
            } catch {print("FAIL",error);fflush(stdout);r.stop();exit(1)}
        }
        app.run()
    }
}
