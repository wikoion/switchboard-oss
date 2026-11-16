import AVFoundation
import CallKit
import Flutter
import Foundation
import SwitchboardRingRTC
import UIKit

/// One Signal call, as RingRTC and CallKit know it.
final class SignalCall: CallManagerCallReference {
  let roomId: String
  /// The contact's Signal ID (ACI).
  let remoteUuid: UUID
  let name: String
  let incoming: Bool
  /// CallKit's ID for it.
  let uuid = UUID()
  var callId: UInt64?
  /// Offered as a video call.
  let offeredVideo: Bool
  /// Our camera, sent once connected.
  var localVideo: Bool
  var muted = false
  var remoteVideo = false
  /// CallKit was told about it, so its actions go through CallKit.
  var inCallKit = false
  /// Answer was pressed here before CallKit had the call.
  var answerWhenReported = false
  /// Answer was pressed here. Only then does an incoming call connect (see
  /// `shouldStartCall`).
  var answered = false
  /// The bridge's Signal device, which every Switchboard app answers as.
  var localDevice: UInt32 = 0
  /// Why it ended, when RingRTC only knows the app dropped it.
  var endReason: CallEndReason?
  var ended = false

  init(roomId: String, remoteUuid: UUID, name: String, incoming: Bool, video: Bool) {
    self.roomId = roomId
    self.remoteUuid = remoteUuid
    self.name = name
    self.incoming = incoming
    offeredVideo = video
    localVideo = !incoming && video
  }
}

/// Signal calls on iOS: RingRTC's CallManager, with CallKit for the system
/// call screen, the audio session and lock-screen controls. The core reads
/// and sends the call events in chats; Dart passes them through
/// "switchboard/calls" (see app/lib/src/state/calls_ios.dart).
///
/// Dart calls: received, place, accept, hangUp, setMuted, setVideo.
/// It answers: settings (the bridge's device and TURN servers), send (a
/// call event, answered once the server has it), and takes update (where
/// the call is up to).
@MainActor
final class CallsBridge: NSObject, CallManagerDelegate {
  typealias CallManagerDelegateCallType = SignalCall

  private var channel: FlutterMethodChannel?
  private lazy var manager: CallManager<SignalCall, CallsBridge> = {
    let manager = CallManager<SignalCall, CallsBridge>(httpClient: HTTPClient())
    manager.delegate = self
    return manager
  }()
  private let provider: CXProvider
  private let callController = CXCallController()
  private let capture = VideoCaptureController()
  private let providerDelegate = ProviderDelegate()
  private var call: SignalCall?

  /// The contact's video, drawn by Flutter from a texture, and our camera,
  /// for the preview's platform view.
  private var remoteTrack: RTCVideoTrack?
  private var remoteTexture: RemoteVideoTexture?
  private(set) var localSession: AVCaptureSession?
  private let videoViews = NSHashTable<CallVideoView>.weakObjects()

