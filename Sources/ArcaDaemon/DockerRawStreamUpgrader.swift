import Foundation
import Logging
import NIO
import NIOHTTP1
import ContainerBridge
import Containerization  // For Writer protocol

/// SwiftNIO HTTP protocol upgrader for Docker's raw stream protocol
/// Handles upgrade from HTTP to raw TCP for Docker attach/exec operations
final class DockerRawStreamUpgrader: HTTPServerProtocolUpgrader, Sendable {
    private let logger: Logger
    private let execManager: ExecManager
    private let containerManager: ContainerBridge.ContainerManager
    private let logManager: ContainerBridge.ContainerLogManager

    // Required property: supported upgrade protocols
    let supportedProtocol: String = "tcp"

    // Optional headers to include in upgrade response
    let requiredUpgradeHeaders: [String] = []

    init(execManager: ExecManager, containerManager: ContainerBridge.ContainerManager, logManager: ContainerBridge.ContainerLogManager, logger: Logger) {
        self.execManager = execManager
        self.containerManager = containerManager
        self.logManager = logManager
        self.logger = logger
    }

    /// Determine if this request should be upgraded
    /// Docker clients send "Connection: Upgrade" and "Upgrade: tcp" headers
    func shouldUpgrade(channel: Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> {
        // Check if this is an endpoint that supports upgrade (exec or attach)
        let path = head.uri
        let isExecOrAttach = path.contains("/exec/") || path.contains("/attach")

        guard isExecOrAttach else {
            logger.debug("Not an exec/attach endpoint, no upgrade", metadata: ["path": "\(path)"])
            return channel.eventLoop.makeSucceededFuture(nil)
        }

        // Check for upgrade headers
        let connectionHeader = head.headers["Connection"].first?.lowercased() ?? ""
        let upgradeHeader = head.headers["Upgrade"].first?.lowercased() ?? ""

        let shouldUpgrade = connectionHeader.contains("upgrade") && upgradeHeader == "tcp"

        if shouldUpgrade {
            logger.info("Docker raw stream upgrade requested", metadata: [
                "path": "\(path)",
                "method": "\(head.method)"
            ])

            // Return headers to include in the 101 response
            var responseHeaders = HTTPHeaders()
            responseHeaders.add(name: "Content-Type", value: "application/vnd.docker.raw-stream")
            return channel.eventLoop.makeSucceededFuture(responseHeaders)
        } else {
            logger.debug("No upgrade headers found", metadata: ["path": "\(path)"])
            return channel.eventLoop.makeSucceededFuture(nil)
        }
    }

    /// Build the upgrade response (called after shouldUpgrade returns non-nil)
    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        logger.debug("Building upgrade response for Docker raw stream")

        var headers = initialResponseHeaders
        headers.add(name: "Connection", value: "Upgrade")
        headers.add(name: "Upgrade", value: "tcp")

        return channel.eventLoop.makeSucceededFuture(headers)
    }

    /// Perform the upgrade by adding protocol-specific handlers to the pipeline
    /// At this point, HTTP handlers have been removed and we have raw TCP
    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        logger.info("Upgrading connection to Docker raw stream protocol", metadata: [
            "path": "\(upgradeRequest.uri)",
            "method": "\(upgradeRequest.method)"
        ])

        // Determine if this is exec attach or container attach
        let path = upgradeRequest.uri
        let isExecAttach = path.contains("/exec/")
        let isContainerAttach = path.contains("/attach") && !isExecAttach

        // Parse query parameters from URI
        let queryParams = parseQueryParameters(from: upgradeRequest.uri)

