import AppKit
import PDFKit
import NaturalLanguage

enum MarkKind: String, Codable, CaseIterable {
    case highlight, underline, strike
    var title:String {
        switch self { case .highlight:return "高亮"; case .underline:return "下划线"; case .strike:return "删除线" }
    }
    var pdfType: PDFAnnotationSubtype {
        switch self { case .highlight:return .highlight; case .underline:return .underline; case .strike:return .strikeOut }
    }
}
struct Passage: Codable, Equatable {
    let page:Int, start:Int, length:Int
    var range:NSRange { NSRange(location:start,length:length) }
}
struct TextMark: Codable, Equatable {
    let kind:MarkKind, span:Passage
}
struct Excerpt {
    let text:String, example:String, spans:[Passage]
    var termContext:String {
        text.count<=120 && text.split(separator:" ").count<=8 && example.count<=1600 ? example : ""
    }
}
struct Word: Codable, Identifiable {
    let id:String, term:String, document:String
    var meaning:String, example:String, generated:Bool
}
func oneLine(_ s:String)->String {
    s.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
}
func sentence(in text:String, around range:NSRange)->String {
    guard let location=Range(range,in:text)?.lowerBound, location<text.endIndex else { return "" }
    let tokenizer=NLTokenizer(unit:.sentence); tokenizer.string=text; tokenizer.setLanguage(.english)
    return oneLine(String(text[tokenizer.tokenRange(at:location)]))
}

struct NoteFile: Codable {
    var words:[Word] = []
    var marks:[String:[TextMark]] = [:]
}
final class ReadingNotes {
    let file:URL
    private(set) var data=NoteFile()
    private var loadError:Error?
    init(base:URL) {
        file=base.appendingPathComponent("reading-notes.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do { data=try JSONDecoder().decode(NoteFile.self,from:Data(contentsOf:file)) } catch { loadError=error }
        }
    }
    func edit(_ change:(inout NoteFile)->Void)throws {
        if let loadError { throw loadError }
        var next=data; change(&next)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(next).write(to:file,options:.atomic)
        data=next
    }
    func mark(_ kind:MarkKind?, ranges:[Passage], document:String)throws {
        try edit { notes in
            var marks=notes.marks[document] ?? []
            for span in ranges where span.length>0 {
                if let kind {
                    var merged=span.range
                    marks.removeAll { item in
                        guard item.kind==kind, item.span.page==span.page else { return false }
                        let r=item.span.range
                        guard NSMaxRange(r)>=merged.location && NSMaxRange(merged)>=r.location else {return false}
                        merged=NSUnionRange(merged,r); return true
                    }
                    marks.append(TextMark(kind:kind,span:Passage(page:span.page,start:merged.location,length:merged.length)))
                } else {
                    marks=marks.flatMap { item -> [TextMark] in
                        let r=item.span.range, overlap=NSIntersectionRange(r,span.range)
                        guard item.span.page==span.page, overlap.length>0 else { return [item] }
                        return [(r.location,overlap.location),(NSMaxRange(overlap),NSMaxRange(r))].compactMap { a,b in
                            b>a ? TextMark(kind:item.kind,span:Passage(page:span.page,start:a,length:b-a)) : nil
                        }
                    }
                }
            }
            notes.marks[document]=marks
        }
    }
}

extension PDFView {
    func excerpt()->Excerpt? {
        guard let sel=currentSelection,let text=sel.string,let doc=document else { return nil }
        var ranges=[Passage](), example=""
        for page in sel.pages {
            for i in 0..<sel.numberOfTextRanges(on:page) {
                let r=sel.range(at:i,on:page)
                guard r.location != NSNotFound,r.length>0,NSMaxRange(r)<=page.numberOfCharacters else {continue}
                ranges.append(Passage(page:doc.index(for:page),start:r.location,length:r.length))
                if example.isEmpty,let content=page.string { example=sentence(in:content,around:r) }
            }
        }
        return ranges.isEmpty ? nil : Excerpt(text:oneLine(text),example:example,spans:ranges)
    }
    func renderMarks(_ marks:[TextMark], replacing previous:inout [PDFAnnotation]) {
        previous.forEach { $0.page?.removeAnnotation($0) }
        previous.removeAll()
        for mark in marks {
            guard let doc=document,mark.span.page>=0,mark.span.page<doc.pageCount,
                  let page=doc.page(at:mark.span.page),NSMaxRange(mark.span.range)<=page.numberOfCharacters,
                  let sel=page.selection(for:mark.span.range) else {continue}
            for line in sel.selectionsByLine() {
                let box=line.bounds(for:page)
                guard !box.isEmpty, !box.isNull else {continue}
                let annotation=PDFAnnotation(bounds:box,forType:mark.kind.pdfType,withProperties:nil)
                annotation.color=mark.kind == .highlight ? NSColor.systemYellow.withAlphaComponent(0.42) : (mark.kind == .strike ? .systemRed : .systemBlue)
                annotation.shouldPrint=false
                page.addAnnotation(annotation); previous.append(annotation)
            }
        }
        needsDisplay=true
    }
}
