import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PdfReaderIncomingFiles") {
      IncomingFilesPlugin.register(with: registrar)
    }
  }
}

/// Receives PDFs (and Word / Markdown / text files for the reader) from "Open in…" / share ("Copy to PdfReader") and Files.
///
/// Info.plist sets LSSupportsOpeningDocumentsInPlace = NO, so iOS hands us a
/// copy (in Documents/Inbox) or a security-scoped URL. Either way we copy the
/// bytes into the app-private inbox (Application Support/inbox, excluded from
/// backup) with a size cap and a generated file name, delete the system copy,
/// and pass the private path to Dart. Same protocol as the Android
/// IncomingFilesHandler: method channel "pdfreader/incoming" (`configure`) and
/// event channel "pdfreader/incoming/events".
final class IncomingFilesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  FlutterSceneLifeCycleDelegate
{
  private static let maxFilesPerBatch = 20
  private let queue = DispatchQueue(label: "pdfreader.incoming")

  // Main-thread state.
  private var inbox: URL?
  private var maxBytes: Int64 = 0
  private var pendingURLs: [URL] = []
  private var undelivered: [[[String: Any]]] = []
  private var sink: FlutterEventSink?
  private var recentlySeen: [URL] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = IncomingFilesPlugin()
    let method = FlutterMethodChannel(
      name: "pdfreader/incoming", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: method)
    let events = FlutterEventChannel(
      name: "pdfreader/incoming/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  // MARK: - Method channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "configure" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let inboxPath = args["inbox"] as? String,
      let max = (args["maxBytes"] as? NSNumber)?.int64Value, max > 0
    else {
      result(FlutterError(code: "bad_args", message: "inbox and maxBytes are required", details: nil))
      return
    }
    let inboxURL = URL(fileURLWithPath: inboxPath, isDirectory: true).standardizedFileURL
    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    guard inboxURL.path.hasPrefix(home.path + "/") else {
      result(FlutterError(code: "bad_inbox", message: "inbox must be inside the app container", details: nil))
      return
    }
    try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableInbox = inboxURL
    try? mutableInbox.setResourceValues(values)

    inbox = inboxURL
    maxBytes = max
    let queued = pendingURLs
    pendingURLs.removeAll()
    queue.async {
      let results = Array(queued.prefix(Self.maxFilesPerBatch)).map {
        Self.importURL($0, inbox: inboxURL, maxBytes: max)
      }
      DispatchQueue.main.async { result(results) }
    }
  }

