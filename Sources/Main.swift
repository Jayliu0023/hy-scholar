import AppKit

final class App: NSObject, NSApplicationDelegate {
    var reader: Reader!
    var queued = [URL]()
    let recents = NSMenu(title:"最近打开")
    func applicationDidFinishLaunching(_ notification:Notification) {
        signal(SIGPIPE,SIG_IGN)
        reader = Reader()
        reader.recentChanged = { [weak self] in self?.refreshRecent() }
        let menu=NSMenu()
        func submenu(_ name:String)->NSMenu {
            let top=NSMenuItem(); menu.addItem(top); let sub=NSMenu(title:name); top.submenu=sub; return sub
        }
        func add(_ menu:NSMenu,_ name:String,_ action:Selector,_ key:String,_ target:AnyObject?) {
            let item=menu.addItem(withTitle:name,action:action,keyEquivalent:key); item.target=target
        }
        let app=submenu("文译阅读器")
        add(app,"关于文译阅读器",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),"",NSApp)
        app.addItem(.separator()); add(app,"隐藏文译阅读器",#selector(NSApplication.hide(_:)),"h",NSApp)
        add(app,"退出文译阅读器",#selector(NSApplication.terminate(_:)),"q",NSApp)
        let file=submenu("文件"); add(file,"打开…",#selector(Reader.choose),"o",reader)
        add(file,"在新标签页中打开…",#selector(Reader.choose),"t",reader)
        let recent=NSMenuItem(title:"最近打开",action:nil,keyEquivalent:""); recent.submenu=recents; file.addItem(recent)
        add(file,"关闭当前标签页",#selector(Reader.closeCurrentTab),"w",reader)
        let closeWindow=file.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        closeWindow.keyEquivalentModifierMask=[.command,.shift]
        let edit=submenu("编辑")
        add(edit,"剪切",#selector(NSText.cut(_:)),"x",nil); add(edit,"复制",#selector(NSText.copy(_:)),"c",nil); add(edit,"粘贴",#selector(NSText.paste(_:)),"v",nil)
        add(edit,"全选",#selector(NSText.selectAll(_:)),"a",nil)
        let view=submenu("显示")
        add(view,"独立翻译",#selector(Reader.toggleTranslation),"",reader)
        add(view,"收藏词汇",#selector(Reader.toggleWords),"",reader)
        add(view,"Note 笔记",#selector(Reader.toggleNotes),"",reader)
        let trm=view.addItem(withTitle:"右侧终端",action:#selector(Reader.toggleTerminal),keyEquivalent:"\u{60}")
        trm.keyEquivalentModifierMask=[.control]; trm.target=reader
        let next=view.addItem(withTitle:"下一个标签页",action:#selector(Reader.nextTab),keyEquivalent:"\t")
        next.keyEquivalentModifierMask=[.control]; next.target=reader
        let previous=view.addItem(withTitle:"上一个标签页",action:#selector(Reader.previousTab),keyEquivalent:"\t")
        previous.keyEquivalentModifierMask=[.control,.shift]; previous.target=reader
        add(view,"放大 PDF",#selector(zoomIn),"=",self); add(view,"缩小 PDF",#selector(zoomOut),"-",self)
        let win=submenu("窗口"); add(win,"最小化",#selector(NSWindow.performMiniaturize(_:)),"m",nil); NSApp.windowsMenu=win
        NSApp.mainMenu=menu
        refreshRecent()
        reader.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        reader.restoreSession(openLast:queued.isEmpty)
        if !queued.isEmpty { reader.openFiles(queued); queued.removeAll() }
    }
    func refreshRecent() {
        recents.removeAllItems()
        for doc in reader.library.entries.prefix(15) {
            let item=recents.addItem(withTitle:doc.name,action:#selector(openRecent(_:)),keyEquivalent:"")
            item.target=self; item.representedObject=doc.id; item.toolTip=doc.original.path
        }
    }
    @objc func openRecent(_ item:NSMenuItem) {
        if let id=item.representedObject as? String,let doc=reader.library.entries.first(where:{$0.id==id}) { reader.restore(doc) }
    }
    @objc func zoomIn() { reader.pdf?.zoomIn(nil) }
    @objc func zoomOut() { reader.pdf?.zoomOut(nil) }
    func application(_ sender:NSApplication,open urls:[URL]) {
        if let reader { reader.openFiles(urls); reader.window.makeKeyAndOrderFront(nil) } else { queued.append(contentsOf:urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationWillTerminate(_ notification:Notification) { reader?.stop() }
}

#if !READER_TEST
@main enum Entry {
    static func main() {
        let app=NSApplication.shared, delegate=App()
        app.setActivationPolicy(.regular); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