        if isExecAttach {
            // Handle exec attach: /exec/{id}/start
            guard let execID = extractExecID(from: upgradeRequest.uri) else {
                logger.error("Failed to extract exec ID from URI", metadata: ["uri": "\(upgradeRequest.uri)"])
                return context.eventLoop.makeFailedFuture(UpgradeError.invalidURI)
            }
            logger.debug("Starting exec after upgrade", metadata: ["exec_id": "\(execID)"])
            return upgradeForExec(context: context, execID: execID)
        } else if isContainerAttach {
            // Handle container attach: /containers/{id}/attach
            guard let containerID = extractContainerID(from: upgradeRequest.uri) else {
                logger.error("Failed to extract container ID from URI", metadata: ["uri": "\(upgradeRequest.uri)"])
                return context.eventLoop.makeFailedFuture(UpgradeError.invalidURI)
            }
            logger.debug("Attaching to container after upgrade", metadata: ["container_id": "\(containerID)"])

            // Parse attach parameters - stdout/stderr/logs default to true (Docker behavior)
            let stdout = QueryParameterValidator.parseBooleanDefaultTrue(queryParams["stdout"])
            let stderr = QueryParameterValidator.parseBooleanDefaultTrue(queryParams["stderr"])
            let stream = QueryParameterValidator.parseBoolean(queryParams["stream"])
            let logs = QueryParameterValidator.parseBooleanDefaultTrue(queryParams["logs"])

            logger.debug("Attach parameters", metadata: [
                "stdout": "\(stdout)",
                "stderr": "\(stderr)",
                "stream": "\(stream)",
                "logs": "\(logs)"
            ])

            return upgradeForContainerAttach(
                context: context,
                containerID: containerID,
                stdout: stdout,
                stderr: stderr,
                stream: stream,
                logs: logs
            )
        } else {
            logger.error("Unknown attach type", metadata: ["uri": "\(upgradeRequest.uri)"])
            return context.eventLoop.makeFailedFuture(UpgradeError.invalidURI)
        }
    }

    /// Handle HTTP upgrade for exec attach
    private func upgradeForExec(context: ChannelHandlerContext, execID: String) -> EventLoopFuture<Void> {

        // Extract eventLoop, channel, and pipeline before closures to avoid capturing non-Sendable context
        let eventLoop = context.eventLoop
        let channel = context.channel
        let pipeline = context.pipeline

        // CRITICAL: Remove the HTTPHandler from the pipeline first
        // After upgrade, it will try to decode raw TCP data as HTTP and crash
        // We need to find and remove it before adding our raw stream handler
        let removeHTTPHandler = pipeline.handler(type: HTTPHandler.self).flatMap { handler in
            pipeline.removeHandler(handler)
        }.flatMapError { _ in
            // Handler not found or already removed - that's fine
            eventLoop.makeSucceededFuture(())
        }

        return removeHTTPHandler.flatMap { _ in
            // Create stdin reader for interactive exec
            let stdinReader = ChannelReader()

            // Add our raw stream handler with stdin support AT THE FRONT of the pipeline
            // CRITICAL: Must use .first position to ensure our handler receives data before
            // any remaining HTTP decoder/encoder handlers that may still be in the pipeline
            let rawHandler = DockerRawStreamHandler(logger: self.logger, stdinContinuation: stdinReader.continuation)
            return pipeline.addHandler(rawHandler, position: .first).flatMap { _ in
                // Fire channelActive manually since adding handler to active channel
                // doesn't automatically trigger channelActive callback
                if channel.isActive {
                    pipeline.fireChannelActive()
                }

                // CRITICAL: Allow client to close write side while keeping read side open
                // Docker CLI closes its write side after sending exec request but keeps reading output
                return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).map {
                    return stdinReader
                }.recover { error in
                    self.logger.error("Failed to set allowRemoteHalfClosure", metadata: ["error": "\(error)"])
                    return stdinReader
                }
            }
        }.flatMap { stdinReader in
            // CRITICAL: We must NOT return from this method until the exec completes
            // Returning signals to NIO that the upgrade is done and it may close the connection
            // We need to keep the connection open while the exec runs and sends output
            let promise = eventLoop.makePromise(of: Void.self)

            // Start the exec process and wait for it to complete
            Task {
                do {
                    try await self.startExecWithRawStream(execID: execID, channel: channel, stdinReader: stdinReader)
                    self.logger.debug("Exec stream completed successfully", metadata: ["exec_id": "\(execID)"])
                    // Signal success - this allows upgrade to complete and connection to close
                    promise.succeed(())
                } catch {
                    self.logger.error("Failed during exec stream", metadata: [
                        "exec_id": "\(execID)",
                        "error": "\(error)"
                    ])
                    // Close the channel on error (best effort)
                    try? await self.closeChannel(channel)
                    promise.fail(error)
                }
            }

            // Wait for the exec to complete before returning
            // This keeps the upgraded connection alive until we're done with it
            return promise.futureResult
        }
    }

    /// Handle HTTP upgrade for container attach
    private func upgradeForContainerAttach(
        context: ChannelHandlerContext,
        containerID: String,
        stdout: Bool,
        stderr: Bool,
        stream: Bool,
        logs: Bool
    ) -> EventLoopFuture<Void> {

        // Extract eventLoop, channel, and pipeline before closures to avoid capturing non-Sendable context
        let eventLoop = context.eventLoop
        let channel = context.channel
        let pipeline = context.pipeline

        // CRITICAL: Remove the HTTPHandler from the pipeline first
        // After upgrade, it will try to decode raw TCP data as HTTP and crash
        let removeHTTPHandler = pipeline.handler(type: HTTPHandler.self).flatMap { handler in
            pipeline.removeHandler(handler)
        }.flatMapError { _ in
            // Handler not found or already removed - that's fine
            eventLoop.makeSucceededFuture(())
        }

        return removeHTTPHandler.flatMap { _ in
            // Create stdin reader for interactive container
            let stdinReader = ChannelReader()

            // Add our raw stream handler with stdin support AT THE FRONT of the pipeline
            let rawHandler = DockerRawStreamHandler(logger: self.logger, stdinContinuation: stdinReader.continuation)
            return pipeline.addHandler(rawHandler, position: .first).flatMap { _ in
                // Fire channelActive manually since adding handler to active channel
                if channel.isActive {
                    pipeline.fireChannelActive()
                }

                // CRITICAL: Allow client to close write side while keeping read side open
                return channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).map {
                    return stdinReader
                }.recover { error in
                    self.logger.error("Failed to set allowRemoteHalfClosure", metadata: ["error": "\(error)"])
                    return stdinReader
                }
            }
        }.flatMap { stdinReader in
            // CRITICAL: We must NOT return from this method until the container exits
            // Returning signals to NIO that the upgrade is done and it may close the connection
            let promise = eventLoop.makePromise(of: Void.self)

            // Register attach handles with ContainerManager and wait for container to exit
            Task {
                do {
                    try await self.attachToContainer(
                        containerID: containerID,
                        channel: channel,
                        stdinReader: stdinReader,
                        stdout: stdout,
                        stderr: stderr,
                        logs: logs
                    )
                    self.logger.debug("Container attach completed successfully", metadata: ["container_id": "\(containerID)"])
                    promise.succeed(())
                } catch {
                    self.logger.error("Failed during container attach", metadata: [
                        "container_id": "\(containerID)",
                        "error": "\(error)"
                    ])
                    try? await self.closeChannel(channel)
                    promise.fail(error)
                }
            }

            // Wait for the container to exit before returning
            return promise.futureResult
        }
    }

    /// Attach to container and wait for it to exit
    private func attachToContainer(
        containerID: String,
        channel: Channel,
        stdinReader: ChannelReader,
        stdout: Bool,
        stderr: Bool,
        logs: Bool
    ) async throws {
        logger.info("Attaching to container with raw stream", metadata: [
            "container_id": "\(containerID)",
            "stdout": "\(stdout)",
            "stderr": "\(stderr)",
            "logs": "\(logs)"
        ])

        // Check if container is running with TTY
        guard let isTTY = await containerManager.getContainerTTY(id: containerID) else {
            logger.error("Container not found when getting TTY", metadata: ["container_id": "\(containerID)"])
            throw DockerRawStreamUpgraderError.containerNotFound(containerID)
        }

        logger.debug("Container TTY mode", metadata: ["container_id": "\(containerID)", "tty": "\(isTTY)"])

        // Create AsyncStreams for stdout/stderr from the container process
        // CRITICAL: Do this FIRST to avoid race condition with container start
        let (stdoutStream, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (stderrStream, stderrContinuation) = AsyncStream<Data>.makeStream()

        // Create writers that feed the AsyncStreams
        // TTY mode: Use RawWriter (no multiplexing headers)
        // Non-TTY mode: Use StreamingWriter (with multiplexing headers)
        let stdoutWriter: Writer
        let stderrWriter: Writer

        if isTTY {
            // TTY mode: Output is raw, no stream type headers
            stdoutWriter = RawWriter(continuation: stdoutContinuation)
            stderrWriter = RawWriter(continuation: stderrContinuation)
        } else {
            // Non-TTY mode: Output is multiplexed with stream type headers
            stdoutWriter = StreamingWriter(continuation: stdoutContinuation, streamType: 1)
            stderrWriter = StreamingWriter(continuation: stderrContinuation, streamType: 2)
        }

        // Create a continuation to signal when the container exits
        let exitContinuation = AsyncStream<Void>.makeStream()

        // Create attach handles
        let handles = ContainerBridge.ContainerManager.AttachHandles(
            stdin: stdinReader,
            stdout: stdoutWriter,
            stderr: stderrWriter,
            waitForExit: {
                // Wait for the exit signal
                for await _ in exitContinuation.stream {
                    break
                }
            }
        )

        // Register attach handles with ContainerManager IMMEDIATELY
        // CRITICAL: Do this before reading historical logs to avoid race with container start
        await containerManager.registerAttach(containerID: containerID, handles: handles, exitSignal: exitContinuation.continuation)

        logger.debug("Attach handles registered, starting forward task", metadata: ["container_id": "\(containerID)"])

        // Start task to forward stream data to the raw TCP channel
        let forwardTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Forward stdout
                group.addTask {
                    var count = 0
                    for await data in stdoutStream {
                        count += 1
                        do {
                            try await self.writeToChannel(channel: channel, data: data)
                            self.logger.debug("Wrote stdout chunk", metadata: [
                                "container_id": "\(containerID)",
                                "bytes": "\(data.count)",
                                "chunk": "\(count)"
                            ])
                        } catch {
                            // Client disconnected - stop forwarding to avoid log spam
                            self.logger.info("Client disconnected, stopping stdout forwarding", metadata: [
                                "container_id": "\(containerID)",
                                "chunks_sent": "\(count)"
                            ])
                            break
                        }
                    }
                    self.logger.debug("Stdout forwarding finished", metadata: [
                        "container_id": "\(containerID)",
                        "chunks": "\(count)"
                    ])
                }

                // Forward stderr
                group.addTask {
                    var count = 0
                    for await data in stderrStream {
                        count += 1
                        do {
                            try await self.writeToChannel(channel: channel, data: data)
                            self.logger.debug("Wrote stderr chunk", metadata: [
                                "container_id": "\(containerID)",
                                "bytes": "\(data.count)",
                                "chunk": "\(count)"
                            ])
                        } catch {
                            // Client disconnected - stop forwarding
                            self.logger.info("Client disconnected, stopping stderr forwarding", metadata: [
                                "container_id": "\(containerID)",
                                "chunks_sent": "\(count)"
                            ])
                            break
                        }
                    }
                    self.logger.debug("Stderr forwarding finished", metadata: [
                        "container_id": "\(containerID)",
                        "chunks": "\(count)"
                    ])
                }

                await group.waitForAll()
            }
        }

        // Now that attach handles are registered and forward task is running,
        // send historical logs if requested (this can be slow, but won't block container start)
        if logs {
            logger.debug("Reading historical logs for attach", metadata: ["container_id": "\(containerID)"])

            // Get log paths for this container
            if let logPaths = logManager.getLogPaths(dockerID: containerID) {
                do {
                    // Read and format historical logs
                    let historicalLogs = try retrieveHistoricalLogs(
                        logPaths: logPaths,
                        stdout: stdout,
                        stderr: stderr
                    )

                    // Send historical logs to channel
                    if !historicalLogs.isEmpty {
                        try await writeToChannel(channel: channel, data: historicalLogs)
                        logger.debug("Sent historical logs", metadata: [
                            "container_id": "\(containerID)",
                            "bytes": "\(historicalLogs.count)"
                        ])
                    } else {
                        logger.debug("No historical logs to send", metadata: ["container_id": "\(containerID)"])
                    }
                } catch {
                    logger.warning("Failed to read historical logs (non-fatal)", metadata: [
                        "container_id": "\(containerID)",
                        "error": "\(error)"
                    ])
                    // Continue with live attach even if historical logs fail
                }
            } else {
                logger.debug("No log paths registered for container", metadata: ["container_id": "\(containerID)"])
            }
        }

        // Wait for container to exit (the start logic will call the waitForExit closure)
        try await handles.waitForExit()

        logger.debug("Container exited, waiting for forward task", metadata: ["container_id": "\(containerID)"])

        // Wait for all data to be forwarded
        await forwardTask.value

        logger.debug("Forward task completed", metadata: ["container_id": "\(containerID)"])

        // Close the channel (non-fatal if already closed)
        do {
            try await closeChannel(channel)
            logger.debug("Channel closed successfully", metadata: ["container_id": "\(containerID)"])
        } catch {
            logger.debug("Channel already closed or close failed", metadata: [
                "container_id": "\(containerID)",
                "error": "\(error)"
            ])
        }
    }

    /// Extract exec ID from URI path
    private func extractExecID(from uri: String) -> String? {
        // Remove query parameters if present
        let path = uri.split(separator: "?").first.map(String.init) ?? uri

        // Match patterns: /exec/{id}/start or /v1.XX/exec/{id}/start
        let components = path.split(separator: "/")

        // Find "exec" component and get the next component as ID
        if let execIndex = components.firstIndex(of: "exec"),
           execIndex + 1 < components.count {
            return String(components[execIndex + 1])
        }

        return nil
    }

    /// Extract container ID from URI path
    private func extractContainerID(from uri: String) -> String? {
        // Remove query parameters if present
        let path = uri.split(separator: "?").first.map(String.init) ?? uri

        // Match patterns: /containers/{id}/attach or /v1.XX/containers/{id}/attach
        let components = path.split(separator: "/")

        // Find "containers" component and get the next component as ID
        if let containersIndex = components.firstIndex(of: "containers"),
           containersIndex + 1 < components.count {
            return String(components[containersIndex + 1])
        }

        return nil
    }

    /// Start exec process and wire up raw TCP stream
    private func startExecWithRawStream(execID: String, channel: Channel, stdinReader: ChannelReader) async throws {
        logger.info("Starting exec with raw stream", metadata: ["exec_id": "\(execID)"])

        // Get exec info to check TTY mode
        guard let execInfo = await execManager.getExecInfo(execID: execID) else {
            throw DockerRawStreamUpgraderError.execNotFound(execID)
        }

        let isTTY = execInfo.config.tty

        // Create AsyncStreams for stdout/stderr from the exec process
        let (stdoutStream, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (stderrStream, stderrContinuation) = AsyncStream<Data>.makeStream()

        // Create writers that feed the AsyncStreams
        // TTY mode: Use RawWriter (no multiplexing headers)
        // Non-TTY mode: Use StreamingWriter (with multiplexing headers)
        let stdoutWriter: Writer
        let stderrWriter: Writer

        if isTTY {
            // TTY mode: Output is raw, no stream type headers
            stdoutWriter = RawWriter(continuation: stdoutContinuation)
            stderrWriter = RawWriter(continuation: stderrContinuation)
            logger.debug("Using raw writers for TTY mode", metadata: ["exec_id": "\(execID)"])
        } else {
            // Non-TTY mode: Output is multiplexed with stream type headers
            stdoutWriter = StreamingWriter(continuation: stdoutContinuation, streamType: 1)
            stderrWriter = StreamingWriter(continuation: stderrContinuation, streamType: 2)
            logger.debug("Using streaming writers for non-TTY mode", metadata: ["exec_id": "\(execID)"])
        }

        // Start task to forward stream data to the raw TCP channel
        let forwardTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // Forward stdout
                group.addTask {
                    var count = 0
                    for await data in stdoutStream {
                        count += 1
                        do {
                            try await self.writeToChannel(channel: channel, data: data)
                            self.logger.debug("Wrote stdout chunk", metadata: [
                                "exec_id": "\(execID)",
                                "bytes": "\(data.count)",
                                "chunk": "\(count)"
                            ])
                        } catch {
                            // Client disconnected (Ctrl+C, connection loss, etc.)
                            // Stop forwarding output to avoid log spam
                            // Note: The exec process continues running (Docker behavior)
                            // For non-TTY exec, Ctrl+C just closes the client, doesn't signal the process
                            self.logger.info("Client disconnected, stopping stdout forwarding", metadata: [
                                "exec_id": "\(execID)",
                                "chunks_sent": "\(count)"
                            ])
                            break
                        }
                    }
                    self.logger.debug("Stdout forwarding finished", metadata: [
                        "exec_id": "\(execID)",
                        "chunks": "\(count)"
                    ])
                }

                // Forward stderr
                group.addTask {
                    var count = 0
                    for await data in stderrStream {
                        count += 1
                        do {
                            try await self.writeToChannel(channel: channel, data: data)
                            self.logger.debug("Wrote stderr chunk", metadata: [
                                "exec_id": "\(execID)",
                                "bytes": "\(data.count)",
                                "chunk": "\(count)"
                            ])
                        } catch {
                            // Client disconnected - stop forwarding
                            self.logger.info("Client disconnected, stopping stderr forwarding", metadata: [
                                "exec_id": "\(execID)",
                                "chunks_sent": "\(count)"
                            ])
                            break
                        }
                    }
                    self.logger.debug("Stderr forwarding finished", metadata: [
                        "exec_id": "\(execID)",
                        "chunks": "\(count)"
                    ])
                }

                await group.waitForAll()
            }
        }

        do {
            // Start the exec process with stdin support
            // Note: We're passing tty: nil which lets ExecManager use the value from exec creation
            try await execManager.startExec(
                execID: execID,
                detach: false,
                tty: nil,
                stdin: stdinReader,
                stdout: stdoutWriter,
                stderr: stderrWriter
            )

            logger.info("Exec process completed", metadata: ["exec_id": "\(execID)"])

            // Wait for all data to be forwarded
            await forwardTask.value

            logger.debug("Forward task completed", metadata: ["exec_id": "\(execID)"])

            // Close the channel (non-fatal if already closed)
            do {
                try await closeChannel(channel)
                logger.debug("Channel closed successfully", metadata: ["exec_id": "\(execID)"])
            } catch {
                logger.debug("Channel already closed or close failed", metadata: [
                    "exec_id": "\(execID)",
                    "error": "\(error)"
                ])
            }

        } catch {
            logger.error("Exec process failed", metadata: [
                "exec_id": "\(execID)",
                "error": "\(error)"
            ])

            forwardTask.cancel()
            try? await closeChannel(channel)

            // Re-throw the error - it will be caught by the upgrade task
            throw error
        }
    }

    /// Write data to raw TCP channel
    private func writeToChannel(channel: Channel, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)

                channel.writeAndFlush(buffer).whenComplete { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Close the channel
    private func closeChannel(_ channel: Channel) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute {
                channel.close().whenComplete { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Parse query parameters from URI
    private func parseQueryParameters(from uri: String) -> [String: String] {
        guard let queryStart = uri.firstIndex(of: "?") else {
            return [:]
        }

        let queryString = uri[uri.index(after: queryStart)...]
        var params: [String: String] = [:]

        for component in queryString.split(separator: "&") {
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0])
                let value = String(parts[1])
                params[key] = value
            } else if parts.count == 1 {
                // Parameter without value (e.g., "?stream")
                let key = String(parts[0])
                params[key] = "1"
            }
        }

        return params
    }

    /// Retrieve and format historical logs from log files
    /// Returns Docker multiplexed stream format data
    private func retrieveHistoricalLogs(
        logPaths: ContainerBridge.ContainerLogManager.LogPaths,
        stdout: Bool,
        stderr: Bool
    ) throws -> Data {
        var allLogs: [LogEntry] = []

        // Helper to parse log files
        func parseLogs(from path: URL, forStream stream: String) throws {
            guard FileManager.default.fileExists(atPath: path.path) else {
                return
            }

            let content = try String(contentsOf: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                guard !line.isEmpty else { continue }

                // Parse the JSON log entry with ContainerBridge's own codec.
                // A default-options ISO8601DateFormatter cannot read the
                // fractional-seconds stamps the writer emits and returns nil
                // for every one, which would leave this an empty log rather
                // than an error.
                guard let data = line.data(using: .utf8),
                      let entry = try? ContainerBridge.ContainerLogCodec.decode(line: data),
                      let payload = try? ContainerBridge.ContainerLogCodec.payload(of: entry),
                      let timestamp = ContainerBridge.LogEntryTimestamp.date(from: entry.time) else {
                    continue
                }

                allLogs.append(LogEntry(
                    stream: entry.stream,
                    message: String(decoding: payload, as: UTF8.self),
                    timestamp: timestamp
                ))
            }
        }

        // Read from stdout log file if requested
        if stdout {
            try parseLogs(from: logPaths.stdoutPath, forStream: "stdout")
        }

        // Read from stderr log file if requested
        if stderr {
            try parseLogs(from: logPaths.stderrPath, forStream: "stderr")
        }

        // Sort by timestamp (logs from different streams need to be interleaved chronologically)
        allLogs.sort { $0.timestamp < $1.timestamp }

        // Format as Docker multiplexed stream
        return formatMultiplexedStream(logs: allLogs)
    }

    /// Format log entries as Docker multiplexed stream
    /// Docker format: [stream_type (1 byte)][padding (3 bytes)][size (4 bytes big-endian)][payload]
    /// Stream types: 0=stdin, 1=stdout, 2=stderr
    private func formatMultiplexedStream(logs: [LogEntry]) -> Data {
        var result = Data()

        for entry in logs {
            // Determine stream type
            let streamType: UInt8 = entry.stream == "stdout" ? 1 : 2

            // Convert message to data
            guard let messageData = entry.message.data(using: .utf8) else {
                continue
            }

            // Build frame header: [stream_type][padding][size]
            var header = Data()
            header.append(streamType)                    // 1 byte: stream type
            header.append(contentsOf: [0, 0, 0])        // 3 bytes: padding

            // 4 bytes: size (big-endian UInt32)
            let size = UInt32(messageData.count)
            header.append(UInt8((size >> 24) & 0xFF))
            header.append(UInt8((size >> 16) & 0xFF))
            header.append(UInt8((size >> 8) & 0xFF))
            header.append(UInt8(size & 0xFF))

            // Append header + payload
            result.append(header)
            result.append(messageData)
        }

        return result
    }

    /// Log entry structure
    private struct LogEntry {
        let stream: String
        let message: String
        let timestamp: Date
    }

    enum UpgradeError: Error {
        case invalidURI
    }
}

