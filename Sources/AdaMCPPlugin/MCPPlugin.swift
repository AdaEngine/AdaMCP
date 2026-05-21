import AdaEngine
import AdaMCPCore
import AdaMCPServer
import Logging

@MainActor
public struct MCPPlugin: Plugin {
    @MainActor
    final class State: @unchecked Sendable {
        let registry = MCPIntrospectionRegistry()
        let runtimeResource = MCPServerRuntime()
        let logger = Logger(label: "org.adaengine.mcp.plugin")
        var httpController: AdaMCPHTTPServerController?
        var stdioController: AdaMCPStdioServerController?
        var discoveryPublisher: AdaMCPDiscoveryPublisher?
        var renderCaptureService: RenderCaptureService?
        var traceRecorder: AdaMCPTraceRecorder?
    }

    private let configuration: MCPServerConfiguration
    private let state: State

    public init(configuration: MCPServerConfiguration = .init()) {
        self.configuration = configuration
        self.state = State()
    }

    public func setup(in app: borrowing AppWorlds) {
        AdaMCPBuiltins.registerDefaultTypes(in: state.registry)
        configuration.registerTypes?(state.registry)

        let appWorlds = copy app
        let renderCaptureService = RenderCaptureService(
            appWorlds: appWorlds,
            captureOverride: configuration.captureOverride
        )
        state.renderCaptureService = renderCaptureService
        if let activeRecorder = AdaMCPTraceRecorder.activeGlobalRecorder() {
            state.traceRecorder = activeRecorder
        } else if let traceRecorder = configuration.traceRecorder {
            if traceRecorder.installAsGlobalTracerIfPossible() {
                state.traceRecorder = traceRecorder
            } else {
                state.logger.warning("AdaMCP trace recorder could not install because InstrumentationSystem already has a non-AdaMCP instrument")
            }
        }

        app.insertResource(state.runtimeResource)
        app.insertResource(renderCaptureService)
    }

    public func finish(for app: borrowing AppWorlds) {
        AdaMCPBuiltins.registerAssetDescriptors(in: state.registry)
        guard let renderCaptureService = state.renderCaptureService else {
            return
        }

        state.logger.info(
            "Configuring AdaMCP server transports: HTTP=\(configuration.enableHTTP ? "enabled" : "disabled"), stdio=\(configuration.enableStdio ? "enabled" : "disabled")"
        )

        let appWorlds = copy app
        let runtime = AdaMCPRuntime(
            appWorlds: appWorlds,
            registry: state.registry,
            renderCaptureService: renderCaptureService,
            traceRecorder: state.traceRecorder,
            logger: state.logger
        )
        if configuration.enableHTTP {
            let controller = AdaMCPHTTPServerController(configuration: configuration, runtime: runtime)
            state.httpController = controller

            Task { @MainActor in
                do {
                    let endpointURL = try await controller.start(configuration: configuration)
                    self.state.runtimeResource.updateHTTP(endpointURL: endpointURL, isRunning: true)
                    if configuration.enableDiscovery {
                        let publisher = AdaMCPDiscoveryPublisher()
                        do {
                            try publisher.start(endpointURL: endpointURL, configuration: configuration)
                            self.state.discoveryPublisher = publisher
                        } catch {
                            self.state.logger.warning("Failed to publish AdaMCP discovery manifest: \(error.localizedDescription)")
                        }
                    }
                    self.state.logger.info("AdaMCP HTTP server is active at \(endpointURL.absoluteString)")
                } catch {
                    self.state.logger.error("Failed to start MCP HTTP server: \(error.localizedDescription)")
                    self.state.discoveryPublisher?.stop()
                    self.state.discoveryPublisher = nil
                    self.state.runtimeResource.updateHTTP(endpointURL: nil, isRunning: false)
                }
            }
        } else {
            state.runtimeResource.updateHTTP(endpointURL: nil, isRunning: false)
            state.discoveryPublisher?.stop()
            state.discoveryPublisher = nil
            state.logger.info("AdaMCP HTTP server transport is disabled")
        }

        if configuration.enableStdio {
            let controller = AdaMCPStdioServerController(runtime: runtime)
            state.stdioController = controller

            Task { @MainActor in
                do {
                    try await controller.start(configuration: configuration)
                    self.state.runtimeResource.updateStdio(isRunning: true)
                    self.state.logger.info("AdaMCP stdio server is active on stdin/stdout")
                } catch {
                    self.state.logger.error("Failed to start MCP stdio server: \(error.localizedDescription)")
                    self.state.runtimeResource.updateStdio(isRunning: false)
                }
            }
        } else {
            state.runtimeResource.updateStdio(isRunning: false)
            state.logger.info("AdaMCP stdio server transport is disabled")
        }

        if configuration.enableHTTP == false && configuration.enableStdio == false {
            state.logger.warning("AdaMCP server is configured with no active transports")
        }
    }

    public func destroy(for app: borrowing AppWorlds) {
        Task { @MainActor in
            self.state.discoveryPublisher?.stop()
            await self.state.httpController?.stop()
            await self.state.stdioController?.stop()
            self.state.runtimeResource.updateHTTP(endpointURL: nil, isRunning: false)
            self.state.runtimeResource.updateStdio(isRunning: false)
            self.state.httpController = nil
            self.state.stdioController = nil
            self.state.discoveryPublisher = nil
            self.state.logger.info("AdaMCP server transports stopped")
        }
    }
}
