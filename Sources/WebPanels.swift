import AppKit
import WebKit
import UniformTypeIdentifiers

let resources = Bundle.main.resourceURL!.appendingPathComponent("web")
func jsonString(_ s: String) -> String {
    return String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
}

final class MessageLink: NSObject, WKScriptMessageHandler {
    let action: (WKScriptMessage) -> Void
    init(_ action: @escaping (WKScriptMessage) -> Void) { self.action = action }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        action(message)
    }
}

final class LocalWeb: NSObject, WKNavigationDelegate {
    let page: String
    var ready: (() -> Void)?
    init(_ page: String) { self.page = page }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready?() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = action.request.url?.standardizedFileURL == resources.appendingPathComponent(page).standardizedFileURL
        decisionHandler(allowed ? .allow : .cancel)
    }
}

final class Images: NSObject, WKURLSchemeHandler {
    var directory: URL?
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = directory?.resolvingSymlinksInPath(),
              let rel = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let file = root.appendingPathComponent(String(rel.drop(while: {$0 == "/"}))).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        task.didReceive(URLResponse(url: url, mimeType: type.preferredMIMEType, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class MarkdownPane {
    let web: WKWebView
    let images = Images()
    let nav = LocalWeb("document.html")
    var selection: ((String, NSRect) -> Void)?
    private(set) var excerpt:Excerpt?
    private var marks:[TextMark]=[]
    var notebook=Notebook(), geometry=WebNoteGeometry()
    var onGeometry:(()->Void)?
    var onContentReady:(()->Void)?
    private(set) var contentReady=false
    private(set) var rendered = false
    private var text = ""
    private(set) var revision = UUID().uuidString

    init() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(images, forURLScheme: "reader-asset")
        web = WKWebView(frame: .zero, configuration: cfg)
        cfg.userContentController.add(MessageLink { [weak self] msg in
            guard let self, let body = msg.body as? [String:Any], body["id"] as? String == self.revision,
                  let text = body["text"] as? String else { return }
            let r = NSRect(x: body["x"] as? CGFloat ?? 0, y: body["y"] as? CGFloat ?? 0,
                           width: body["w"] as? CGFloat ?? 0, height: body["h"] as? CGFloat ?? 0)
            var rect = r
            if !self.web.isFlipped { rect.origin.y = self.web.bounds.height - r.maxY }
            if let start=body["start"] as? Int, let length=body["length"] as? Int, start>=0, length>0, !text.isEmpty {
                self.excerpt=Excerpt(text:oneLine(text),example:oneLine(body["example"] as? String ?? ""),spans:[Passage(page:0,start:start,length:length)])
            } else { self.excerpt=nil }
            self.selection?(text, rect)
        }, name: "selection")
        cfg.userContentController.add(MessageLink { [weak self] msg in self?.receiveGeometry(msg.body) },name:"marginGeometry")
        nav.ready = { [weak self] in self?.rendered = true; self?.render() }
        web.navigationDelegate = nav
        web.loadFileURL(resources.appendingPathComponent(nav.page), allowingReadAccessTo: resources)
    }
    func set(_ content: String, directory: URL, marks:[TextMark]) {
        excerpt=nil; contentReady=false; geometry=WebNoteGeometry(); self.marks=marks
        revision = UUID().uuidString; text = content; images.directory = directory; render()
    }
    private var markData:[[String:Any]] { marks.map { ["kind":$0.kind.rawValue,"span":["start":$0.span.start,"length":$0.span.length]] } }
    func renderMarks(_ marks:[TextMark]) {
        self.marks=marks
        if rendered { web.callAsyncJavaScript("applyMarks(id,marks)",arguments:["id":revision,"marks":markData],in:nil,in:.page) { _ in } }
    }
    private func render() {
        guard rendered else { return }
        let id=revision
        web.callAsyncJavaScript("renderPaper(text,id,marks)", arguments:["text":text,"id":id,"marks":markData], in:nil, in:.page) { [weak self] result in
            guard let self,self.revision==id,case .success=result else{return}
            self.contentReady=true;self.pushNotebook();self.onContentReady?()
        }
    }
}

final class TerminalPane {
    let web: WKWebView
    let nav = LocalWeb("terminal.html")
    var directory = FileManager.default.homeDirectoryForCurrentUser
    private var master: FileHandle?
    private var pid: pid_t = 0
    private var cols = 80, rows = 24
    private var generation = 0
    private let writer = DispatchQueue(label: "local.wenyi.pty.write")
    private var stopping = false
    var running: Bool { return pid > 0 }

    init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = nav
        config.userContentController.add(MessageLink { [weak self] in self?.message($0) }, name: "pty")
        web.loadFileURL(resources.appendingPathComponent(nav.page), allowingReadAccessTo: resources)
    }
    private func message(_ msg: WKScriptMessage) {
        guard !stopping, let body = msg.body as? [String:Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "size", "ready":
            if let size = body["value"] as? [Int], size.count == 2 {
                cols = min(1000,max(2,size[0])); rows = min(1000,max(1,size[1]))
                if let handle = master { reader_resize(handle.fileDescriptor, Int32(rows), Int32(cols)) }
            }
            if kind == "ready" && !running { start() }
        case "input":
            guard let text = body["value"] as? String else { return }
            if let handle = master {
                let data = Data(text.utf8)
                writer.async { try? handle.write(contentsOf: data) }
            } else if text == "\r" { start() }
        default: break
        }
    }
    private func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var fd: Int32 = -1
        let child = reader_spawn(shell, directory.path, Int32(rows), Int32(cols), &fd)
        guard child > 0 else { web.evaluateJavaScript("ended()"); return }
        generation += 1
        let tag = generation, handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        master = handle; pid = child
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bytes = [UInt8](repeating:0,count:32768)
            while true {
                let count = read(fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                let data = Data(bytes.prefix(count)).base64EncodedString()
                DispatchQueue.main.sync {
                    if let self, self.generation == tag { self.web.evaluateJavaScript("receive('" + data + "')") }
                }
            }
            var status: Int32 = 0
            while waitpid(child,&status,0) < 0 && errno == EINTR {}
            DispatchQueue.main.async {
                guard let self, self.generation == tag else { return }
                self.master = nil; self.pid = 0
                self.web.evaluateJavaScript("ended()")
            }
            withExtendedLifetime(handle) {}
        }
    }
    func focus() {
        web.window?.makeFirstResponder(web)
        web.evaluateJavaScript("if(typeof term !== 'undefined'){fit();term.focus()}")
    }
    func stop() {
        stopping = true; generation += 1
        if let handle = master, pid > 0 { reader_hangup(handle.fileDescriptor, pid) }
        master = nil; pid = 0
    }
}
