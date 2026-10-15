import Foundation
import Darwin
import IndexCore
import MCP

@main struct EverythingMCP {
    static func main() async {
        do {
            let options = try MCPOptions.parse(Array(CommandLine.arguments.dropFirst()))
            switch options.action {
            case .help:
                print(MCPOptions.help)
            case .version:
                // Source: the same published IndexCore.version used by the CLI.
                print(IndexCore.version)
            case .serve:
                let server = await makeServer(cacheURL: options.cacheURL)
                try await server.start(transport: StdioTransport())
                await server.waitUntilCompleted()
                await server.stop()
            }
        } catch {
            // Source: the actual argument, transport or filesystem failure.
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(2)
        }
    }

    static func makeServer(cacheURL: URL) async -> Server {
        let index = MCPIndexService(cacheURL: cacheURL)
        // Source: this executable's product name, IndexCore.version and the
        // saved-cache-only operations implemented by MCPIndexService.
        let server = Server(name: "everything-mac", version: IndexCore.version,
            instructions: "Searches EverythingMac's saved index, not the app's live state or file contents. "
                + "Each call reads the latest saved cache. Indexed paths may be offline or no longer exist.",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPToolDefinitions.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard MCPToolDefinitions.tools.contains(where: { $0.name == params.name }) else {
                // Source: the submitted tool name and the registered tool list.
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            do {
                let cancellation = MCPWorkCancellation()
                let value = try await withTaskCancellationHandler {
                    try await index.call(name: params.name, arguments: params.arguments ?? [:],
                                         isCancelled: { cancellation.isCancelled })
                } onCancel: {
                    cancellation.cancel()
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let text = String(decoding: try encoder.encode(value), as: UTF8.self)
                // MCP specifies structuredContent plus serialized text for older clients.
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)],
                             structuredContent: Optional.some(value), isError: false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Source: the actual input/query/scope/cache validation failure.
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                             isError: true)
            }
        }
        return server
    }
}