  override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    // Recents would offer to call back through the app, which we can't take.
    config.includesCallsInRecents = false
    provider = CXProvider(configuration: config)
    super.init()
    providerDelegate.bridge = self
    provider.setDelegate(providerDelegate, queue: nil)
    // WebRTC starts audio only when CallKit hands over the audio session.
    let audio = RTCAudioSession.sharedInstance()
    audio.useManualAudio = true
    audio.isAudioEnabled = false
  }

  func attach(to messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
    let channel = FlutterMethodChannel(name: "switchboard/calls", binaryMessenger: messenger)
    let texture = RemoteVideoTexture(registry: textures)
    let textureId = texture.id
    texture.onShape = { [weak channel] width, height, rotation in
      channel?.invokeMethod(
        "remoteVideo",
        arguments: ["textureId": textureId, "width": width, "height": height, "rotation": rotation])
    }
    remoteTexture = texture
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      do {
        switch call.method {
        case "received":
          try self.received(args)
          result(nil)
        case "place":
          self.place(args, result)
        case "accept":
          try self.accept(video: args["video"] as? Bool ?? false)
          result(nil)
        case "hangUp":
          self.hangUp()
          result(nil)
        case "setMuted":
          self.setMuted(args["muted"] as? Bool ?? false)
          result(nil)
        case "setVideo":
          try self.setVideo(args["enabled"] as? Bool ?? false)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "call", message: "\(error)", details: nil))
      }
    }
    self.channel = channel
  }

  // MARK: Dart's calls

  /// A call event from the contact, in order.
  private func received(_ args: [String: Any]) throws {
    guard let kind = args["kind"] as? String,
      let callId = (args["callId"] as? String).flatMap(UInt64.init),
      let remoteUuid = (args["uuid"] as? String).flatMap(UUID.init(uuidString:)),
      let roomId = args["roomId"] as? String
    else { throw BridgeError("incomplete call event") }
    let device = uint32(args["senderDeviceId"])
    switch kind {
    case "offer":
      let video = args["video"] as? Bool ?? false
      let call = SignalCall(
        roomId: roomId, remoteUuid: remoteUuid, name: args["name"] as? String ?? "Signal", incoming: true, video: video)
      call.localDevice = uint32(args["localDevice"])
      offered[callId] = call
      try manager.receivedOffer(
        call: call, remoteUuid: remoteUuid, sourceDevice: device, callId: callId, opaque: data(args["opaque"]),
        messageAgeSec: UInt64(uint32(args["ageSecs"])), callMediaType: video ? .videoCall : .audioCall,
        localDevice: call.localDevice, senderIdentityKey: data(args["senderIdentityKey"]),
        receiverIdentityKey: data(args["receiverIdentityKey"]))
    case "answer":
      try manager.receivedAnswer(
        remoteUuid: remoteUuid, sourceDevice: device, callId: callId, opaque: data(args["opaque"]),
        senderIdentityKey: data(args["senderIdentityKey"]), receiverIdentityKey: data(args["receiverIdentityKey"]))
    case "ice":
      let candidates = (args["candidates"] as? [FlutterStandardTypedData] ?? []).map(\.data)
      try manager.receivedIceCandidates(
        remoteUuid: remoteUuid, sourceDevice: device, callId: callId, candidates: candidates)
    case "hangup":
      let type = HangupType(rawValue: Int32(truncatingIfNeeded: (args["hangupType"] as? NSNumber)?.intValue ?? 0))
      let hangupDevice = uint32(args["hangupDeviceId"])
      // Every Switchboard app is the bridge's one Signal device, so "taken on
      // another device" naming that device, for a call not answered here,
      // means another Switchboard app took it. RingRTC would ignore it as
      // our own, and this app would ring on.
      if let type, type != .normal, let call = offered[callId], call.incoming, !call.answered,
        hangupDevice == call.localDevice
      {
        call.endReason = Self.elsewhere(type)
        manager.drop(callId: callId)
        return
      }
      try manager.receivedHangup(
        remoteUuid: remoteUuid, sourceDevice: device, callId: callId, hangupType: type ?? .normal,
        deviceId: hangupDevice)
    case "busy":
      try manager.receivedBusy(remoteUuid: remoteUuid, sourceDevice: device, callId: callId)
    default:
      throw BridgeError("unknown call event \(kind)")
    }
  }

  /// Rings the contact, through CallKit so the system knows there's a call.
  private func place(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard call == nil else {
      result(FlutterError(code: "busy", message: "already in a call", details: nil))
      return
    }
    guard let roomId = args["roomId"] as? String,
      let remoteUuid = (args["uuid"] as? String).flatMap(UUID.init(uuidString:))
    else {
      result(FlutterError(code: "call", message: "no Signal contact for this chat", details: nil))
      return
    }
    let video = args["video"] as? Bool ?? false
    let call = SignalCall(
      roomId: roomId, remoteUuid: remoteUuid, name: args["name"] as? String ?? "Signal", incoming: false,
      video: video)
    let localDevice = uint32(args["localDevice"])
    self.call = call
    configureAudioSession(video: video)
    let start = CXStartCallAction(call: call.uuid, handle: CXHandle(type: .generic, value: call.name))
    start.isVideo = video
    pendingPlace = (call, localDevice)
    callController.request(CXTransaction(action: start)) { error in
      Task { @MainActor in
        if let error {
          if self.call === call { self.call = nil }
          self.pendingPlace = nil
          result(FlutterError(code: "call", message: "\(error)", details: nil))
        } else {
          call.inCallKit = true
          result(nil)
        }
      }
    }
  }

  private var pendingPlace: (SignalCall, UInt32)?
  /// Incoming calls by RingRTC's call ID, from their offer until they end.
  private var offered: [UInt64: SignalCall] = [:]

  private func accept(video: Bool) throws {
    guard let call, call.incoming, !call.answered else { throw BridgeError("no call to answer") }
    call.localVideo = video
    guard call.inCallKit else {
      call.answerWhenReported = true
      return
    }
    requestCallKit(CXAnswerCallAction(call: call.uuid))
  }

  /// Ends the call, or declines it while it rings.
  private func hangUp() {
    guard let call else { return }
    if call.inCallKit {
      requestCallKit(CXEndCallAction(call: call.uuid))
    } else {
      try? manager.hangup()
    }
  }

  private func setMuted(_ muted: Bool) {
    guard let call else { return }
    if call.inCallKit {
      requestCallKit(CXSetMutedCallAction(call: call.uuid, muted: muted))
    } else {
      call.muted = muted
    }
  }

  private func setVideo(_ enabled: Bool) throws {
    guard let call else { throw BridgeError("not in a call") }
    call.localVideo = enabled
    manager.setLocalVideoEnabled(call: call, enabled: enabled)
  }

  private func requestCallKit(_ action: CXCallAction) {
    callController.request(CXTransaction(action: action)) { error in
      if let error { NSLog("switchboard: CallKit \(type(of: action)): \(error)") }
    }
  }

  // MARK: CallKit's actions (ProviderDelegate passes them on)

  fileprivate func performStart(_ action: CXStartCallAction) {
    guard let (call, localDevice) = pendingPlace, call.uuid == action.callUUID else {
      action.fail()
      return
    }
    pendingPlace = nil
    do {
      try manager.placeCall(
        call: call, remoteUuid: call.remoteUuid, callMediaType: call.offeredVideo ? .videoCall : .audioCall,
        localDevice: localDevice)
      action.fulfill()
    } catch {
      self.call = nil
      action.fail()
    }
  }

  /// Connects the call now; RingRTC rings once it has, and is accepted then.
  fileprivate func performAnswer(_ action: CXAnswerCallAction) {
    guard let call, call.uuid == action.callUUID, let callId = call.callId, !call.answered else {
      action.fail()
      return
    }
    call.answered = true
    emit(call, "connecting")
    proceed(call, callId)
    action.fulfill()
  }

  fileprivate func performEnd(_ action: CXEndCallAction) {
    if let call, call.uuid == action.callUUID {
      try? manager.hangup()
    }
    action.fulfill()
  }

  fileprivate func performMute(_ action: CXSetMutedCallAction) {
    guard let call, call.uuid == action.callUUID else {
      action.fail()
      return
    }
    call.muted = action.isMuted
    manager.setLocalAudioEnabled(enabled: !action.isMuted)
    action.fulfill()
  }

  fileprivate func providerReset() {
    try? manager.hangup()
  }

  // MARK: The audio session

  private func configureAudioSession(video: Bool) {
    let session = RTCAudioSession.sharedInstance()
    session.lockForConfiguration()
    defer { session.unlockForConfiguration() }
    var options: AVAudioSession.CategoryOptions = []
    // iOS 26 renamed it; older SDKs (Xcode 16) only have the old name.
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        options.insert(.allowBluetoothHFP)
      } else {
        options.insert(.allowBluetooth)
      }
    #else
      options.insert(.allowBluetooth)
    #endif
    // Video calls play through the speaker, voice calls the earpiece.
    do {
      try session.setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: options)
    } catch {
      NSLog("switchboard: call audio session: \(error)")
    }
  }

  fileprivate func audioSessionActivated(_ session: AVAudioSession) {
    let audio = RTCAudioSession.sharedInstance()
    audio.audioSessionDidActivate(session)
    audio.isAudioEnabled = true
  }

  fileprivate func audioSessionDeactivated(_ session: AVAudioSession) {
    let audio = RTCAudioSession.sharedInstance()
    audio.audioSessionDidDeactivate(session)
    audio.isAudioEnabled = false
    // Back to iOS's default, or videos in chats would play through the
    // earpiece after a voice call.
    do {
      try session.setCategory(.soloAmbient, mode: .default)
    } catch {
      NSLog("switchboard: resetting the audio session: \(error)")
    }
  }

  // MARK: RingRTC

  /// Outgoing calls connect at once. Incoming ones ring but wait for Answer:
  /// every open Switchboard app answers to Signal as the bridge's one
  /// device, and the caller connects to the first answer it gets, so only
  /// the app where Answer is pressed may send one.
  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldStartCall call: SignalCall, callId: UInt64, isOutgoing: Bool, callMediaType: CallMediaType) {
    call.callId = callId
    self.call = call
    emit(call, isOutgoing ? "outgoing" : "incoming")
    if isOutgoing {
      proceed(call, callId)
    } else {
      configureAudioSession(video: call.offeredVideo)
      reportIncoming(call)
      // Warms the core's cache of the bridge's settings for Answer.
      channel?.invokeMethod("settings", arguments: nil)
    }
  }

  private func proceed(_ call: SignalCall, _ callId: UInt64) {
    // The TURN servers come from the bridge, through Dart and the core.
    channel?.invokeMethod("settings", arguments: nil) { [weak self] value in
      guard let self else { return }
      let settings = value as? [String: Any]
      let servers = (settings?["iceServers"] as? [[String: Any]] ?? []).map { server in
        RTCIceServer(
          urlStrings: server["urls"] as? [String] ?? [], username: server["username"] as? String,
          credential: server["password"] as? String, tlsCertPolicy: .secure,
          hostname: (server["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 })
      }
      if servers.isEmpty { NSLog("switchboard: no TURN servers for the call") }
      do {
        try self.manager.proceed(
          callId: callId, iceServers: servers, hideIp: false, videoCaptureController: self.capture,
          dataMode: .normal, audioLevelsIntervalMillis: nil)
        // Placing a video call shows the camera while it rings.
        if !call.incoming && call.localVideo {
          self.manager.setLocalVideoEnabled(call: call, enabled: true)
        }
      } catch {
        NSLog("switchboard: call proceed: \(error)")
        self.manager.drop(callId: callId)
      }
    }
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onEvent call: SignalCall, event: CallManagerEvent) {
    switch event {
    case .ringingLocal:
      // Incoming calls only connect once answered (see shouldStartCall).
      if call.answered, let callId = call.callId {
        do {
          try manager.accept(callId: callId)
        } catch {
          NSLog("switchboard: call accept: \(error)")
        }
      }
    case .ringingRemote:
      emit(call, "ringing")
      provider.reportOutgoingCall(with: call.uuid, startedConnectingAt: nil)
    case .connectedLocal, .connectedRemote:
      if !call.incoming { provider.reportOutgoingCall(with: call.uuid, connectedAt: nil) }
      manager.setLocalAudioEnabled(enabled: !call.muted)
      manager.setLocalVideoEnabled(call: call, enabled: call.localVideo)
      emit(call, "connected")
    case .remoteVideoEnable, .remoteVideoDisable:
      call.remoteVideo = event == .remoteVideoEnable
      if self.call === call { emit(call, currentPhase) }
    case .receivedOfferExpired, .receivedOfferWhileActive, .receivedOfferWithGlare, .glareHandlingFailure:
      // An offer RingRTC turned away; Dart drops the end of a call it never showed.
      emit(call, "ended", reason: Self.reasonName("\(event)"))
    default:
      break
    }
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onCallEnded call: SignalCall, callId: UInt64, reason: CallEndReason, summary: CallSummary) {
    let reason = call.endReason ?? reason
    call.ended = true
    offered[callId] = nil
    if call.inCallKit && reason != .localHangup {
      provider.reportCall(with: call.uuid, endedAt: nil, reason: Self.endedReason(reason))
    }
    if self.call === call {
      if let remoteTexture {
        remoteTrack?.remove(remoteTexture)
        remoteTexture.clear()
      }
      remoteTrack = nil
      localSession = nil
      videoViewsChanged()
    }
    emit(call, "ended", reason: Self.reasonName("\(reason)"))
    if self.call === call { self.call = nil }
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onCallConcluded call: SignalCall) {
    if let callId = call.callId { offered[callId] = nil }
    if self.call === call { self.call = nil }
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onNetworkRouteChangedFor call: SignalCall, networkRoute: NetworkRoute) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onAudioLevelsFor call: SignalCall, capturedLevel: UInt16, receivedLevel: UInt16) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onLowBandwidthForVideoFor call: SignalCall, recovered: Bool) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendOffer callId: UInt64, call: SignalCall, destinationDeviceId: UInt32?, opaque: Data, callMediaType: CallMediaType) {
    send(call, callId, "offer", destinationDeviceId, ["opaque": typed(opaque), "video": callMediaType == .videoCall])
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendAnswer callId: UInt64, call: SignalCall, destinationDeviceId: UInt32?, opaque: Data) {
    send(call, callId, "answer", destinationDeviceId, ["opaque": typed(opaque)])
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendIceCandidates callId: UInt64, call: SignalCall, destinationDeviceId: UInt32?, candidates: [Data]) {
    send(call, callId, "ice", destinationDeviceId, ["candidates": candidates.map(typed)])
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendHangup callId: UInt64, call: SignalCall, destinationDeviceId: UInt32?, hangupType: HangupType, deviceId: UInt32) {
    var extra: [String: Any] = ["hangupType": Int(hangupType.rawValue)]
    // Only the "on another device" kinds name a device.
    if hangupType != .normal { extra["hangupDeviceId"] = Int(deviceId) }
    send(call, callId, "hangup", destinationDeviceId, extra)
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendBusy callId: UInt64, call: SignalCall, destinationDeviceId: UInt32?) {
    send(call, callId, "busy", destinationDeviceId, [:])
  }

  // Group calls aren't supported.
  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendCallMessage recipientUuid: UUID, message: Data, urgency: CallMessageUrgency) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendCallMessageToGroup groupId: Data, message: Data, urgency: CallMessageUrgency, overrideRecipients: [UUID]) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, shouldSendCallMessageToAdhocGroup message: Data, urgency: CallMessageUrgency, expiration: Date, recipientsToEndorsements: [UUID: Data]) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, didUpdateRingForGroup groupId: Data, ringId: Int64, sender: UUID, update: RingUpdate) {}

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onUpdateLocalVideoSession call: SignalCall, session: AVCaptureSession?) {
    localSession = session
    videoViewsChanged()
  }

  func callManager(_ callManager: CallManager<SignalCall, CallsBridge>, onAddRemoteVideoTrack call: SignalCall, track: RTCVideoTrack) {
    if let remoteTexture {
      remoteTrack?.remove(remoteTexture)
      track.add(remoteTexture)
    }
    remoteTrack = track
  }

  // MARK: Helpers

  private var currentPhase: String = "incoming"

  private func emit(_ call: SignalCall, _ phase: String, reason: String? = nil) {
    if self.call === call { currentPhase = phase }
    channel?.invokeMethod(
      "update",
      arguments: [
        "roomId": call.roomId,
        "callId": call.callId.map(String.init) ?? "",
        "phase": phase,
        "video": call.offeredVideo,
        "remoteVideo": call.remoteVideo,
        "reason": reason as Any,
      ])
  }

  private func reportIncoming(_ call: SignalCall) {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: call.name)
    update.localizedCallerName = call.name
    update.hasVideo = call.offeredVideo
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    provider.reportNewIncomingCall(with: call.uuid, update: update) { error in
      Task { @MainActor in
        if let error {
          // Do Not Disturb or a blocked caller: leave the call to the other
          // devices rather than declining it for all of them.
          NSLog("switchboard: CallKit refused the call: \(error)")
          if let callId = call.callId, !call.ended { self.manager.drop(callId: callId) }
          return
        }
        call.inCallKit = true
        if call.ended {
          // It ended while CallKit was being told.
          self.provider.reportCall(
            with: call.uuid, endedAt: nil, reason: Self.endedReason(call.endReason ?? .remoteHangup))
        } else if call.answerWhenReported {
          call.answerWhenReported = false
          self.requestCallKit(CXAnswerCallAction(call: call.uuid))
        }
      }
    }
  }

  /// Sends a call event through Dart and the core; RingRTC waits for each
  /// to be sent, so candidates found meanwhile go out together.
  private func send(
    _ call: SignalCall, _ callId: UInt64, _ kind: String, _ destination: UInt32?, _ extra: [String: Any]
  ) {
    var args: [String: Any] = ["roomId": call.roomId, "kind": kind, "callId": String(callId)]
    if let destination { args["destinationDeviceId"] = Int(destination) }
    args.merge(extra) { $1 }
    guard let channel else {
      manager.signalingMessageDidFail(callId: callId)
      return
    }
    channel.invokeMethod("send", arguments: args) { [weak self] value in
      guard let self else { return }
      if value is FlutterError || (value as? NSObject) === FlutterMethodNotImplemented {
        NSLog("switchboard: sending call \(kind): \(String(describing: value))")
        self.manager.signalingMessageDidFail(callId: callId)
      } else {
        try? self.manager.signalingMessageDidSend(callId: callId)
      }
    }
  }

  fileprivate func register(_ view: CallVideoView) {
    videoViews.add(view)
  }

  private func videoViewsChanged() {
    for view in videoViews.allObjects { view.update() }
  }

  /// RingRTC's names, as the Linux core gives them: `remoteHangup` is
  /// "RemoteHangup".
  static func reasonName(_ name: String) -> String {
    name.prefix(1).uppercased() + name.dropFirst()
  }

  /// How a call taken by another Switchboard app ended, as RingRTC says it
  /// for other devices.
  static func elsewhere(_ type: HangupType) -> CallEndReason {
    switch type {
    case .accepted: return .remoteHangupAccepted
    case .declined: return .remoteHangupDeclined
    case .busy: return .remoteHangupBusy
    case .needPermission: return .remoteHangupNeedPermission
    case .normal: return .remoteHangup
    }
  }

  static func endedReason(_ reason: CallEndReason) -> CXCallEndedReason {
    switch reason {
    case .timeout: return .unanswered
    case .remoteHangupAccepted: return .answeredElsewhere
    case .remoteHangupDeclined, .remoteHangupBusy: return .declinedElsewhere
    case .internalFailure, .signalingFailure, .connectionFailure: return .failed
    default: return .remoteEnded
    }
  }
}

