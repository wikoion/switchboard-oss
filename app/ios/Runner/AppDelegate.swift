import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// "switchboard/push": push registration, the shared session and
  /// settings for the notification extension, and opening chats from
  /// notifications.
  private var pushChannel: FlutterMethodChannel?
  private var tokenWaiters: [FlutterResult] = []
  /// A chat tapped before Dart was listening.
  private var pendingRoom: String?
  private var dartReady = false
  /// Signal calls: RingRTC and CallKit.
  private let calls = CallsBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let callsRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "SwitchboardCalls") {
      calls.attach(to: callsRegistrar.messenger(), textures: callsRegistrar.textures())
      callsRegistrar.register(CallVideoFactory(bridge: calls), withId: "switchboard/call-video")
    }
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SwitchboardPush") else { return }
    let channel = FlutterMethodChannel(name: "switchboard/push", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "register":
        self.register(result)
      case "shareSession":
        SharedSession.store(call.arguments as? String)
        result(nil)
      case "pushKey":
        // The key the server seals each push's message with, as base64.
        result(PushKey.loadOrCreate()?.base64EncodedString())
      case "setHideSender":
        // The setting to hide who sent a message, for the notification
        // extension, which draws the notifications.
        if NotificationPrivacy.store((call.arguments as? Bool) ?? true) {
          result(nil)
        } else {
          result(FlutterError(code: "keychain", message: "The keychain didn't save the setting", details: nil))
        }
      case "setBadge":
        // The app icon counts unread chats; pushes only update it when a
        // message arrives, so reading in the app has to update it too.
        let count = (call.arguments as? Int) ?? 0
        if #available(iOS 16.0, *) {
          UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        } else {
          UIApplication.shared.applicationIconBadgeNumber = count
        }
        result(nil)
      case "clearRead":
        // Notifications for chats now read leave Notification Center, but
        // only for messages the app has synced: each read chat comes with
        // its newest message's time, and a notification for a later message
        // arrived before sync did. Without the message's own time (set by
        // the notification service), the delivery time stands in.
        let read = (call.arguments as? [String: NSNumber]) ?? [:]
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
          let ids = delivered.filter { n in
            let content = n.request.content
            let room = (content.userInfo["room_id"] as? String) ?? content.threadIdentifier
            guard let newest = read[room]?.int64Value else { return false }
            let sent = (content.userInfo["ts"] as? NSNumber)?.int64Value ?? Int64(n.date.timeIntervalSince1970 * 1000)
            return sent <= newest
          }.map { $0.request.identifier }
          if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        result(nil)
      case "previews":
        // Whether notifications show their text on the lock screen. iOS
        // owns this (Settings › Notifications › Switchboard › Show
        // Previews); apps can only read it.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let value: String
          switch settings.showPreviewsSetting {
          case .always: value = "always"
          case .never: value = "never"
          default: value = "whenUnlocked"
          }
          DispatchQueue.main.async { result(value) }
        }
      case "openNotificationSettings":
        let page: String
        if #available(iOS 16.0, *) {
          page = UIApplication.openNotificationSettingsURLString
        } else {
          page = UIApplication.openSettingsURLString
        }
        if let url = URL(string: page) { UIApplication.shared.open(url) }
        result(nil)
      case "ready":
        // Dart is listening: hand over a chat tapped at launch.
        self.dartReady = true
        result(self.pendingRoom)
        self.pendingRoom = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    pushChannel = channel
  }

  /// Asks for permission, then for an APNs token, returned as hex.
  private func register(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
      DispatchQueue.main.async {
        guard granted else {
          result(FlutterError(code: "denied", message: "Notifications are turned off for Switchboard in Settings", details: nil))
          return
        }
        self.tokenWaiters.append(result)
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    tokenWaiters.forEach { $0(hex) }
    tokenWaiters.removeAll()
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    tokenWaiters.forEach { $0(FlutterError(code: "register", message: error.localizedDescription, details: nil)) }
    tokenWaiters.removeAll()
  }

  /// While the app is open it shows new messages itself.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  /// A tapped notification opens its chat.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let room = response.notification.request.content.userInfo["room_id"] as? String {
      if dartReady, let channel = pushChannel {
        channel.invokeMethod("openRoom", arguments: room)
      } else {
        pendingRoom = room
      }
    }
    completionHandler()
  }
}
