import Flutter
import NetworkExtension
import UIKit

// MARK: - VpnPlugin

class VpnPlugin: NSObject, FlutterPlugin {

    static let methodChannelName = "com.chrnet.vpn/service"
    static let statsChannelName  = "com.chrnet.vpn/stats"

    // App Group shared between Runner and PacketTunnel extension
    static let appGroup = "group.com.chrnet.vpn"
    static let extensionBundleId = "com.chrnet.vpn.PacketTunnel"

    private var channel: FlutterMethodChannel!
    private var eventChannel: FlutterEventChannel!
    private var eventSink: FlutterEventSink?
    private var manager: NETunnelProviderManager?
    private var statsTimer: Timer?
    private var vpnObserver: NSObjectProtocol?

    // MARK: Register

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = VpnPlugin()
        let messenger = registrar.messenger()

        instance.channel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: instance.channel)

        instance.eventChannel = FlutterEventChannel(name: statsChannelName, binaryMessenger: messenger)
        instance.eventChannel.setStreamHandler(instance)

        instance.loadManager { _ in }
    }

    // MARK: Method call handler

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "connect":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARG", message: "Config is null", details: nil))
                return
            }
            connect(config: args, result: result)

        case "reconnect":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARG", message: "Config is null", details: nil))
                return
            }
            reconnect(config: args, result: result)

        case "disconnect":
            disconnect(result: result)

        case "getStatus":
            getStatus(result: result)

        case "getDeviceInfo":
            result([
                "deviceId": UIDevice.current.identifierForVendor?.uuidString ?? "",
                "osVersion": UIDevice.current.systemVersion,
                "model": UIDevice.current.model,
            ])

        case "getStats":
            fetchStats(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Connect / Disconnect

    private func connect(config: [String: Any], result: @escaping FlutterResult) {
        saveConfig(config)
        loadManager { [weak self] error in
            guard let self else { return }
            if let error {
                result(FlutterError(code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
                return
            }
            self.startTunnel(result: result)
        }
    }

    private func reconnect(config: [String: Any], result: @escaping FlutterResult) {
        saveConfig(config)
        loadManager { [weak self] error in
            guard let self else { return }
            if let error {
                result(FlutterError(code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
                return
            }
            self.stopTunnel { [weak self] in
                self?.startTunnel(result: result)
            }
        }
    }

    private func disconnect(result: @escaping FlutterResult) {
        stopTunnel {
            result(nil)
        }
    }

    private func getStatus(result: FlutterResult) {
        loadManager { [weak self] _ in
            guard let self, let manager = self.manager else {
                result(false)
                return
            }
            let running = manager.connection.status == .connected
            result(running)
        }
    }

    // MARK: Tunnel control

    private func startTunnel(result: @escaping FlutterResult) {
        guard let manager else {
            result(FlutterError(code: "NO_MANAGER", message: "VPN manager not loaded", details: nil))
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            observeConnection()
            startStatsPolling()
            result(nil)
        } catch {
            result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func stopTunnel(completion: @escaping () -> Void) {
        stopStatsPolling()
        stopObserving()
        guard let manager else { completion(); return }
        if manager.connection.status == .disconnected || manager.connection.status == .invalid {
            completion()
            return
        }
        manager.connection.stopVPNTunnel()
        var obs: NSObjectProtocol?
        obs = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak manager] _ in
            guard let s = manager?.connection.status,
                  s == .disconnected || s == .invalid else { return }
            if let obs { NotificationCenter.default.removeObserver(obs) }
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { completion() }
    }

    // MARK: Manager

    private func loadManager(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error { completion(error); return }

            let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == VpnPlugin.extensionBundleId
            })

            if let existing {
                self.manager = existing
                completion(nil)
                return
            }

            let mgr = NETunnelProviderManager()
            mgr.localizedDescription = "ChrNet VPN"
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = VpnPlugin.extensionBundleId
            proto.serverAddress = "ChrNet"
            proto.providerConfiguration = [:]
            mgr.protocolConfiguration = proto
            mgr.isEnabled = true

            mgr.saveToPreferences { [weak self] error in
                if let error { completion(error); return }
                self?.manager = mgr
                completion(nil)
            }
        }
    }

    // MARK: Connection observer

    private func observeConnection() {
        guard let manager else { return }
        stopObserving()
        vpnObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            self?.handleStatusChange()
        }
    }

    private func stopObserving() {
        if let obs = vpnObserver {
            NotificationCenter.default.removeObserver(obs)
            vpnObserver = nil
        }
    }

    private func handleStatusChange() {
        guard let status = manager?.connection.status else { return }
        switch status {
        case .connected:
            channel.invokeMethod("onConnected", arguments: nil)
        case .disconnected:
            stopStatsPolling()
            channel.invokeMethod("onDisconnected", arguments: nil)
        case .invalid:
            stopStatsPolling()
            channel.invokeMethod("onError", arguments: "VPN конфигурация недействительна")
        default:
            break
        }
    }

    // MARK: Stats

    private func startStatsPolling() {
        stopStatsPolling()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchStats(result: nil)
        }
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func fetchStats(result: FlutterResult?) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            result?(nil)
            return
        }
        do {
            try session.sendProviderMessage(Data("getStats".utf8)) { [weak self] data in
                guard let data, !data.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    result?(nil)
                    return
                }
                let stats: [String: Any] = [
                    "download": json["download"] ?? 0,
                    "upload":   json["upload"] ?? 0,
                ]
                result?(stats)
                self?.eventSink?(stats)
            }
        } catch {
            result?(nil)
        }
    }

    // MARK: Config

    private func saveConfig(_ config: [String: Any]) {
        let defaults = UserDefaults(suiteName: VpnPlugin.appGroup)
        defaults?.set(config["rawUri"] as? String ?? "", forKey: "rawUri")
        defaults?.set(config["ruRouting"] as? Bool ?? false, forKey: "ruRouting")
        defaults?.synchronize()
    }
}

// MARK: - FlutterStreamHandler

extension VpnPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
