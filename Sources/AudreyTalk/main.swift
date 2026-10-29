// Audrey Talk: the listening half of talk mode in A4's chat with Audrey (John 2026-10-28).
// A background app (no window, no Dock icon) so macOS asks for the Microphone in its own name.
// Speech to text is FluidAudio's Parakeet (English v2) on the Neural Engine (John 2026-10-29): the Mac's own
// recognizer dropped first and last words and ran a sentence behind. The model sits in
// ~/Library/Application Support/FluidAudio/Models (FluidVoice shares it); it is downloaded once if missing.
//
//   Audrey Talk.app --socket <path>   connects to the chat's socket and streams JSON lines:
//       {"type":"ready"} {"type":"partial","text":…} {"type":"final","text":…} {"type":"error","message":…}
//     and takes lines "hold" (John is holding space: start a message), "release" (send it as one final),
//     "reset" (drop it unsent), "quit". Exits when the socket closes. Only an Obsidian process may be on the other end.
//     --debug adds {"type":"note"} lines (the hidden test reads them).
//   Audrey Talk.app --file <audio>    self-check: prints what it hears in the file, then exits.
//   Audrey Talk.app --mic             self-check of the live microphone (8 seconds).
import AVFoundation
import FluidAudio
import Foundation

let args = CommandLine.arguments
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let rate = 16_000.0 // what Parakeet takes: 16 kHz mono floats

func authorize(_ done: @escaping (String?) -> Void) {
  if args.contains("--file") { return done(nil) }
  AVCaptureDevice.requestAccess(for: .audio) { ok in done(ok ? nil : "The microphone is not allowed for Audrey Talk (System Settings, Privacy).") }
}

// One recognizer, loaded once; transcribe calls are serialized by the actor.
let asr = AsrManager(config: .default)
func loadModel() async throws { try await asr.loadModels(try await AsrModels.downloadAndLoad(version: .v2)) }
func transcribe(_ samples: [Float]) async throws -> String {
  // Parakeet needs at least a second of audio; pad short bits with silence.
  let padded = samples.count < Int(rate) ? samples + [Float](repeating: 0, count: Int(rate) - samples.count) : samples
  var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
  return try await asr.transcribe(padded, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
}

if let file = arg("--file") {
  Task {
    do {
      try await loadModel()
      print(try await transcribe(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: file)))); exit(0)
    } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
  }
  RunLoop.main.run()
}

// Reads the default microphone through a capture session, already as 16 kHz mono floats, and hands them on.
final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  let session = AVCaptureSession()
  let q = DispatchQueue(label: "mic")
  let onSamples: ([Float]) -> Void
  private(set) var count = 0
  init(_ onSamples: @escaping ([Float]) -> Void) { self.onSamples = onSamples }
  func start() throws {
    if !session.inputs.isEmpty { return q.async { self.session.startRunning() } }
    guard let dev = AVCaptureDevice.default(for: .audio) else { throw NSError(domain: "AudreyTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found."]) }
    let input = try AVCaptureDeviceInput(device: dev)
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
    output.setSampleBufferDelegate(self, queue: q)
    session.beginConfiguration()
    if session.canAddInput(input) { session.addInput(input) }
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    q.async { self.session.startRunning() } // blocks while the mic opens, so not on the main thread
  }
  func stop() { q.async { self.session.stopRunning() } }
  func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
    guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
    // Copied, not pointed at: the buffer can come in more than one piece.
    var out = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
    guard !out.isEmpty, out.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }) == noErr else { return }
    count += 1
    onSamples(out)
  }
}

// Self-check of the live microphone: listens 8 seconds, then prints how many sound buffers came in and what it heard.
if args.contains("--mic") {
  authorize { err in
    if let err { print("ERROR " + err); exit(1) }
    let lock = NSLock(); var all: [Float] = []
    let cap = Capture { s in lock.lock(); all += s; lock.unlock() }
    Task {
      do {
        try await loadModel(); try cap.start()
        try await Task.sleep(nanoseconds: 8_000_000_000); cap.stop()
        lock.lock(); let s = all; lock.unlock()
        let heard = try await transcribe(s)
        print("buffers \(cap.q.sync { cap.count }), seconds \(String(format: "%.1f", Double(s.count) / rate))"); print("heard: " + heard)
        exit(heard.isEmpty ? 1 : 0)
      } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
    }
  }
  RunLoop.main.run()
}

// --listen <seconds>: self-check of the whole listener, printing what it would send, with timings, then exits.
let listenFor = arg("--listen").flatMap(Double.init)
let started = Date()
func connectToChat() -> Int32 {
  guard let sockPath = arg("--socket") else { print("usage: --socket <path> | --file <audio> | --mic | --listen <seconds>"); exit(2) }
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
  return fd
}
let fd: Int32 = listenFor == nil ? connectToChat() : 1
let out = FileHandle(fileDescriptor: fd)
let outQ = DispatchQueue(label: "out")
func send(_ o: [String: String]) {
  var o = o
  if listenFor != nil { o["at"] = String(format: "%.1f", Date().timeIntervalSince(started)) }
  guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
  outQ.async { try? out.write(contentsOf: d + Data([10])) }
}
// Only in the --listen self-check and with --debug: timings and why a request ended.
func note(_ s: String) { if listenFor != nil || args.contains("--debug") { send(["type": "note", "text": s]) } }

