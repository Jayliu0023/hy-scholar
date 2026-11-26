import AppKit
import PDFKit
import WebKit

private enum Failure:Error {case check(String)}
@MainActor private func check(_ value:Bool,_ message:String)throws {
    guard value else{throw Failure.check(message)}
    print("PASS",message);fflush(stdout)
}
@MainActor private func pause()async {try? await Task.sleep(nanoseconds:180_000_000)}
@MainActor private func wait(_ message:String,_ condition:()->Bool)async throws {
    let end=Date().addingTimeInterval(15)
    while !condition(){if Date()>end{throw Failure.check("Timeout: "+message)};try? await Task.sleep(nanoseconds:40_000_000)}
}
@MainActor private func key(_ reader:Reader,_ code:UInt16,_ chars:String,_ flags:NSEvent.ModifierFlags)async {
    let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,
        windowNumber:reader.window.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
    NSApp.postEvent(event,atStart:false);await pause()
}
@MainActor private func query(_ reader:Reader,_ value:String)async throws {
    reader.documentSearch.bar.field.stringValue=value;reader.documentSearch.run()
    try await wait("query "+value){!reader.documentSearch.isSearching};await pause()
}
@main enum NavigationSmoke {
    static var retainedReader:Reader?
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        Task {@MainActor in
            let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            let library=Library(root:folder.appendingPathComponent("library-"+UUID().uuidString))
            let reader=Reader(library:library)
            reader.window.setFrame(NSRect(x:60,y:60,width:1180,height:790),display:true)
            reader.window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
            do {
                let pdfURL=folder.appendingPathComponent("Search.pdf")
                let data=NSMutableData();let consumer=CGDataConsumer(data:data)!,context=CGContext(consumer:consumer,mediaBox:nil,nil)!
                for page in 0..<3 {
                    context.beginPDFPage([kCGPDFContextMediaBox:CGRect(x:0,y:0,width:612,height:792)] as CFDictionary)
                    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
                    ("RNA search across pages.\nAlpha [RNA] on page \(page+1)." as NSString).draw(at:CGPoint(x:60,y:650),withAttributes:[.font:NSFont.systemFont(ofSize:18)])
                    NSGraphicsContext.restoreGraphicsState();context.endPDFPage()
                }
                context.closePDF()
                let authored=PDFDocument(data:data as Data)!,root=PDFOutline(),study=PDFOutline(),methods=PDFOutline(),results=PDFOutline()
                study.label="Study";study.destination=PDFDestination(page:authored.page(at:0)!,at:CGPoint(x:0,y:792))
                methods.label="Methods";methods.action=PDFActionGoTo(destination:PDFDestination(page:authored.page(at:1)!,at:CGPoint(x:0,y:700)))
                results.label="Results";results.destination=PDFDestination(page:authored.page(at:2)!,at:CGPoint(x:0,y:700))
                study.insertChild(methods,at:0);study.insertChild(results,at:1);root.insertChild(study,at:0);authored.outlineRoot=root
                guard authored.write(to:pdfURL) else{throw Failure.check("PDF fixture write")}
                let plain=PDFDocument(data:data as Data)!
                try check(OutlineNode.pdf(plain).isEmpty,"PDF without embedded outline does not fabricate a directory")
                let mdURL=folder.appendingPathComponent("Search.md")
                try ("# Search test\n\nRNA search and **RNA** markup.\n\nLiteral [RNA] and中文内容.\n\n## Methods\n\n### Details\n\n"+(0..<24).map{"Paragraph \($0): bookmark position and long reading content.\n\n"}.joined()).write(to:mdURL,atomically:true,encoding:.utf8)
                reader.openFiles([pdfURL,mdURL]);await pause()
                let pdfTab=reader.activeTab!,pdf=reader.pdf!,doc=pdf.document!
                try check(reader.outlineVisible && reader.navigationSplit.arrangedSubviews.first === reader.outlineHost && reader.outlineHost.frame.width>=200,"directory sidebar is visible on the left at startup")
                await key(reader,3,"f",.command)
                try check(reader.documentSearch.isVisible && reader.documentSearch.bar.field.currentEditor() != nil,"Command + F opens and focuses document search")
                try await query(reader,"rNa")
                try check(reader.documentSearch.count==6 && pdf.highlightedSelections?.count==6,"PDF search finds and highlights case-insensitive matches across pages")
                try check(reader.bubble.superview==nil && reader.source.isEmpty,"search navigation does not trigger translation")
                let start=reader.documentSearch.index
                reader.documentSearch.step(-1)
                try check(reader.documentSearch.index==(start+5)%6,"previous result wraps around")
                reader.documentSearch.step(1)
                try check(reader.documentSearch.index==start,"next result returns to original match")
                try await query(reader,"Alpha [RNA]")
                try check(reader.documentSearch.count==3,"PDF query treats punctuation literally")
                try await query(reader,"absent-98765")
                try check(reader.documentSearch.count==0 && reader.documentSearch.bar.status.stringValue=="没有匹配结果","missing query reports no matches")
                try await query(reader,"")
                try check(pdf.highlightedSelections?.isEmpty ?? true,"empty query removes search highlights")
                await key(reader,53,"\u{1b}",[])
                try check(!reader.documentSearch.isVisible,"Escape closes find bar")
                reader.window.makeFirstResponder(pdf)
                await key(reader,3,"f",.control)
                try check(reader.documentSearch.isVisible,"Control + F also works when document is focused")
                reader.documentSearch.close();reader.setSide(.translation);reader.window.makeFirstResponder(reader.manual.input)
                await key(reader,3,"f",.control)
                try check(!reader.documentSearch.isVisible,"Control + F leaves sidebar text editing alone")
                reader.setSide(.none)
                pdf.go(to:doc.page(at:1)!);await pause()
                reader.bookmarks.addCurrent()
                try check(reader.bookmarks.items.count==1,"current PDF position can be bookmarked with one action")
                let pdfBookmark=reader.bookmarks.items[0]
                if case let .pdf(position)=pdfBookmark.destination {try check(position.page==1,"PDF bookmark stores the current page")}
                reader.bookmarks.addCurrent()
                try check(reader.bookmarks.items.count==1,"adding the same PDF page twice avoids duplicates")
                pdf.go(to:doc.page(at:2)!);await pause();reader.bookmarks.reveal(pdfBookmark.id);await pause()
                try check(pdf.currentPage===doc.page(at:1),"bookmark jumps back to saved PDF page")
                try check(try BookmarkStore(library.base).read(pdfTab.entry.id).count==1,"bookmarks survive a fresh store reload")
                reader.setOutlineVisible(true);await pause()
                try check(reader.outlineVisible && reader.bookmarks.panel.view.isDescendant(of:reader.outlineHost) && reader.bookmarks.panel.tabs.selectedSegment==0,"article directory is embedded in a fixed left sidebar")
                try check(reader.bookmarks.outline.count==1 && reader.bookmarks.outline[0].children.map(\.title)==["Methods","Results"],"PDF directory preserves native section hierarchy and action destinations")
                let tree=reader.bookmarks.panel.directory.tree,outlineRoot=reader.bookmarks.outline[0]
                try check(tree.numberOfRows==3 && tree.level(forItem:outlineRoot.children[0])==1,"outline view displays the expanded chapter hierarchy")
                tree.collapseItem(outlineRoot)
                try check(tree.numberOfRows==1,"chapter groups can collapse")
                tree.expandItem(outlineRoot)
                try check(tree.numberOfRows==3,"chapter groups can expand again")
                let pdfSection=reader.bookmarks.outline[0].children[1]
                let pdfMethods=reader.bookmarks.outline[0].children[0]
                tree.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false);await pause()
                try check(pdf.currentPage===doc.page(at:2) && reader.outlineVisible,"selecting a chapter navigates while keeping the left sidebar visible")
                reader.bookmarks.revealSection(pdfMethods);await pause()
                try check(pdf.currentPage===doc.page(at:1),"PDF GoTo action resolves to the correct chapter")
                reader.setOutlineVisible(true);await pause()
                reader.bookmarks.panel.tabs.selectedSegment=1;reader.bookmarks.panel.selectTab()
                try check(reader.bookmarks.panel.directory.isHidden && !reader.bookmarks.panel.add.isHidden,"manual bookmarks are available in the secondary tab")
                reader.toggleBookmarks();reader.toggleBookmarks();await pause()
                try check(reader.bookmarks.panel.tabs.selectedSegment==0,"reopening bookmarks returns to the directory")
                reader.setOutlineVisible(false)
                reader.showFind();try await query(reader,"RNA")
                reader.selectTab(reader.tabs[1].entry.id)
                try await wait("first Markdown visit with open search"){!reader.documentSearch.isSearching && reader.documentSearch.count==3}
                try check(reader.documentSearch.count==3,"open search resumes after a new Markdown tab finishes loading")
                try check(reader.bookmarks.items.isEmpty,"bookmarks stay separate for each document")
                let md=reader.markdown!
                try await wait("Markdown outline"){reader.bookmarks.outline.first?.children.first?.children.first?.title=="Details"}
                try check(reader.bookmarks.outline[0].title=="Search test" && reader.bookmarks.outline[0].children[0].title=="Methods","Markdown directory follows heading levels")
                let markdownSection=reader.bookmarks.outline[0].children[0].children[0]
                reader.bookmarks.revealSection(pdfSection);await pause()
                try check(reader.markdown === md,"a stale PDF section cannot navigate another tab")
                reader.bookmarks.revealSection(markdownSection);await pause()
                let headingTop=try await md.web.evaluateJavaScript("document.querySelector('h3').getBoundingClientRect().top") as! Double
                try check(abs(headingTop-40)<3,"Markdown section jumps to the original heading")
                try await wait("Markdown rendering"){md.rendered}
                reader.showFind();try await query(reader,"rNa")
                try check(reader.documentSearch.count==3,"Markdown search includes text inside markup")
                let highlights=try await md.web.evaluateJavaScript("CSS.highlights.get('hy-find').size") as? Int
                try check(highlights==3,"Markdown search uses highlights without changing the text layer")
                reader.documentSearch.step(-1)
                try check(reader.documentSearch.index==2,"Markdown previous result wraps")
                let exactText=try await md.web.evaluateJavaScript("findRanges[findIndex].toString()") as? String
                try check(exactText=="RNA","active Markdown result maps to original text")
                try await query(reader,"[RNA]")
                try check(reader.documentSearch.count==1,"Markdown query escapes regex punctuation")
                try await query(reader,"中文内容")
                try check(reader.documentSearch.count==1,"Markdown search supports Chinese")
                try await query(reader,"RNA")
                try reader.notes.mark(.underline,ranges:[Passage(page:0,start:11,length:3)],document:reader.entry!.id)
                reader.redrawMarks();await pause()
                let live=try await md.web.evaluateJavaScript("[...CSS.highlights.get('hy-find')].every(range=>range.startContainer.isConnected)") as? Bool
                try check(live==true,"applying annotations keeps search ranges attached to live text")
                _=try await md.web.evaluateJavaScript("window.scrollTo(0,700)")
                await pause();reader.bookmarks.addCurrent()
                try await wait("Markdown bookmark"){reader.bookmarks.items.count==1}
                let markdownBookmark=reader.bookmarks.items[0]
                let y=try await md.web.evaluateJavaScript("window.scrollY") as! Double
                _=try await md.web.evaluateJavaScript("window.scrollTo(0,0)")
                reader.bookmarks.reveal(markdownBookmark.id);await pause()
                let restored=try await md.web.evaluateJavaScript("window.scrollY") as! Double
                try check(abs(restored-y)<4,"Markdown bookmark restores the reading position")
                // A query completion belonging to the old tab must not update the new one.
                reader.showFind();reader.documentSearch.bar.field.stringValue="Paragraph";reader.documentSearch.run()
                reader.selectTab(pdfTab.entry.id)
                try await wait("search tab switch"){!reader.documentSearch.isSearching};await pause()
                try check(reader.documentSearch.count==0 && reader.bookmarks.items.count==1,"switching tabs refreshes search and restores that document's bookmarks")
                reader.documentSearch.close();reader.bookmarks.remove(pdfBookmark.id)
                try check(reader.bookmarks.items.isEmpty && (try BookmarkStore(library.base).read(pdfTab.entry.id)).isEmpty,"bookmark removal persists")
                try check((try BookmarkStore(library.base).read(reader.tabs[1].entry.id)).count==1,"removing a bookmark preserves other documents")
                try check(reader.window.title.contains("Hy-translator"),"window title uses the new product name")
                print("NAVIGATION SMOKE OK");fflush(stdout)
                if CommandLine.arguments.contains("--preview") {retainedReader=reader;reader.setOutlineVisible(true)}
                else {reader.stop();app.terminate(nil)}
            } catch {print("FAIL",error);fflush(stdout);reader.stop();exit(1)}
        }
        app.run()
    }
}
