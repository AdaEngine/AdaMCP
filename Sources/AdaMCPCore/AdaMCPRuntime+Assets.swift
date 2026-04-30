import AdaEngine
import MCP

extension AdaMCPRuntime {
    func assetFindPayload(arguments: [String: Value]) async throws -> Value {
        let assets = await AssetsManager.cachedAssets().filter { asset in
            if let path = arguments["path"]?.stringValue, !asset.assetPath.contains(path) {
                return false
            }
            if let name = arguments["name"]?.stringValue, !asset.assetName.localizedCaseInsensitiveContains(name) {
                return false
            }
            if let type = arguments["type"]?.stringValue, asset.typeName != type {
                return false
            }
            if let assetID = arguments["assetId"]?.stringValue, asset.assetID != assetID {
                return false
            }
            return true
        }
        return ["assets": .array(assets.map(self.makeAssetPayload))]
    }

    func assetGetPayload(arguments: [String: Value]) async throws -> Value {
        let assetsValue = try await self.assetFindPayload(arguments: arguments)
        guard let first = assetsValue.objectValue?["assets"]?.arrayValue?.first else {
            let query = arguments.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            throw AdaMCPError.assetNotFound(query)
        }
        return first
    }
}

private extension AdaMCPRuntime {
    func makeAssetPayload(_ asset: AssetsManager.CachedAssetInfo) -> Value {
        let diagnostics: [Value]
        if registry.descriptor(named: asset.typeName) == nil {
            diagnostics = [
                self.diagnosticValue(
                    code: "unregistered_asset_descriptor",
                    message: "Asset type \(asset.typeName) has no explicit MCP descriptor."
                )
            ]
        } else {
            diagnostics = []
        }

        return .object([
            "type": .string(asset.typeName),
            "kind": .string(MCPTypeKind.asset.rawValue),
            "id": asset.assetID.map(Value.string) ?? .null,
            "name": .string(asset.assetName),
            "world": .null,
            "summary": .object([
                "isLoaded": .bool(asset.isLoaded),
                "handleCount": .int(asset.handleCount)
            ]),
            "fields": .object([
                "assetPath": .string(asset.assetPath),
                "assetName": .string(asset.assetName),
                "assetID": asset.assetID.map(Value.string) ?? .null,
                "isLoaded": .bool(asset.isLoaded),
                "handleCount": .int(asset.handleCount)
            ]),
            "diagnostics": .array(diagnostics)
        ])
    }
}
