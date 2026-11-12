import Flutter
import UIKit
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CLLocationManagerDelegate {
  private var keepAliveLocationManager: CLLocationManager?
  private var isKeepAliveActive: Bool = false
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var backgroundChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    let messenger: FlutterBinaryMessenger? = (window?.rootViewController as? FlutterViewController)?.binaryMessenger
      ?? self.registrar(forPlugin: "com.datbike.mybike/ios_background")?.messenger()

    if let messenger = messenger {
      setupMethodChannel(messenger: messenger)
    }

    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "com.datbike.mybike/ios_background")?.messenger() {
      setupMethodChannel(messenger: messenger)
    }
  }

  private func setupMethodChannel(messenger: FlutterBinaryMessenger) {
    guard backgroundChannel == nil else { return }
    let channel = FlutterMethodChannel(
      name: "com.datbike.mybike/ios_background",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(FlutterError(code: "DEALLOCATED", message: "AppDelegate deallocated", details: nil))
        return
      }
      switch call.method {
      case "startBackgroundKeepAlive", "updateBackgroundKeepAlive":
        self.startOrUpdateKeepAlive()
        result(true)
      case "stopBackgroundKeepAlive":
        self.stopKeepAlive()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    backgroundChannel = channel
  }

  private func startOrUpdateKeepAlive() {
    isKeepAliveActive = true

    if keepAliveLocationManager == nil {
      keepAliveLocationManager = CLLocationManager()
    }

    guard let manager = keepAliveLocationManager else { return }
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = kCLDistanceFilterNone
    manager.pausesLocationUpdatesAutomatically = false

    if let bgModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
       bgModes.contains("location") {
      manager.allowsBackgroundLocationUpdates = true
    }

    if #available(iOS 11.0, *) {
      manager.showsBackgroundLocationIndicator = false
    }

    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }

    if status == .notDetermined {
      manager.requestAlwaysAuthorization()
    } else if status == .authorizedWhenInUse || status == .authorizedAlways {
      manager.startUpdatingLocation()
      if CLLocationManager.significantLocationChangeMonitoringAvailable() {
        manager.startMonitoringSignificantLocationChanges()
      }
    }

    beginOrRenewBackgroundTask()
  }

  private func stopKeepAlive() {
    isKeepAliveActive = false
    keepAliveLocationManager?.stopUpdatingLocation()
    if CLLocationManager.significantLocationChangeMonitoringAvailable() {
      keepAliveLocationManager?.stopMonitoringSignificantLocationChanges()
    }
    endBackgroundTask()
  }

  private func beginOrRenewBackgroundTask() {
    endBackgroundTask()
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "DatBikeBleKeepAlive") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    if bgTask != .invalid {
      let taskToStop = bgTask
      bgTask = .invalid
      UIApplication.shared.endBackgroundTask(taskToStop)
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    if isKeepAliveActive {
      beginOrRenewBackgroundTask()
      keepAliveLocationManager?.startUpdatingLocation()
    }
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isKeepAliveActive else { return }
    if UIApplication.shared.applicationState == .background {
      beginOrRenewBackgroundTask()
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = manager.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }
    handleAuthorization(status: status)
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    handleAuthorization(status: status)
  }

  private func handleAuthorization(status: CLAuthorizationStatus) {
    if (status == .authorizedAlways || status == .authorizedWhenInUse) && isKeepAliveActive {
      keepAliveLocationManager?.startUpdatingLocation()
      if CLLocationManager.significantLocationChangeMonitoringAvailable() {
        keepAliveLocationManager?.startMonitoringSignificantLocationChanges()
      }
      if UIApplication.shared.applicationState == .background {
        beginOrRenewBackgroundTask()
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Không làm sập ứng dụng nếu định vị tạm thời không khả dụng
  }
}
