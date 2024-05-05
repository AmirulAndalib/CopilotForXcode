import AppKit
import Foundation
import Logger
import XPCShared

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: CommunicationBridgeXPCServiceProtocol.self
        )

        let exportedObject = XPCService()
        newConnection.exportedObject = exportedObject
        newConnection.resume()

        Logger.communicationBridge.info("Accepted new connection.")

        return true
    }
}

class XPCService: CommunicationBridgeXPCServiceProtocol {
    static let eventHandler = EventHandler()

    func launchExtensionServiceIfNeeded(
        withReply reply: @escaping (NSXPCListenerEndpoint?) -> Void
    ) {
        Task {
            await Self.eventHandler.launchExtensionServiceIfNeeded(withReply: reply)
        }
    }

    func quit(withReply reply: @escaping () -> Void) {
        Task {
            await Self.eventHandler.quit(withReply: reply)
        }
    }

    func updateServiceEndpoint(
        endpoint: NSXPCListenerEndpoint,
        withReply reply: @escaping () -> Void
    ) {
        Task {
            await Self.eventHandler.updateServiceEndpoint(endpoint: endpoint, withReply: reply)
        }
    }
}

actor EventHandler {
    var endpoint: NSXPCListenerEndpoint?
    let launcher = ExtensionServiceLauncher()
    var exitTask: Task<Void, Error>?

    init() {
        Task { await rescheduleExitTask() }
    }

    func launchExtensionServiceIfNeeded(
        withReply reply: @escaping (NSXPCListenerEndpoint?) -> Void
    ) async {
        rescheduleExitTask()
        #if DEBUG
        reply(endpoint)
        #else
        if await launcher.isApplicationValid {
            reply(endpoint)
        } else {
            endpoint = nil
            await launcher.launch()
            reply(nil)
        }
        #endif
    }

    func quit(withReply reply: () -> Void) {
        Logger.communicationBridge.info("Exiting service.")
        listener.invalidate()
        exit(0)
    }

    func updateServiceEndpoint(endpoint: NSXPCListenerEndpoint, withReply reply: () -> Void) {
        rescheduleExitTask()
        self.endpoint = endpoint
        reply()
    }

    /// The bridge will kill itself when it's not used for a period.
    /// It's fine that the bridge is killed because it will be launched again when needed.
    private func rescheduleExitTask() {
        exitTask?.cancel()
        exitTask = Task {
            #if DEBUG
            try await Task.sleep(nanoseconds: 60_000_000_000)
            Logger.communicationBridge.info("Exit will be called in release build.")
            #else
            try await Task.sleep(nanoseconds: 1_800_000_000_000)
            Logger.communicationBridge.info("Exiting service.")
            listener.invalidate()
            exit(0)
            #endif
        }
    }
}

actor ExtensionServiceLauncher {
    let appIdentifier = bundleIdentifierBase.appending(".ExtensionService")
    let appURL = Bundle.main.bundleURL.appendingPathComponent(
        "CopilotForXcodeExtensionService.app"
    )
    var isLaunching: Bool = false
    var application: NSRunningApplication?
    var isApplicationValid: Bool {
        if let application, !application.isTerminated { return true }
        return false
    }

    func launch() {
        guard !isLaunching else { return }
        isLaunching = true

        Logger.communicationBridge.info("Launching extension service app.")
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: .init()
        ) { app, error in
            if let error = error {
                Logger.communicationBridge.error(
                    "Failed to launch extension service app: \(error)"
                )
            } else {
                Logger.communicationBridge.info(
                    "Finished launching extension service app."
                )
            }

            self.application = app
            self.isLaunching = false
        }
    }
}

