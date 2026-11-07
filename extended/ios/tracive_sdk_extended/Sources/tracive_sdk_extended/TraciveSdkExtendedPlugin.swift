import Flutter
import UIKit

/// Holds the native core for Dart. Every entry point runs on the main thread, so the dictionaries
/// need no lock.
public final class TraciveSdkExtendedPlugin: NSObject, FlutterPlugin {

  private final class Instance {
    let reports: TraciveReports
    var evidence: [Int: PreparedEvidence] = [:]
    var calls: [Int: Task<Void, Never>] = [:]
    var submissions: [String: Int] = [:]

    init(reports: TraciveReports) {
      self.reports = reports
    }
  }

  private let channel: FlutterMethodChannel
  private var instances: [Int: Instance] = [:]
  private var nextHandle = 1
  private var screenIsOpen = false
  private var tokenWaiters: [Int: CheckedContinuation<String, Error>] = [:]

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tracive_sdk_extended/reports", binaryMessenger: registrar.messenger())
    let plugin = TraciveSdkExtendedPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    instances.values.forEach { $0.calls.values.forEach { $0.cancel() } }
    instances.removeAll()
    // Nothing will ever answer these.
    let waiters = tokenWaiters.values
    tokenWaiters.removeAll()
    waiters.forEach {
      $0.resume(throwing: TraciveReportError(code: .server, message: "The Flutter engine has stopped."))
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    if call.method == "create" { return create(arguments, result: result) }
    guard let handle = arguments["reports"] as? Int, let instance = instances[handle] else {
      return result(
        FlutterError(code: "CANCELLED", message: "This TraciveReports was disposed.", details: nil))
    }
    switch call.method {
    case "dispose":
      instances[handle] = nil
      instance.calls.values.forEach { $0.cancel() }
      result(nil)
    case "requirements":
      run(instance, result) { try await instance.reports.requirements().wire }
    case "prepare":
      prepare(arguments, instance, result)
    case "releaseEvidence":
      if let evidence = arguments["evidence"] as? Int { instance.evidence[evidence] = nil }
      result(nil)
    case "submit":
      submit(arguments, instance, result)
    case "cancelSubmit":
      if let key = arguments["key"] as? String, let id = instance.submissions[key] {
        instance.calls[id]?.cancel()
      }
      result(nil)
    case "status":
      let reportId = arguments["reportId"] as? String ?? ""
      run(instance, result) { try await instance.reports.status(reportId).rawValue }
    case "openInTracive":
      instance.reports.openInTracive(arguments["reportId"] as? String ?? "") { result($0) }
    case "presentForm":
      presentForm(arguments, instance, result)
    case "presentStatus":
      presentStatus(arguments, instance, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(_ arguments: [String: Any], result: FlutterResult) {
    guard let baseUrl = (arguments["baseUrl"] as? String).flatMap(URL.init(string:)),
      let scheme = arguments["appUrlScheme"] as? String
    else { return result(Self.flutterError(Self.badArguments)) }
    let handle = nextHandle
    nextHandle += 1
    let reports = TraciveReports(
      environment: TraciveEnvironment(baseUrl: baseUrl),
      target: ReportFormTarget(scheme: scheme),
      accessToken: { [weak self] stale in
        try await self?.dartToken(handle: handle, stale: stale) ?? { throw Self.noAnswer }()
      })
    instances[handle] = Instance(reports: reports)
    result(handle)
  }

  /// Native never refreshes: a rotating refresh token has one owner, the base SDK in Dart.
  private func dartToken(handle: Int, stale: String?) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.main.async { self.askDart(handle, stale, continuation) }
    }
  }

  private func askDart(
    _ handle: Int, _ stale: String?, _ continuation: CheckedContinuation<String, Error>
  ) {
    let waiter = nextHandle
    nextHandle += 1
    tokenWaiters[waiter] = continuation
    let arguments: [String: Any] = ["reports": handle, "stale": stale ?? NSNull()]
    channel.invokeMethod("accessToken", arguments: arguments) { [weak self] reply in
      guard let continuation = self?.tokenWaiters.removeValue(forKey: waiter) else { return }
      switch reply {
      case let token as String: continuation.resume(returning: token)
      case let failure as FlutterError: continuation.resume(throwing: Self.reportError(failure))
      default: continuation.resume(throwing: Self.noAnswer)
      }
    }
  }

  private func prepare(
    _ arguments: [String: Any], _ instance: Instance, _ result: @escaping FlutterResult
  ) {
    guard let bytes = arguments["bytes"] as? FlutterStandardTypedData,
      let mimeType = arguments["mimeType"] as? String
    else { return result(Self.flutterError(Self.badArguments)) }
    run(instance, result) { [self] in
      let prepared = try await instance.reports.prepare(bytes.data, mimeType: mimeType)
      let handle = nextHandle
      nextHandle += 1
      instance.evidence[handle] = prepared
      return [
        "evidence": handle, "mimeType": prepared.mimeType, "byteCount": prepared.byteCount,
      ] as [String: Any]
    }
  }

  private func submit(
    _ arguments: [String: Any], _ instance: Instance, _ result: @escaping FlutterResult
  ) {
    guard let key = arguments["key"] as? String else {
      return result(Self.flutterError(Self.badArguments))
    }
    let draft: ReportDraft
    do {
      draft = try ReportDraft(arguments, key: key, evidence: instance.evidence)
    } catch {
      return result(Self.flutterError(error))
    }
    let channel = self.channel
    let id = run(instance, result) {
      defer { instance.submissions[key] = nil }
      let outcome = try await instance.reports.submit(draft) { fraction in
        DispatchQueue.main.async {
          channel.invokeMethod("progress", arguments: ["key": key, "fraction": fraction])
        }
      }
      switch outcome {
      case .submitted(let reportId, let status):
        return ["outcome": "submitted", "reportId": reportId, "status": status.rawValue]
      case .needsConsent:
        return ["outcome": "needsConsent"]
      case .failed(let error):
        throw error
      }
    }
    instance.submissions[key] = id
  }

  private func presentForm(
    _ arguments: [String: Any], _ instance: Instance, _ result: @escaping FlutterResult
  ) {
    guard let presenter = startScreen(result) else { return }
    let files = arguments["attachments"] as? [[String: Any]] ?? []
    let prefill = ReportPrefill(
      identifiers: arguments["identifiers"] as? [String] ?? [],
      incidentDate: (arguments["incidentDate"] as? String)
        .flatMap(ReportIncidentDate.init(iso8601:)),
      title: arguments["title"] as? String,
      attachments: files.compactMap { file in
        guard let bytes = file["bytes"] as? FlutterStandardTypedData,
          let mimeType = file["mimeType"] as? String
        else { return nil }
        return ReportAttachment(bytes: bytes.data, mimeType: mimeType)
      })
    MainActor.assumeIsolated {
      TraciveReportForm.present(
        reports: instance.reports, prefill: prefill, theme: Self.theme(arguments), from: presenter
      ) { [weak self] outcome in
        self?.screenIsOpen = false
        result(outcome.wire)
      }
    }
  }

  private func presentStatus(
    _ arguments: [String: Any], _ instance: Instance, _ result: @escaping FlutterResult
  ) {
    guard let presenter = startScreen(result) else { return }
    MainActor.assumeIsolated {
      TraciveReportStatus.present(
        reports: instance.reports, reportId: arguments["reportId"] as? String ?? "",
        theme: Self.theme(arguments), from: presenter
      ) { [weak self] outcome in
        self?.screenIsOpen = false
        result(outcome == .needsConsent ? "needsConsent" : "closed")
      }
    }
  }

  private func startScreen(_ result: FlutterResult) -> UIViewController? {
    guard !screenIsOpen else {
      result(FlutterError(code: "SERVER", message: "A Tracive screen is already open.", details: nil))
      return nil
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "SERVER", message: "There is no view to open it from.", details: nil))
      return nil
    }
    screenIsOpen = true
    return presenter
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private static func theme(_ arguments: [String: Any]) -> TraciveReportTheme {
    let radius = (arguments["cornerRadius"] as? Int).map { CGFloat($0) }
    guard let argb = arguments["primaryColor"] as? Int else {
      return TraciveReportTheme(primaryColor: nil, cornerRadius: radius)
    }
    let color = UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: 1)
    return TraciveReportTheme(primaryColor: color, cornerRadius: radius)
  }

  @discardableResult
  private func run(
    _ instance: Instance, _ result: @escaping FlutterResult,
    _ body: @escaping @MainActor () async throws -> Any?
  ) -> Int {
    let id = nextHandle
    nextHandle += 1
    instance.calls[id] = Task { @MainActor in
      defer { instance.calls[id] = nil }
      do {
        result(try await body())
      } catch {
        result(Self.flutterError(error))
      }
    }
    return id
  }

  private static let badArguments = TraciveReportError(code: .server, message: "Bad arguments.")
  private static let noAnswer = TraciveReportError(code: .server, message: "The token call failed.")

  private static func flutterError(_ error: Error) -> FlutterError {
    if error is CancellationError {
      return FlutterError(code: "CANCELLED", message: "The call was cancelled.", details: nil)
    }
    guard let report = error as? TraciveReportError else {
      return FlutterError(code: "SERVER", message: "The call failed.", details: nil)
    }
    return FlutterError(
      code: report.code.rawValue,
      message: report.message,
      details: [
        "httpStatus": report.httpStatus ?? NSNull(),
        "retryAfterSeconds": report.retryAfterSeconds ?? NSNull(),
      ] as [String: Any])
  }

  private static func reportError(_ failure: FlutterError) -> TraciveReportError {
    let details = failure.details as? [String: Any]
    return TraciveReportError(
      code: TraciveReportError.Code(rawValue: failure.code) ?? .server,
      message: failure.message ?? failure.code,
      httpStatus: details?["httpStatus"] as? Int,
      retryAfterSeconds: details?["retryAfterSeconds"] as? Int)
  }
}

