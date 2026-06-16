import BackgroundTasks
import Flutter
import Foundation

/// Native side of `audio_dashcam/recording_schedule`. The Dart controller owns
/// recording decisions; this bridge asks iOS for a wakeup near the next schedule
/// boundary and hands the barrier back to Dart when the engine is available.
final class RecordingScheduleBridge {
  private static let channelName = "audio_dashcam/recording_schedule"
  private static let taskIdentifier = "com.ores.audioDashcam.recordingScheduleBarrier"
  private static let pendingKey = "recording_schedule.pending_barrier"
  private static let nextBarrierKey = "recording_schedule.next_barrier_epoch_millis"

  private static var channel: FlutterMethodChannel?
  private static var didRegisterTask = false
  private static let defaults = UserDefaults.standard

  static func registerBackgroundTaskIfNeeded() {
    guard #available(iOS 13.0, *), !didRegisterTask else { return }
    didRegisterTask = true
    _ = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: taskIdentifier,
      using: nil
    ) { task in
      handleBackgroundTask(task)
    }
  }

  static func register(messenger: FlutterBinaryMessenger) {
    registerBackgroundTaskIfNeeded()
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
    deliverPendingBarrier()
  }

  private static func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "replaceSchedule":
      guard
        let args = call.arguments as? [String: Any],
        let millis = int64(args["nextBarrierEpochMillis"])
      else {
        clearSchedule()
        result(nil)
        return
      }
      defaults.set(millis, forKey: nextBarrierKey)
      scheduleBarrier(epochMillis: millis)
      result(nil)

    case "clearSchedule":
      clearSchedule()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 13.0, *)
  private static func handleBackgroundTask(_ task: BGTask) {
    task.expirationHandler = {
      task.setTaskCompleted(success: false)
    }
    markPendingBarrier()
    deliverPendingBarrier()
    if let millis = int64(defaults.object(forKey: nextBarrierKey)) {
      scheduleBarrier(epochMillis: millis)
    }
    task.setTaskCompleted(success: true)
  }

  private static func scheduleBarrier(epochMillis: Int64) {
    guard #available(iOS 13.0, *) else { return }
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
    request.earliestBeginDate = Date(
      timeIntervalSince1970: TimeInterval(epochMillis) / 1000.0
    )
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // iOS may decline background refresh based on user/system policy. Dart
      // still enforces barriers while the app is running.
    }
  }

  private static func clearSchedule() {
    defaults.removeObject(forKey: pendingKey)
    defaults.removeObject(forKey: nextBarrierKey)
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
  }

  private static func markPendingBarrier() {
    defaults.set(true, forKey: pendingKey)
  }

  private static func deliverPendingBarrier() {
    guard defaults.bool(forKey: pendingKey), let channel else { return }
    defaults.set(false, forKey: pendingKey)
    DispatchQueue.main.async {
      channel.invokeMethod("barrier", arguments: nil)
    }
  }

  private static func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let int = value as? Int {
      return Int64(int)
    }
    if let int64 = value as? Int64 {
      return int64
    }
    if let double = value as? Double {
      return Int64(double)
    }
    return nil
  }
}
