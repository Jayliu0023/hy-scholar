import AppKit

final class Translator {
    private var process: Process?
    private var input: FileHandle?
    private var serial = 0
    typealias Update = (String, Bool, Bool) -> Void
    private struct Request {
        let lane: String, text: String, context: String, example: Bool, update: Update
    }
    private var waiting = [Request]()
    private var active: Request?
    private var result = ""

    func cancel(_ lane: String) {
        waiting.removeAll { $0.lane == lane }
        guard active?.lane == lane else { return }
        active = nil; serial += 1
        try? send(["id":serial])
        startNext()
    }

    func translate(_ text: String, lane: String, context: String = "", example: Bool = false, update: @escaping Update) {
        cancel(lane)
        waiting.append(Request(lane:lane,text:text,context:context,example:example,update:update))
        startNext()
    }

    private func startNext() {
        guard active == nil, !waiting.isEmpty else { return }
        let request=waiting.removeFirst()
        active=request; result=""; serial += 1
        do {
            if process == nil { try launch() }
            try send(["id":serial,"text":request.text,"example":request.example,"context":request.context])
        } catch {
            finish("无法启动本地 Hy-MT2 翻译引擎。请检查模型安装。",error:true)
        }
    }
    private func finish(_ text:String,error:Bool) {
        let callback=active?.update
        active=nil
        callback?(text,true,error)
        startNext()
    }

    private func send(_ value: [String:Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input?.write(contentsOf: data)
    }

    private func launch() throws {
        let job = Process(), commands = Pipe(), replies = Pipe()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-u", Bundle.main.resourceURL!.appendingPathComponent("translate.py").path]
        job.standardInput = commands
        job.standardOutput = replies
        job.standardError = FileHandle.nullDevice
        try job.run()
        process = job
        input = commands.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = replies.fileHandleForReading
            var buffer = Data()
            while true {
                let bytes = reader.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    if let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String:Any] {
                        DispatchQueue.main.async { self?.receive(entry) }
                    }
                }
            }
            job.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.process === job else { return }
                self.input = nil; self.process = nil
                self.finish("本地翻译服务已退出，请重试。", error:true)
            }
        }
    }

    private func receive(_ entry: [String:Any]) {
        guard let active, entry["id"] as? Int == serial else { return }
        if let error = entry["error"] as? String {
            finish(error,error:true)
        } else if let piece = entry["delta"] as? String {
            result += piece
            active.update(result,false,false)
        } else if entry["done"] as? Bool == true {
            finish(result.isEmpty ? "未生成结果，请重试。" : result,error:result.isEmpty)
        }
    }

    func stop() {
        waiting.removeAll(); active=nil
        serial += 1
        try? input?.close()
        input = nil; process = nil
    }
}
