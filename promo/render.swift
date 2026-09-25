// Offline renderer for promo.html.
//
//   swiftc -O -o out/render render.swift
//   out/render promo.html out/sample --stills 1.2,3.0,5.9     → PNG stills for review
//   out/render promo.html out/sample                          → frames/%05d.png + audio.wav
//
// The page exposes window.__frame(t) → PNG data URL and window.__audioWav() → base64 WAV, both
// deterministic, so every export of the same source is identical. make.sh muxes them with ffmpeg.
import AppKit
import WebKit

struct Options {
    var html: URL
    var out: URL
    var stills: [Double]? = nil
    var fps = 30
}

func parseArgs() -> Options {
    let a = CommandLine.arguments
    guard a.count >= 3 else {
        FileHandle.standardError.write("usage: render <page.html> <outdir> [--stills t1,t2,…] [--fps N]\n".data(using: .utf8)!)
        exit(64)
    }
    var o = Options(html: URL(fileURLWithPath: a[1]).standardizedFileURL, out: URL(fileURLWithPath: a[2]).standardizedFileURL)
    var i = 3
    while i < a.count {
        switch a[i] {
        case "--stills": o.stills = a[i + 1].split(separator: ",").compactMap { Double($0) }; i += 2
        case "--fps": o.fps = Int(a[i + 1]) ?? 30; i += 2
        default: i += 1
        }
    }
    return o
}

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let o: Options
    let web: WKWebView

    init(_ o: Options) {
        self.o = o
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), configuration: WKWebViewConfiguration())
        super.init()
        web.navigationDelegate = self
    }

    func start() { web.loadFileURL(o.html, allowingReadAccessTo: o.html.deletingLastPathComponent()) }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.run() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("load failed: \(error)"); exit(2)
    }

    func js(_ s: String) async -> Any? { try? await web.evaluateJavaScript(s) }

    func frame(_ t: Double) async -> Data {
        let r = await js("window.__frame(\(t))") as? String ?? ""
        return Data(base64Encoded: r.components(separatedBy: ",").last ?? "") ?? Data()
    }

    func run() async {
        for _ in 0..<400 where (await js("window.__ready === true")) as? Bool != true {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard (await js("window.__ready === true")) as? Bool == true else { print("page never became ready"); exit(3) }
        let duration = (await js("window.__duration")) as? Double ?? 0
        let fm = FileManager.default
        try? fm.createDirectory(at: o.out, withIntermediateDirectories: true)

        if let stills = o.stills {
            for t in stills {
                try? await frame(t).write(to: o.out.appendingPathComponent(String(format: "still-%05.2f.png", t)))
            }
            print("stills: \(stills.count) → \(o.out.path)"); exit(0)
        }

        let framesDir = o.out.appendingPathComponent("frames")
        try? fm.removeItem(at: framesDir)
        try? fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let n = Int((duration * Double(o.fps)).rounded(.down)), start = Date()
        for i in 0..<n {
            let d = await frame(Double(i) / Double(o.fps))
            guard !d.isEmpty else { print("empty frame \(i)"); exit(5) }
            try? d.write(to: framesDir.appendingPathComponent(String(format: "%05d.png", i)))
            if i % 90 == 0 { print("frame \(i)/\(n)") }
        }
        print("frames: \(n) in \(Int(Date().timeIntervalSince(start)))s")

        do {
            let r = try await web.callAsyncJavaScript("return await window.__audioWav()", arguments: [:], in: nil, contentWorld: .page)
            guard let b64 = r as? String, let wav = Data(base64Encoded: b64) else { print("audio: nothing returned"); exit(4) }
            try wav.write(to: o.out.appendingPathComponent("audio.wav"))
            print("audio.wav: \(wav.count / 1024) KB")
        } catch { print("audio failed: \(error)"); exit(4) }
        exit(0)
    }
}

// Top-level code in a multi-file-capable build isn't main-actor isolated; hop explicitly.
let options = parseArgs()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let renderer = Renderer(options)
    renderer.start()
    withExtendedLifetime(renderer) { app.run() }
}