/// CallKit's delegate, on the main queue, passing actions to the bridge.
private final class ProviderDelegate: NSObject, CXProviderDelegate {
  weak var bridge: CallsBridge?

  func providerDidReset(_ provider: CXProvider) {
    MainActor.assumeIsolated { bridge?.providerReset() }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    MainActor.assumeIsolated { bridge?.performStart(action) ?? action.fail() }
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    MainActor.assumeIsolated { bridge?.performAnswer(action) ?? action.fail() }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    MainActor.assumeIsolated { bridge?.performEnd(action) ?? action.fulfill() }
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    MainActor.assumeIsolated { bridge?.performMute(action) ?? action.fail() }
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { bridge?.audioSessionActivated(audioSession) }
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { bridge?.audioSessionDeactivated(audioSession) }
  }
}

/// Our camera's preview in Flutter, as a platform view on RingRTC's capture
/// session: "switchboard/call-video". The contact's video is a texture
/// (RemoteVideoTexture).
final class CallVideoFactory: NSObject, FlutterPlatformViewFactory {
  private weak var bridge: CallsBridge?

  init(bridge: CallsBridge) {
    self.bridge = bridge
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    MainActor.assumeIsolated { CallVideoView(frame: frame, bridge: bridge) }
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

@MainActor
final class CallVideoView: NSObject, FlutterPlatformView {
  private let container: PreviewContainer
  private weak var bridge: CallsBridge?

  init(frame: CGRect, bridge: CallsBridge?) {
    container = PreviewContainer(frame: frame)
    container.backgroundColor = .black
    container.clipsToBounds = true
    container.preview.videoGravity = .resizeAspectFill
    self.bridge = bridge
    super.init()
    bridge?.register(self)
    update()
  }

  nonisolated func view() -> UIView {
    MainActor.assumeIsolated { container }
  }

  /// Follows the bridge's capture session.
  func update() {
    container.preview.session = bridge?.localSession
  }
}

/// The contact's video as a Flutter texture, so Flutter draws it like any
/// other widget. In an RTCMTLVideoView inside a platform view it froze
/// often while the call carried on. Frames come on WebRTC's decoding
/// thread; hardware-decoded ones are passed on as they are, and the I420
/// ones the software decoders give are copied into NV12, which Flutter
/// draws itself. Rotation is left to Flutter (onShape).
final class RemoteVideoTexture: NSObject, FlutterTexture, RTCVideoRenderer {
  private weak var registry: FlutterTextureRegistry?
  private(set) var id: Int64 = 0
  /// On the main thread when the frame's size or rotation changes: width,
  /// height and rotation in degrees, or zeros once cleared.
  var onShape: ((Int, Int, Int) -> Void)?

  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var shape = (0, 0, 0)
  private var notifyPending = false
  private var lastFrame: CFTimeInterval = 0
  // Only touched on the decoding thread.
  private var pool: CVPixelBufferPool?
  private var poolSize = (0, 0)

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
    id = registry.register(self)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return latest.map { Unmanaged.passRetained($0) }
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame, let buffer = pixelBuffer(for: frame) else { return }
    let now = CACurrentMediaTime()
    let frameShape = (Int(frame.width), Int(frame.height), frame.rotation.rawValue)
    lock.lock()
    let gap = lastFrame > 0 ? now - lastFrame : 0
    lastFrame = now
    latest = buffer
    let changed = frameShape != shape
    shape = frameShape
    let notify = changed || !notifyPending
    notifyPending = true
    lock.unlock()
    // Frames that stop coming are the network or the decoder, not drawing.
    if gap > 1 { NSLog("switchboard: remote video: no frame for %.1f s", gap) }
    guard notify else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.notifyPending = false
      self.lock.unlock()
      if changed { self.onShape?(frameShape.0, frameShape.1, frameShape.2) }
      self.registry?.textureFrameAvailable(self.id)
    }
  }