  // MARK: - Event channel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    let queued = undelivered
    undelivered.removeAll()
    queued.forEach { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  // MARK: - Entry points

  func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return offer([url])
  }

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts, !contexts.isEmpty else { return false }
    return offer(contexts.map { $0.url })
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return offer(URLContexts.map { $0.url })
  }

  /// Main thread. Returns true if at least one URL is a file we will import.
  private func offer(_ urls: [URL]) -> Bool {
    // The same URL can arrive through both the app and the scene callback.
    let files = urls.filter { $0.isFileURL && !recentlySeen.contains($0) }
    guard !files.isEmpty else { return false }
    recentlySeen = Array((recentlySeen + files).suffix(40))
    guard let inboxURL = inbox else {
      pendingURLs.append(contentsOf: files)
      return true
    }
    let max = maxBytes
    queue.async {
      let results = Array(files.prefix(Self.maxFilesPerBatch)).map {
        Self.importURL($0, inbox: inboxURL, maxBytes: max)
      }
      DispatchQueue.main.async { self.deliver(results) }
    }
    return true
  }

  private func deliver(_ results: [[String: Any]]) {
    guard !results.isEmpty else { return }
    if let sink = sink { sink(results) } else { undelivered.append(results) }
  }

  // MARK: - Copy (background queue)

  private static func importURL(_ url: URL, inbox: URL, maxBytes: Int64) -> [String: Any] {
    let source = url.absoluteString
    let name = sanitize(url.lastPathComponent)
    func failure(_ code: String) -> [String: Any] {
      return ["error": code, "displayName": name, "sourceUri": source]
    }
    guard url.isFileURL else { return failure("unsupported") }

    let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
    let systemInbox = isSystemInboxCopy(resolved, home: home)
    // Never re-import our own private files (only the system's Inbox copy).
    if resolved.hasPrefix(home + "/") && !systemInbox { return failure("rejected") }

    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
      if systemInbox { try? FileManager.default.removeItem(at: url) }
    }

    var outcome: [String: Any] = failure("unreadable")
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordinationError
    ) { readURL in
      outcome = copy(readURL, to: inbox, maxBytes: maxBytes, name: name, source: source)
    }
    return outcome
  }

  private static func isSystemInboxCopy(_ path: String, home: String) -> Bool {
    let documentsInbox = home + "/Documents/Inbox/"
    let tmpDir = home + "/tmp/"
    if path.hasPrefix(documentsInbox) { return true }
    // Newer iOS versions place "Open in" copies in tmp/<bundle id>-Inbox/.
    if path.hasPrefix(tmpDir) {
      let rest = path.dropFirst(tmpDir.count)
      if let first = rest.split(separator: "/").first, first.hasSuffix("-Inbox") { return true }
    }
    return false
  }

  private static func copy(
    _ url: URL, to inbox: URL, maxBytes: Int64, name: String, source: String
  ) -> [String: Any] {
    func failure(_ code: String) -> [String: Any] {
      return ["error": code, "displayName": name, "sourceUri": source]
    }
    let fm = FileManager.default
    // PDFs keep the full cap; other documents (sniffed in Dart) are capped at
    // the largest reader limit (SecurityLimits.maxDocxFileBytes).
    let rawExt = (name as NSString).pathExtension.lowercased()
    let ext = rawExt.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil ? rawExt : "pdf"
    let cap = ext == "pdf" ? maxBytes : min(maxBytes, nonPdfMaxBytes)
    if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
      size.int64Value > cap
    {
      return failure("tooLarge")
    }
    guard let input = InputStream(url: url) else { return failure("unreadable") }
    let stamp = UUID().uuidString
    let part = inbox.appendingPathComponent("in_\(stamp).part")
    let target = inbox.appendingPathComponent("in_\(stamp).\(ext)")
    guard fm.createFile(atPath: part.path, contents: nil),
      let output = try? FileHandle(forWritingTo: part)
    else { return failure("noSpace") }

    input.open()
    var total: Int64 = 0
    var code: String?
    let bufferSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while code == nil {
      let n = input.read(&buffer, maxLength: bufferSize)
      if n < 0 { code = "unreadable"; break }
      if n == 0 { break }
      total += Int64(n)
      if total > cap { code = "tooLarge"; break }
      do {
        try output.write(contentsOf: Data(buffer[0..<n]))
      } catch {
        code = "noSpace"
      }
    }
    input.close()
    try? output.synchronize()
    try? output.close()
    if code == nil && total == 0 { code = "unreadable" }
    if code == nil {
      do { try fm.moveItem(at: part, to: target) } catch { code = "unreadable" }
    }
    if let code = code {
      try? fm.removeItem(at: part)
      return failure(code)
    }
    return ["path": target.path, "displayName": name, "sourceUri": source, "size": total]
  }

  /// Mirrors FileNames.sanitize (Kotlin) and sanitizeDisplayName (Dart).
  private static let nonPdfMaxBytes: Int64 = 100 * 1024 * 1024

  static func sanitize(_ raw: String) -> String {
    var n = raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    n = n.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    let banned: Set<Character> = [":", "*", "?", "\"", "<", ">", "|"]
    n = String(
      n.unicodeScalars.filter { s in
        let v = s.value
        if v < 0x20 || v == 0x7F { return false }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return false }
        if v == 0x200E || v == 0x200F { return false }
        return !banned.contains(Character(s))
      }.map(Character.init))
    n = n.trimmingCharacters(in: .whitespaces)
    while n.hasPrefix(".") { n.removeFirst() }
    n = n.trimmingCharacters(in: .whitespaces)
    if n.isEmpty { return "document.pdf" }
    if n.count > 120 {
      let ext = (n as NSString).pathExtension
      let suffix = (!ext.isEmpty && ext.count < 10) ? "." + ext : ""
      n = String(n.prefix(120 - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
    }
    return n
  }
}
