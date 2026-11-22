import AppKit

enum NoteInk:String,Codable,CaseIterable {
    case gray,blue,green,orange,purple,red
    var color:NSColor {
        switch self {
        case .gray:return .systemGray
        case .blue:return .systemBlue
        case .green:return .systemGreen
        case .orange:return .systemOrange
        case .purple:return .systemPurple
        case .red:return .systemRed
        }
    }
    var title:String {
        switch self {
        case .gray:return "灰色"; case .blue:return "蓝色"; case .green:return "绿色"
        case .orange:return "橙色"; case .purple:return "紫色"; case .red:return "红色"
        }
    }
}

struct BlockPoint:Codable {
    let block:Int
    let x:Double, y:Double
}
enum RegionLocation:Codable {
    case pdf(page:Int,rect:CGRect)
    case markdown(BlockPoint,BlockPoint)
}
struct NoteOrder:Codable,Comparable {
    let page:Int
    let offset:Double
    static func <(a:Self,b:Self)->Bool {a.page==b.page ? a.offset<b.offset : a.page<b.page}
}
struct MarkedRegion:Codable {
    var id=UUID().uuidString
    let location:RegionLocation, order:NoteOrder
    var ink:NoteInk = .gray
}
enum NoteAnchor:Codable {
    case text([Passage])
    case region(String)
}
struct MarginNote:Codable {
    var id=UUID().uuidString
    let anchor:NoteAnchor, quote:String, order:NoteOrder
    var text="", ink:NoteInk = .gray
}
struct Notebook:Codable {
    var notes=[MarginNote](), regions=[MarkedRegion]()
}
final class NotebookStore {
    let folder:URL
    init(_ base:URL) {folder=base.appendingPathComponent("document-notes",isDirectory:true)}
    private func url(_ document:String)->URL {folder.appendingPathComponent(document+".json")}
    func read(_ document:String)throws->Notebook {
        let file=url(document)
        do {return try JSONDecoder().decode(Notebook.self,from:Data(contentsOf:file))}
        catch let e as NSError where e.domain==NSCocoaErrorDomain && e.code==NSFileReadNoSuchFileError {return Notebook()}
    }
    func change(_ document:String,_ edit:(inout Notebook)->Void)throws->Notebook {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var result:Result<Notebook,Error>?
        var coordination:NSError?
        NSFileCoordinator().coordinate(writingItemAt:url(document),options:.forMerging,error:&coordination) { file in
            result=Result {
                var book=try read(document); edit(&book)
                try JSONEncoder().encode(book).write(to:file,options:.atomic)
                return book
            }
        }
        if let coordination {throw coordination}
        return try result!.get()
    }
}