/// Handler for Docker raw stream protocol (after HTTP upgrade)
/// Keeps the channel pipeline alive after HTTP upgrade
/// All I/O is handled directly via channel.writeAndFlush in the upgrader
final class DockerRawStreamHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let logger: Logger
    private let stdinContinuation: AsyncStream<UInt8>.Continuation?

    init(logger: Logger, stdinContinuation: AsyncStream<UInt8>.Continuation? = nil) {
        self.logger = logger
        self.stdinContinuation = stdinContinuation
    }

    func channelActive(context: ChannelHandlerContext) {
        // Enable auto-read to keep the channel alive
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { error in
            self.logger.error("Failed to enable auto-read", metadata: ["error": "\(error)"])
        }

        // Trigger initial read
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        logger.debug("Received raw stream data", metadata: ["bytes": "\(buffer.readableBytes)"])

        // Forward stdin data to the exec process
        if let stdinCont = stdinContinuation {
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            for byte in bytes {
                stdinCont.yield(byte)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // The read loop will continue automatically with autoRead enabled
        context.fireChannelReadComplete()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Handle half-closure: client closed write side (sent EOF on stdin) but keeps read side open
        if event is ChannelEvent, (event as! ChannelEvent) == ChannelEvent.inputClosed {
            stdinContinuation?.finish()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error in Docker raw stream handler", metadata: ["error": "\(error)"])
        // Close stdin stream if active
        stdinContinuation?.finish()

        // Only close if channel is still active to avoid "Bad file descriptor" errors
        // when the channel is already closing/closed
        if context.channel.isActive {
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Close stdin stream when channel closes
        stdinContinuation?.finish()
    }
}

/// Errors that can occur during Docker raw stream upgrade
enum DockerRawStreamUpgraderError: Error, CustomStringConvertible {
    case execNotFound(String)
    case containerNotFound(String)

    var description: String {
        switch self {
        case .execNotFound(let execID):
            return "Exec instance not found: \(execID)"
        case .containerNotFound(let containerID):
            return "Container not found: \(containerID)"
        }
    }
}
