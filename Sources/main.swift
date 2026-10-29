// Audrey Talk: the listening half of talk mode in A4's chat with Audrey (John 2026-10-28).
// A background app (no window, no Dock icon) so macOS asks for Microphone and Speech Recognition
// in its own name; Obsidian's own Info.plist has no speech key, so it cannot ask itself.
//
//   Audrey Talk.app --socket <path>   connects to the chat's socket and streams JSON lines:
//       {"type":"ready"} {"type":"partial","text":…} {"type":"final","text":…} {"type":"error","message":…}
//     and takes lines "pause", "resume", "reset" (drop what it has heard so far), "quit". Exits when the
//     socket closes. Only an Obsidian process may be on the other end.
//   Audrey Talk.app --file <audio>    self-check: prints what it hears in the file, then exits.
import AVFoundation
import Foundation
import Speech

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let silence: TimeInterval = 1.3 // a pause this long ends what John said

func authorize(_ done: @escaping (String?) -> Void) {
  SFSpeechRecognizer.requestAuthorization { st in
    guard st == .authorized else { return done("Speech recognition is not allowed for Audrey Talk (System Settings, Privacy).") }
    if args.contains("--file") { return done(nil) }
    AVCaptureDevice.requestAccess(for: .audio) { ok in done(ok ? nil : "The microphone is not allowed for Audrey Talk (System Settings, Privacy).") }
  }
}

func recognizer() -> SFSpeechRecognizer? {
  let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  return (r?.supportsOnDeviceRecognition ?? false) ? r : nil
}

if let file = arg("--file") {
  authorize { err in
    if let err { print("ERROR " + err); exit(1) }
    guard let r = recognizer() else { print("ERROR no on-device English recognition"); exit(1) }
    let req = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: file))
    req.requiresOnDeviceRecognition = true
    r.recognitionTask(with: req) { res, e in
      if let e { print("ERROR " + e.localizedDescription); exit(1) }
      if let res, res.isFinal { print(res.bestTranscription.formattedString); exit(0) }
    }
  }
  RunLoop.main.run()
}

// Self-check of the live microphone: listens 8 seconds, then prints buffers, loudest level and what it heard.
// --mic on uses echo cancelling (as talk mode does), --mic off does not.
if let mode = arg("--mic") {
  authorize { err in
    if let err { print("ERROR " + err); exit(1) }
    guard let r = recognizer() else { print("ERROR no on-device English recognition"); exit(1) }
    let engine = AVAudioEngine(), input = engine.inputNode
    if mode == "on" { do { try input.setVoiceProcessingEnabled(true) } catch { print("VP error \(error)") } }
    let fmt = input.outputFormat(forBus: 0)
    print("format \(fmt)")
    let req = SFSpeechAudioBufferRecognitionRequest(); req.requiresOnDeviceRecognition = true
    let lock = NSLock(); var n = 0; var peak: Float = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
      req.append(buf)
      var p: Float = 0
      if let ch = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { p = max(p, abs(ch[0][i])) } }
      lock.lock(); n += 1; peak = max(peak, p); lock.unlock()
    }
    var heard = ""
    r.recognitionTask(with: req) { res, e in
      if let res { heard = res.bestTranscription.formattedString }
      if let e { print("task error \(e.localizedDescription)") }
    }
    do { try engine.start() } catch { print("ERROR start \(error)"); exit(1) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      req.endAudio()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        lock.lock(); print("buffers \(n) peak \(peak)"); lock.unlock()
        print("heard: " + heard); exit(0)
      }
    }
  }
  RunLoop.main.run()
}

guard let sockPath = arg("--socket") else { print("usage: --socket <path> | --file <audio> | --mic on|off"); exit(2) }

// The chat's socket.
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(sockPath.utf8)
if pathBytes.count >= MemoryLayout.size(ofValue: addr.sun_path) { exit(2) } // the rest stays zero, so the path ends
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
if ok != 0 { exit(3) }
// Only Obsidian (A4's chat) may hear John: the other end of the socket must be an Obsidian process,
// and the socket must sit in this user's own temporary folder.
func peerIsObsidian() -> Bool {
  var pid: pid_t = 0; var len = socklen_t(MemoryLayout<pid_t>.size)
  guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return false }
  var buf = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
  return String(cString: buf).hasPrefix("/Applications/Obsidian.app/Contents/")
}
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
if !URL(fileURLWithPath: sockPath).resolvingSymlinksInPath().path.hasPrefix(tmp + "/") || !peerIsObsidian() { exit(4) }
let out = FileHandle(fileDescriptor: fd)
let outQ = DispatchQueue(label: "out")
func send(_ o: [String: String]) {
  guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
  outQ.async { try? out.write(contentsOf: d + Data([10])) }
}