  /// Drops the last frame when the call ends.
  func clear() {
    lock.lock()
    latest = nil
    shape = (0, 0, 0)
    lastFrame = 0
    lock.unlock()
    DispatchQueue.main.async { [weak self] in self?.onShape?(0, 0, 0) }
  }

  private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
    if let cv = frame.buffer as? RTCCVPixelBuffer, !cv.requiresCropping() {
      switch CVPixelBufferGetPixelFormatType(cv.pixelBuffer) {
      case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA:
        return cv.pixelBuffer
      default:
        break
      }
    }
    return nv12(frame.buffer.toI420())
  }

  private func nv12(_ i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
    let width = Int(i420.width), height = Int(i420.height)
    if pool == nil || poolSize != (width, height) {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      pool = nil
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
      poolSize = (width, height)
    }
    var out: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else {
      return nil
    }
    CVPixelBufferLockBaseAddress(out, [])
    defer { CVPixelBufferUnlockBaseAddress(out, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(out, 0),
      let uvBase = CVPixelBufferGetBaseAddressOfPlane(out, 1)
    else { return nil }
    let y = yBase.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
    for row in 0..<height {
      memcpy(y + row * yStride, i420.dataY + row * Int(i420.strideY), width)
    }
    let uv = uvBase.assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
    let chromaWidth = Int(i420.chromaWidth)
    for row in 0..<Int(i420.chromaHeight) {
      let u = i420.dataU + row * Int(i420.strideU)
      let v = i420.dataV + row * Int(i420.strideV)
      let line = uv + row * uvStride
      for col in 0..<chromaWidth {
        line[2 * col] = u[col]
        line[2 * col + 1] = v[col]
      }
    }
    return out
  }
}

/// A view whose layer previews a capture session.
final class PreviewContainer: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
  var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct BridgeError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func uint32(_ value: Any?) -> UInt32 {
  UInt32(truncatingIfNeeded: (value as? NSNumber)?.int64Value ?? 0)
}

private func data(_ value: Any?) -> Data {
  (value as? FlutterStandardTypedData)?.data ?? Data()
}

private func typed(_ data: Data) -> FlutterStandardTypedData {
  FlutterStandardTypedData(bytes: data)
}
