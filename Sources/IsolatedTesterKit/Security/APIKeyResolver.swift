import Foundation

/// Resolves API keys from multiple sources in priority order:
/// 1. Explicit CLI flag
/// 2. Environment variable
/// 3. Config file
/// 4. macOS Keychain
public struct APIKeyResolver {

    /// Resolve the API key for a given provider.
    public static func resolve(
        provider: String,
        explicit: String? = nil,
        config: Configuration? = nil
    ) -> String? {
        // 1. Explicit (CLI flag)
        if let key = explicit, !key.isEmpty {
            return key
        }

        // 2. Environment variable
        let envKey = environmentKey(for: provider)
        if let key = ProcessInfo.processInfo.environment[envKey], !key.isEmpty {
            return key
        }

        // 3. Config file
        if let key = config?.apiKey, !key.isEmpty {
            return key
        }

        // 4. Keychain
        if let key = KeychainManager.retrieve(provider: provider), !key.isEmpty {
            return key
        }

        return nil
    }

    /// Get the environment variable name for a provider.
    public static func environmentKey(for provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "ANTHROPIC_API_KEY"
        case "openai": return "OPENAI_API_KEY"
        case "ollama": return "OLLAMA_API_KEY"
        default: return "\(provider.uppercased())_API_KEY"
        }
    }
}