final class Listener {
  let engine = AVAudioEngine()
  var r: SFSpeechRecognizer?
  // Read by the audio thread for every mic buffer; changed on the main thread.
  private let lock = NSLock()
  private var _req: SFSpeechAudioBufferRecognitionRequest?
  var req: SFSpeechAudioBufferRecognitionRequest? {
    get { lock.lock(); defer { lock.unlock() }; return _req }
    set { lock.lock(); _req = newValue; lock.unlock() }
  }
  var task: SFSpeechRecognitionTask?
  var text = ""
  var timer: Timer?
  var paused = false

  func start() {
    guard let r = recognizer() else { return send(["type": "error", "message": "This Mac has no on-device English speech recognition."]) }
    self.r = r
    let input = engine.inputNode
    // Echo cancelling, so Audrey's voice from the speakers is less likely to be heard as John.
    try? input.setVoiceProcessingEnabled(true)
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in self?.req?.append(buf) }
    do { try engine.start() } catch { return send(["type": "error", "message": "Could not start the microphone: \(error.localizedDescription)"]) }
    // Headphones or another microphone switched in stop the engine; start it again on the new one.
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      guard let self, !self.paused else { return }
      do { try self.engine.start(); self.restart() } catch { send(["type": "error", "message": "The microphone changed and could not restart: \(error.localizedDescription)"]) }
    }
    begin()
    send(["type": "ready"])
  }

  // One request per thing John says; a new one starts after each pause.
  func begin() {
    guard let r, !paused else { return }
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = true
    self.req = req; text = ""
    task = r.recognitionTask(with: req) { [weak self] res, err in
      DispatchQueue.main.async {
        guard let self, self.req === req else { return }
        if let res {
          let t = res.bestTranscription.formattedString
          if t != self.text { self.text = t; send(["type": "partial", "text": t]); self.arm() }
          if res.isFinal { self.finish() }
        } else if err != nil { // a long quiet stretch or the time limit ends the task; keep what was heard,
          if !self.text.isEmpty { self.finish() } else { self.restart(after: 0.5) } // then listen again after a beat
        }
      }
    }
  }

  func arm() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: silence, repeats: false) { [weak self] _ in self?.finish() }
  }

  func finish() {
    timer?.invalidate()
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { send(["type": "final", "text": t]) }
    restart()
  }

  func restart(after delay: TimeInterval = 0) {
    timer?.invalidate()
    req?.endAudio(); task?.cancel(); req = nil; task = nil; text = ""
    if delay == 0 { begin() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in if self?.req == nil { self?.begin() } } }
  }

  // Paused turns the microphone off, so the Mac's mic light goes out too.
  func pause() { paused = true; timer?.invalidate(); req?.endAudio(); task?.cancel(); req = nil; task = nil; text = ""; engine.pause() }
  func resume() {
    guard paused else { return }
    paused = false
    do { try engine.start() } catch { return send(["type": "error", "message": "Could not start the microphone: \(error.localizedDescription)"]) }
    begin()
  }
}

let listener = Listener()
authorize { err in
  DispatchQueue.main.async {
    if let err { send(["type": "error", "message": err]); return }
    listener.start()
  }
}

// Commands from the chat; the socket closing (Obsidian quit, End talk) ends the app.
Thread {
  var buf = Data()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { exit(0) }
    buf.append(contentsOf: chunk[0..<n])
    while let i = buf.firstIndex(of: 10) {
      let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self); buf = Data(buf[(i + 1)...])
      DispatchQueue.main.async {
        switch line {
        case "pause": listener.pause()
        case "resume": listener.resume()
        case "reset": if !listener.paused { listener.restart() }
        case "quit": exit(0)
        default: break
        }
      }
    }
  }
}.start()
RunLoop.main.run()