// Hears John only while he holds space in the chat (John 2026-10-29: always-on listening sent fan noise as "Uh").
// A message starts with the last half second before "hold", so his first word is not cut; while he holds,
// everything he has said is written out again every moment; "release" sends all of it as the message.
final class Listener {
  // The mic is read through a capture session: an AVAudioEngine tap got no sound at all in this
  // background app on John's Mac (2026-10-29), while the capture session does.
  // shortcut: stays on the mic that was the default at start, switch to watching device changes if John uses headphones.
  lazy var mic = Capture { [weak self] s in self?.add(s) }
  // Read by the mic queue for every buffer; changed by the chat-reading thread and the main thread.
  private let lock = NSLock()
  private var samples: [Float] = []
  private var generation = 0 // bumped by hold/release/reset, so a pass that started before it is thrown away
  private var holding = false
  var text = ""
  var busy = false
  var loaded = false
  var timer: Timer?
  let preroll = Int(rate * 0.5)

  func add(_ s: [Float]) {
    lock.lock(); samples += s
    if !holding && samples.count > 2 * preroll { samples.removeFirst(samples.count - preroll) } // trimmed now and then, not per buffer
    lock.unlock()
  }
  func take(_ f: (inout [Float], inout Int, inout Bool) -> Void) { lock.lock(); f(&samples, &generation, &holding); lock.unlock() }

  func start() {
    do { try mic.start() } catch { return send(["type": "error", "message": "Could not start the microphone: \(error.localizedDescription)"]) }
    // The session fails quietly otherwise (another app took the mic, or it went away).
    NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: mic.session, queue: .main) { n in
      let e = n.userInfo?[AVCaptureSessionErrorKey] as? Error
      send(["type": "error", "message": "The microphone stopped (\(e?.localizedDescription ?? "unknown reason")). End talk and start it again."])
    }
    Task {
      do { try await loadModel() } catch { return send(["type": "error", "message": "Could not load the speech model: \(error.localizedDescription)"]) }
      DispatchQueue.main.async {
        self.loaded = true
        self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        send(["type": "ready"])
        if listenFor != nil { self.hold() } // the self-check holds the whole time
      }
    }
  }

  func tick() {
    guard loaded, !busy else { return }
    var snap: [Float] = []; var gen = 0; var on = false
    take { s, g, h in snap = s; gen = g; on = h }
    guard on, !snap.isEmpty else { return }
    busy = true
    Task {
      let heard = try? await transcribe(snap)
      DispatchQueue.main.async {
        self.busy = false
        var current = false
        self.take { _, g, _ in current = g == gen }
        guard current, let t = heard, !t.isEmpty, t != self.text else { return } // a failed pass changes nothing
        self.text = t; send(["type": "partial", "text": t])
      }
    }
  }

  // hold, release and reset change the sound on the thread that reads the chat, the moment the line comes in,
  // so a busy main thread cannot cut his first word (a first word went missing once, 2026-10-29, cause unproven).
  // The rest runs on main.
  func hold() {
    let got = Date(); var had = 0
    take { s, g, h in had = s.count; if s.count > preroll { s.removeFirst(s.count - preroll) }; g += 1; h = true }
    DispatchQueue.main.async { self.text = ""; note("hold: \(String(format: "%.1f", Double(had) / rate)) s before it, main thread \(Int(Date().timeIntervalSince(got) * 1000)) ms behind") }
  }

  // Always answers with one final, empty when nothing was held or heard, so the chat never waits on it;
  // "missed" when the speech model failed, so the chat can tell him to say it again.
  // shortcut: no cap on one hold (the old one was 2 minutes); add one if a hold that long ever fails.
  func release(_ then: @escaping () -> Void = {}) {
    var snap: [Float] = []
    take { s, g, h in if h { snap = s; s.removeAll() }; g += 1; h = false }
    DispatchQueue.main.async { self.text = ""; self.finish(snap, then) }
  }

  // One pass on the model at a time: waits for a moment-by-moment pass still running; new ones wait for this.
  private func finish(_ snap: [Float], _ then: @escaping () -> Void) {
    if busy { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.finish(snap, then) } }
    busy = true
    Task {
      var t: String? = ""
      if !snap.isEmpty { t = try? await transcribe(snap) }
      DispatchQueue.main.async {
        self.busy = false
        send(t.map { ["type": "final", "text": $0] } ?? ["type": "final", "text": "", "missed": "true"]); note("sent after \(String(format: "%.1f", Double(snap.count) / rate)) s of sound")
        then()
      }
    }
  }

  func reset() { take { s, g, h in s.removeAll(); g += 1; h = false }; DispatchQueue.main.async { self.text = "" } }
}

let listener = Listener()
authorize { err in
  DispatchQueue.main.async {
    if let err { send(["type": "error", "message": err]); return }
    listener.start()
  }
}

// Commands from the chat; the socket closing (Obsidian quit, End talk) ends the app.
if let listenFor { DispatchQueue.main.asyncAfter(deadline: .now() + listenFor) { listener.release { outQ.sync {}; exit(0) } } } else { Thread {
  var buf = Data()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { exit(0) }
    buf.append(contentsOf: chunk[0..<n])
    while let i = buf.firstIndex(of: 10) {
      let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self); buf = Data(buf[(i + 1)...])
      switch line {
      case "hold": listener.hold()
      case "release": listener.release()
      case "reset": listener.reset()
      case "quit": exit(0)
      default: break
      }
    }
  }
}.start() }
RunLoop.main.run()
