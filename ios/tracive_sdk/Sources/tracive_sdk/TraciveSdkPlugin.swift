import Flutter
import UIKit

/// The iOS steps of `openReportForm`. Dart validates and encodes the package and decides what
/// happens next; this class performs one step per call and reports the outcome.
///
/// Error codes are the SDK's reason tokens and carry no message: nothing here may echo the
/// identifier, the link or the package.
public final class TraciveSdkPlugin: NSObject, FlutterPlugin, UIDocumentInteractionControllerDelegate {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tracive_sdk/report_form", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TraciveSdkPlugin(), channel: channel)
  }

  /// Kept until iOS has finished sending the file: a released controller takes its sheet, and a
  /// transfer in progress, down with it.
  private var controller: UIDocumentInteractionController?

  /// The `handOver` call waiting for the user's choice in the sheet.
  private var pending: FlutterResult?
  private var sheetWatch: VanishedSheetWatch?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "handOver":
      handOver(arguments, result: result)
    case "isInstalled":
      result(canOpen(scheme: arguments["appScheme"] as? String))
    case "openLink":
      openLink(arguments["link"] as? String, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handOver(_ arguments: [String: Any], result: @escaping FlutterResult) {
    guard pending == nil else { return result(Self.failure("busy")) }
    guard let capabilityScheme = arguments["capabilityScheme"] as? String,
      let fileExtension = arguments["fileExtension"] as? String,
      let packageData = arguments["package"] as? FlutterStandardTypedData
    else { return result(Self.failure("unexpected")) }

    // The sheet lists the app whether or not that version accepts a package, so a second scheme,
    // registered only by versions that do, is the capability probe.
    guard canOpen(scheme: capabilityScheme) else { return result(["outcome": "notAccepted"]) }

    let anchor = arguments["anchor"] as? [String: Double]
    let data = packageData.data
    pending = result
    DispatchQueue.global(qos: .userInitiated).async {
      let file: URL
      do {
        file = try Self.write(data, fileExtension: fileExtension)
      } catch {
        DispatchQueue.main.async { self.resolve(Self.failure("write_failed")) }
        return
      }
      DispatchQueue.main.async { self.present(file, anchor: anchor) }
    }
  }

  private func present(_ file: URL, anchor: [String: Double]?) {
    guard let root = Self.keyWindow()?.rootViewController, let rootView = root.view else {
      return resolve(Self.failure("no_view_controller"))
    }
    var host = root
    while let presented = host.presentedViewController { host = presented }
    guard let view = host.view else { return resolve(Self.failure("no_view_controller")) }

    let controller = UIDocumentInteractionController(url: file)
    controller.delegate = self
    self.controller = controller
    sheetWatch = VanishedSheetWatch(window: view.window) { [weak self] in
      self?.resolve(["outcome": "dismissed"])
    }
    if !controller.presentOpenInMenu(
      from: Self.rect(anchor, from: rootView, to: view), in: view, animated: true)
    {
      self.controller = nil
      resolve(Self.failure("menu_not_presented"))
    }
  }

  public func documentInteractionController(
    _ controller: UIDocumentInteractionController,
    willBeginSendingToApplication application: String?
  ) {
    // Dart compares the bundle id with the target build: any app may claim the extension.
    resolve(["outcome": "sentTo", "bundleId": application ?? ""])
  }

  public func documentInteractionControllerDidDismissOpenInMenu(
    _ controller: UIDocumentInteractionController
  ) {
    // Also fires after a pick, once `willBeginSending` has already resolved the call; alone it means
    // the user backed out or chose "Save to Files".
    resolve(["outcome": "dismissed"])
  }

  public func documentInteractionController(
    _ controller: UIDocumentInteractionController,
    didEndSendingToApplication application: String?
  ) {
    if self.controller === controller { self.controller = nil }
  }

  private func openLink(_ link: String?, result: @escaping FlutterResult) {
    guard let link, let url = URL(string: link) else { return result(Self.failure("unexpected")) }
    UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
  }

  private func canOpen(scheme: String?) -> Bool {
    guard let scheme, let url = URL(string: "\(scheme)://") else { return false }
    return UIApplication.shared.canOpenURL(url)
  }

  private func resolve(_ value: Any) {
    sheetWatch?.stop()
    sheetWatch = nil
    guard let pending else { return }
    self.pending = nil
    pending(value)
  }

  /// `report.<extension>` in a fresh folder under `tmp/tracive-sdk/report/`, after deleting what
  /// earlier calls left there. The extension, not the controller's UTI, decides which apps iOS
  /// offers.
  private static func write(_ data: Data, fileExtension: String) throws -> URL {
    guard fileExtension.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "tracive-sdk/report", isDirectory: true)
    try? fileManager.removeItem(at: root)
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("report.\(fileExtension)")
    try data.write(to: file, options: .atomic)
    return file
  }

  private static func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    }
    return UIApplication.shared.keyWindow
  }

  /// The anchor is in the Flutter view's coordinates, which are the root view's.
  private static func rect(_ anchor: [String: Double]?, from root: UIView, to view: UIView)
    -> CGRect
  {
    guard let anchor, let left = anchor["left"], let top = anchor["top"],
      let width = anchor["width"], let height = anchor["height"]
    else { return CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0) }
    return root.convert(CGRect(x: left, y: top, width: width, height: height), to: view)
  }

  private static func failure(_ reason: String) -> FlutterError {
    FlutterError(code: reason, message: nil, details: nil)
  }
}

/// Notices the "Open in" sheet has gone without a word to its delegate. iPadOS takes it down when
/// the device rotates and calls no delegate method at all, so `handOver` would never return and
/// every later call would answer "busy".
///
/// The sheet is presented after `presentOpenInMenu` returns, so each check looks for it first. Once
/// seen, it must be gone on two checks in a row, so that a delegate answer already on its way still
/// decides the outcome.
private final class VanishedSheetWatch: NSObject {
  private weak var window: UIWindow?
  private weak var topBefore: UIViewController?
  private weak var sheet: UIViewController?
  private var seen = false
  private var goneChecks = 0
  private var timer: Timer?
  private let onVanished: () -> Void

  /// Create it just before presenting, while `window`'s top view controller is the one the sheet
  /// will cover.
  init(window: UIWindow?, onVanished: @escaping () -> Void) {
    self.window = window
    self.topBefore = Self.topViewController(of: window)
    self.onVanished = onVanished
    super.init()
    timer = Timer.scheduledTimer(
      timeInterval: 0.5, target: self, selector: #selector(check), userInfo: nil, repeats: true)
  }

  /// The timer holds this object until stopped.
  func stop() {
    timer?.invalidate()
    timer = nil
  }

  @objc private func check() {
    guard seen else {
      if let top = Self.topViewController(of: window), top !== topBefore {
        sheet = top
        seen = true
      }
      return
    }
    goneChecks = sheet?.presentingViewController == nil ? goneChecks + 1 : 0
    guard goneChecks >= 2 else { return }
    stop()
    onVanished()
  }

  private static func topViewController(of window: UIWindow?) -> UIViewController? {
    var top = window?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
