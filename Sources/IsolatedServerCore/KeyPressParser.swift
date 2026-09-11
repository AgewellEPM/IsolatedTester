import Foundation
import IsolatedTesterKit

/// Shared MCP/HTTP validation; invalid input must fail before placement or input.
public enum KeyPressParser {
    public static func parse(key: String?, modifiers: [String]? = nil) throws -> KeyCombination {
        do {
            return try KeyCombination.parse(key: key, modifiers: modifiers)
        } catch let error as KeyCombinationError {
            throw ServerError.invalidRequest(error.localizedDescription)
        }
    }

    /// Decode the MCP dictionary strictly instead of silently discarding bad types.
    /// An omitted/null optional modifiers field matches ActionRequest's Codable API.
    public static func action(arguments: [String: Any]) throws -> ActionRequest {
        guard let key = arguments["key"] as? String else {
            throw ServerError.invalidRequest("keyPress requires a string key parameter")
        }
        let modifiers: [String]?
        if let value = arguments["modifiers"], !(value is NSNull) {
            guard let strings = value as? [String] else {
                throw ServerError.invalidRequest("keyPress modifiers must be an array of strings")
            }
            modifiers = strings
        } else {
            modifiers = nil
        }
        _ = try parse(key: key, modifiers: modifiers)
        return ActionRequest(action: "keyPress", key: key, modifiers: modifiers)
    }
}