extension ReportDraft {
  /// Dart's key rather than a new one: a retry must send what the first attempt sent. This pod is
  /// one module with the overlay, which is what lets an extension set a `let`.
  fileprivate init(_ arguments: [String: Any], key: String, evidence held: [Int: PreparedEvidence])
    throws
  {
    let handles = arguments["evidence"] as? [Int] ?? []
    let date = arguments["incidentDate"] as? String ?? ""
    guard let incidentDate = ReportIncidentDate(iso8601: date) else {
      throw TraciveReportError(code: .invalidReport, message: "incidentDate is not YYYY-MM-DD.")
    }
    guard handles.allSatisfy({ held[$0] != nil }) else {
      throw TraciveReportError(code: .attachmentInvalid, message: "The evidence was released.")
    }
    identifiers = arguments["identifiers"] as? [String] ?? []
    title = arguments["title"] as? String ?? ""
    chronology = arguments["chronology"] as? String ?? ""
    comment = arguments["comment"] as? String
    self.incidentDate = incidentDate
    self.evidence = handles.compactMap { held[$0] }
    acceptedTerms = (arguments["terms"] as? [[String: String]] ?? []).compactMap { term in
      guard let id = term["id"], let version = term["version"], let url = term["url"] else {
        return nil
      }
      return RequiredTerm(id: id, version: version, url: url)
    }
    language = arguments["language"] as? String
    idempotencyKey = key
  }
}

extension ReportRequirements {
  fileprivate var wire: [String: Any] {
    [
      "enabled": enabled,
      "remainingToday": remainingToday,
      "limits": [
        "titleMaxLength": limits.titleMaxLength,
        "chronologyMinLength": limits.chronologyMinLength,
        "chronologyMaxLength": limits.chronologyMaxLength,
        "commentMaxLength": limits.commentMaxLength,
        "maxIdentifiers": limits.maxIdentifiers,
        "attachmentsPerIdentifier": limits.attachmentsPerIdentifier,
        "extraAttachmentsWithPhone": limits.extraAttachmentsWithPhone,
        "maxAttachmentBytes": limits.maxAttachmentBytes,
        "attachmentTypes": limits.attachmentTypes,
      ] as [String: Any],
      "terms": terms.map { ["id": $0.id, "version": $0.version, "url": $0.url] },
    ]
  }
}

extension ReportFormOutcome {
  fileprivate var wire: [String: Any] {
    switch self {
    case .submitted(let reportId, let status):
      return ["outcome": "submitted", "reportId": reportId, "status": status.rawValue]
    case .needsConsent:
      return ["outcome": "needsConsent"]
    case .cancelled:
      return ["outcome": "cancelled"]
    }
  }
}
