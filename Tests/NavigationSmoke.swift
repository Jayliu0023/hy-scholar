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
                context.closePDF();try data.write(to:pdfURL)
                let mdURL=folder.appendingPathComponent("Search.md")
                try ("# Search test\n\nRNA search and **RNA** markup.\n\nLiteral [RNA] and中文内容.\n\n"+(0..<24).map{"Paragraph \($0): bookmark position and long reading content.\n\n"}.joined()).write(to:mdURL,atomically:true,encoding:.utf8)
                reader.openFiles([pdfURL,mdURL]);await pause()
                let pdfTab=reader.activeTab!,pdf=reader.pdf!,doc=pdf.document!
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
                reader.toggleBookmarks();await pause()
                try check(reader.bookmarks.popover.isShown,"left bookmark button opens a bookmark list")
                reader.bookmarks.popover.close()
                reader.showFind();try await query(reader,"RNA")
                reader.selectTab(reader.tabs[1].entry.id)
                try await wait("first Markdown visit with open search"){!reader.documentSearch.isSearching && reader.documentSearch.count==3}
                try check(reader.documentSearch.count==3,"open search resumes after a new Markdown tab finishes loading")
                try check(reader.bookmarks.items.isEmpty,"bookmarks stay separate for each document")
                let md=reader.markdown!
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
                if CommandLine.arguments.contains("--preview") {retainedReader=reader;reader.documentSearch.bar.field.stringValue="RNA";reader.showFind();reader.bookmarks.addCurrent();reader.toggleBookmarks()}
                else {reader.stop();app.terminate(nil)}
            } catch {print("FAIL",error);fflush(stdout);reader.stop();exit(1)}
        }
        app.run()
    }
}
