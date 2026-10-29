// Audrey Talk: the listening half of talk mode in A4's chat with Audrey (John 2026-10-28).
// A background app (no window, no Dock icon) so macOS asks for Microphone and Speech Recognition
// in its own name; Obsidian's own Info.plist has no speech key, so it cannot ask itself.
//
//   Audrey Talk.app --socket <path>   connects to the chat's socket and streams JSON lines:
//       {"type":"ready"} {"type":"partial","text":…} {"type":"final","text":…} {"type":"error","message":…}
//     and takes lines "pause", "resume", "reset" (drop what it has heard so far), "quit". Exits when the
//     socket closes. Only an Obsidian process may be on the other end.
//   Audrey Talk.app --file <audio>    self-check: prints what it hears in the file, then exits.
//   Audrey Talk.app --mic             self-check of the live microphone (8 seconds).
import AVFoundation
import Foundation
import Speech

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let silence: TimeInterval = 5 // a pause this long ends what John said; time to think (John 2026-10-29)

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

// Reads the default microphone through a capture session and hands each sound buffer on.
final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  let session = AVCaptureSession()
  let q = DispatchQueue(label: "mic")
  let onBuffer: (CMSampleBuffer) -> Void
  private(set) var count = 0
  init(_ onBuffer: @escaping (CMSampleBuffer) -> Void) { self.onBuffer = onBuffer }
  func start() throws {
    if !session.inputs.isEmpty { return q.async { self.session.startRunning() } }
    guard let dev = AVCaptureDevice.default(for: .audio) else { throw NSError(domain: "AudreyTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found."]) }
    let input = try AVCaptureDeviceInput(device: dev)
    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: q)
    session.beginConfiguration()
    if session.canAddInput(input) { session.addInput(input) }
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    q.async { self.session.startRunning() } // blocks while the mic opens, so not on the main thread
  }
  func stop() { q.async { self.session.stopRunning() } }
  func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) { count += 1; onBuffer(sb) }
}

// Self-check of the live microphone: listens 8 seconds, then prints how many sound buffers came in and what it heard.
if args.contains("--mic") {
  authorize { err in DispatchQueue.main.async {
    if let err { print("ERROR " + err); exit(1) }
    guard let r = recognizer() else { print("ERROR no on-device English recognition"); exit(1) }
    let req = SFSpeechAudioBufferRecognitionRequest(); req.requiresOnDeviceRecognition = true
    let cap = Capture { req.appendAudioSampleBuffer($0) }
    var heard = ""
    r.recognitionTask(with: req) { res, _ in DispatchQueue.main.async { if let res { heard = res.bestTranscription.formattedString } } }
    do { try cap.start() } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      req.endAudio()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("buffers \(cap.q.sync { cap.count })"); print("heard: " + heard); exit(heard.isEmpty ? 1 : 0) }
    }
  } }
  RunLoop.main.run()
}

guard let sockPath = arg("--socket") else { print("usage: --socket <path> | --file <audio> | --mic"); exit(2) }

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
  // The mic is read through a capture session: an AVAudioEngine tap got no sound at all in this
  // background app on John's Mac (2026-10-29), while the capture session does.
  // shortcut: stays on the mic that was the default at start, switch to watching device changes if John uses headphones.
  lazy var mic = Capture { [weak self] sb in self?.req?.appendAudioSampleBuffer(sb) }
  var r: SFSpeechRecognizer?
  // Read by the mic queue for every buffer; changed on the main thread.
  private let lock = NSLock()
  private var _req: SFSpeechAudioBufferRecognitionRequest?
  var req: SFSpeechAudioBufferRecognitionRequest? {
    get { lock.lock(); defer { lock.unlock() }; return _req }
    set { lock.lock(); _req = newValue; lock.unlock() }
  }
  var task: SFSpeechRecognitionTask?
  var text = ""
  var said = "" // what he said before the recognizer ended a request mid-thought
  var timer: Timer?
  var paused = false

  func start() {
    guard let r = recognizer() else { return send(["type": "error", "message": "This Mac has no on-device English speech recognition."]) }
    self.r = r
    do { try mic.start() } catch { return send(["type": "error", "message": "Could not start the microphone: \(error.localizedDescription)"]) }
    // The session fails quietly otherwise (another app took the mic, or it went away).
    NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: mic.session, queue: .main) { n in
      let e = n.userInfo?[AVCaptureSessionErrorKey] as? Error
      send(["type": "error", "message": "The microphone stopped (\(e?.localizedDescription ?? "unknown reason")). End talk and start it again."])
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
    self.req = req
    task = r.recognitionTask(with: req) { [weak self] res, err in
      DispatchQueue.main.async {
        guard let self, self.req === req else { return }
        if let res {
          let t = [self.said, res.bestTranscription.formattedString].filter { !$0.isEmpty }.joined(separator: " ")
          if t != self.text { self.text = t; send(["type": "partial", "text": t]); self.arm() }
          if res.isFinal { self.carryOn() }
        } else if err != nil { // a quiet stretch or the time limit ends the request: keep what was heard and listen on,
          if !self.text.isEmpty { self.carryOn(after: 0.5) } else { self.restart(after: 0.5) } // the pause timer still sends it
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

  // The recognizer ended the request but he may not be done: a new request continues the same message.
  func carryOn(after delay: TimeInterval = 0) {
    req?.endAudio(); task?.cancel(); req = nil; task = nil; said = text
    if delay == 0 { begin() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in if self?.req == nil { self?.begin() } } }
  }

  func restart(after delay: TimeInterval = 0) {
    timer?.invalidate()
    req?.endAudio(); task?.cancel(); req = nil; task = nil; text = ""; said = ""
    if delay == 0 { begin() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in if self?.req == nil { self?.begin() } } }
  }

  // Paused turns the microphone off, so the Mac's mic light goes out too.
  func pause() { paused = true; timer?.invalidate(); req?.endAudio(); task?.cancel(); req = nil; task = nil; text = ""; said = ""; mic.stop() }
  func resume() {
    guard paused else { return }
    paused = false
    do { try mic.start() } catch { return send(["type": "error", "message": "Could not start the microphone: \(error.localizedDescription)"]) }
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
