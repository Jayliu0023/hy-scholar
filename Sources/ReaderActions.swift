import AppKit

extension Reader {
    var currentExcerpt:Excerpt? { pdf?.excerpt() ?? markdown?.excerpt }

    func selectionMenu(for passage:Excerpt)->NSMenu {
        let menu=NSMenu()
        func add(_ title:String,_ action:Selector,_ key:String) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"")
            item.target=self
            item.representedObject=MenuSelection(document:entry?.id ?? "",passage:passage,action:key)
            menu.addItem(item)
        }
        add("复制",#selector(contextAction(_:)),"copy")
        let saved=notes.data.words.contains { sameTerm($0.term,passage.text) }
        add(saved ? "查看已收藏词汇" : "收藏词汇",#selector(contextAction(_:)),"star")
        menu.addItem(.separator())
        for kind in MarkKind.allCases {add(kind.title,#selector(contextAction(_:)),kind.rawValue)}
        add("清除所选标记",#selector(contextAction(_:)),"erase")
        return menu
    }
    func popupSelection(_ event:NSEvent)->Bool {
        let pos=pageHost.convert(event.locationInWindow,from:nil)
        guard pageHost.bounds.contains(pos),entry != nil else {return false}
        if bubble.superview != nil, bubble.bounds.contains(bubble.convert(event.locationInWindow,from:nil)) {return false}
        guard let sel=currentExcerpt,!sel.text.isEmpty else {return false}
        NSMenu.popUpContextMenu(selectionMenu(for:sel), with:event, for:pageHost)
        return true
    }
    @objc func contextAction(_ item:NSMenuItem) {
        guard let choice=item.representedObject as? MenuSelection,entry?.id==choice.document else {return}
        switch choice.action {
        case "copy":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(choice.passage.text,forType:.string)
        case "star": saveWord(choice.passage)
        default:
            do {
                try notes.mark(MarkKind(rawValue:choice.action),ranges:choice.passage.spans,document:choice.document)
                redrawMarks()
                dismissBubble()
            } catch { noteError(error) }
        }
    }
    func redrawMarks() {
        guard let tab=activeTab else {return}
        let marks=notes.data.marks[tab.entry.id] ?? []
        if let pdf=tab.pdf { pdf.renderMarks(marks,replacing:&tab.annotations) }
        else { tab.markdown?.renderMarks(marks) }
    }
    func noteError(_ error:Error) {
        let a=NSAlert(); a.messageText="无法保存阅读数据"; a.informativeText=error.localizedDescription
        a.beginSheetModal(for:window)
    }
    func sameTerm(_ a:String,_ b:String)->Bool {
        oneLine(a).localizedCaseInsensitiveCompare(oneLine(b)) == .orderedSame
    }
    func saveWord(_ passage:Excerpt) {
        let term=oneLine(passage.text)
        guard !term.isEmpty, let document=entry else {return}
        if notes.data.words.contains(where:{sameTerm($0.term,term)}) {setSide(.words); return}
        let sample=oneLine(passage.example)
        let useSample = !sample.isEmpty && sample.count<=1600 &&
           (!sameTerm(term,sample) || (sample.split(separator:" ").count>=3 && ".!?。！？".contains(sample.last!)))
        let word=Word(id:UUID().uuidString,term:term,document:document.name,
            meaning:source==term && translatedRanges==passage.spans && !busy && !failed ? result : "",example:useSample ? sample:"",generated:!useSample)
        do {
            try notes.edit { $0.words.insert(word,at:0) }
            setSide(.words)
        } catch { noteError(error) }
    }
    func refreshWords() { wordsPanel.show(notes.data.words,errors:wordErrors) }
    func completeWord(_ id:String) {
        guard let word=notes.data.words.first(where:{$0.id==id}),!pendingWords.contains(id),
              word.meaning.isEmpty || word.example.isEmpty else {return}
        pendingWords.insert(id); wordErrors[id]=nil
        let example = !word.meaning.isEmpty
        engine.translate(word.term,lane:id,context:word.generated ? "" : word.example,example:example) { [weak self] text,done,failed in
            guard let self,done else {return}
            self.pendingWords.remove(id)
            guard self.notes.data.words.contains(where:{$0.id==id}) else {return}
            if failed { self.wordErrors[id]=text; self.refreshWords(); return }
            do {
                try self.notes.edit { notes in
                    guard let i=notes.words.firstIndex(where:{$0.id==id}) else {return}
                    if example { notes.words[i].example=text } else { notes.words[i].meaning=text }
                }
                self.refreshWords(); self.completeWord(id)
            } catch { self.noteError(error) }
        }
    }
    func removeWord(_ id:String) {
        do {
            try notes.edit { $0.words.removeAll{$0.id==id} }
            engine.cancel(id); pendingWords.remove(id); wordErrors[id]=nil; refreshWords()
        } catch {noteError(error)}
    }
    func translateManual(_ text:String) {
        engine.translate(text,lane:"manual") { [weak self] result,done,error in
            self?.manual.show(result,done:done,error:error)
            if done {self?.saveDraft()}
        }
    }
    func saveDraft() {
        let draft=Draft(source:manual.input.string,result:manual.output.string,translatedFrom:manual.translatedFrom)
        do {
            try FileManager.default.createDirectory(at:library.base,withIntermediateDirectories:true)
            try JSONEncoder().encode(draft).write(to:library.base.appendingPathComponent("draft.json"),options:.atomic)
        } catch { noteError(error) }
    }
}
private struct MenuSelection {
    let document:String, passage:Excerpt, action:String
}
