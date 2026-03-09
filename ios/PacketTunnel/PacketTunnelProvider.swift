import NetworkExtension
import os.log

// NOTE: LibXray — это Go Mobile XCFramework (аналог libv2ray на Android).
// Добавь LibXray.xcframework в таргет PacketTunnel в Xcode.
// Собрать: gomobile bind -target=ios github.com/2dust/AndroidLibXrayLite
// Или скачать готовый: https://github.com/2dust/AndroidLibXrayLite/releases

// Временный stub — заменить импортом реального фреймворка:
// import LibXray

private let log = OSLog(subsystem: "com.chrnet.vpn.PacketTunnel", category: "VPN")
private let appGroup = "group.com.chrnet.vpn"

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var xrayController: XrayCoreController?
    private var statsTimer: DispatchSourceTimer?
    private var totalDownload: Int64 = 0
    private var totalUpload: Int64 = 0

    // MARK: - Tunnel lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel called", log: log, type: .info)

        guard let rawUri = UserDefaults(suiteName: appGroup)?.string(forKey: "rawUri"),
              !rawUri.isEmpty else {
            completionHandler(makeError("Нет конфигурации сервера"))
            return
        }

        let ruRouting = UserDefaults(suiteName: appGroup)?.bool(forKey: "ruRouting") ?? false

        // 1. Настраиваем сетевые параметры TUN-интерфейса
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "240.0.0.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings error: %{public}@", log: log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }

            // 2. Запускаем Xray core
            do {
                try self.startXray(rawUri: rawUri, ruRouting: ruRouting)
                self.startStatsPolling()
                os_log("VPN started successfully", log: log, type: .info)
                completionHandler(nil)
            } catch {
                os_log("Xray start error: %{public}@", log: log, type: .error, error.localizedDescription)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel called, reason: %d", log: log, type: .info, reason.rawValue)
        stopStatsPolling()
        stopXray()
        completionHandler()
    }

    // MARK: - IPC from main app

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let message = String(data: messageData, encoding: .utf8) ?? ""
        if message == "getStats" {
            let stats: [String: Int64] = [
                "download": totalDownload,
                "upload":   totalUpload,
            ]
            let data = try? JSONSerialization.data(withJSONObject: stats)
            completionHandler?(data)
        } else {
            completionHandler?(nil)
        }
    }

    // MARK: - Xray core

    private func startXray(rawUri: String, ruRouting: Bool) throws {
        // Путь для файлов Xray (geoip.dat, geosite.dat)
        let configDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("xray") ?? URL(fileURLWithPath: NSTemporaryDirectory())

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // TODO: Заменить на реальные вызовы LibXray когда добавишь XCFramework:
        //
        // LibXray.initCoreEnv(configDir.path, "")
        //
        // let config = buildXrayConfig(rawUri: rawUri, ruRouting: ruRouting, tunFd: tunFd)
        //
        // let controller = LibXray.newCoreController(callback)
        // try controller.startLoop(config, tunFd)
        // xrayController = controller
        //
        // Для работы через SOCKS (без TUN fd):
        // let config = buildSocksConfig(rawUri: rawUri, port: 10808)
        // try controller.startLoop(config, -1)

        os_log("Xray core placeholder — подключи LibXray.xcframework", log: log, type: .debug)
        // Убери этот throw после добавления LibXray:
        throw makeError("LibXray.xcframework не подключён — добавь в Xcode таргет PacketTunnel")
    }

    private func stopXray() {
        // TODO: xrayController?.stopLoop()
        xrayController = nil
        os_log("Xray stopped", log: log, type: .info)
    }

    // MARK: - Stats

    private func startStatsPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // TODO: когда LibXray подключён:
            // let dl = (try? self.xrayController?.queryStats("proxy", "downlink")) ?? 0
            // let ul = (try? self.xrayController?.queryStats("proxy", "uplink")) ?? 0
            // self.totalDownload += dl
            // self.totalUpload += ul
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsPolling() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    // MARK: - Helpers

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "com.chrnet.vpn", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// Stub — удали после подключения LibXray
private class XrayCoreController {}
