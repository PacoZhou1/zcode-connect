import Foundation
import CryptoKit

private enum HookWire {
    static func object(_ value: RelayJSON, keys: Set<String>, required: Set<String>? = nil) throws -> [String: RelayJSON] {
        let fields = try value.requiringObject()
        guard Set(fields.keys).isSubset(of: keys), (required ?? keys).isSubset(of: Set(fields.keys)) else { throw RelayFailure("hook_review_invalid", "The workspace hook review has missing or unsupported fields.") }
        return fields
    }
    static func text(_ value: RelayJSON, _ key: String) throws -> String {
        guard let text = value[key].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RelayFailure("hook_review_invalid", "Missing hook review field: \(key).") }; return text
    }
    static func flag(_ value: RelayJSON, _ key: String) throws -> Bool {
        guard let flag = value[key].bool else { throw RelayFailure("hook_review_invalid", "Invalid hook review flag: \(key).") }; return flag
    }
    static func digest(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RelayFailure("hook_review_invalid", "Invalid workspace hook digest.") }
    }
    static func hash(_ value: RelayJSON) throws -> String { SHA256.hash(data: try value.data()).map { String(format: "%02x", $0) }.joined() }
}

public struct RelayHookReviewSourceFile: Codable, Sendable, Equatable {
    public let path: String
    public let displayPath: String
    public let editable: Bool
    public let wire: RelayJSON
    public init(wire: RelayJSON) throws {
        _ = try HookWire.object(wire, keys: ["path", "displayPath", "editable"])
        path = try HookWire.text(wire, "path"); displayPath = try HookWire.text(wire, "displayPath"); editable = try HookWire.flag(wire, "editable"); self.wire = wire
    }
    public init(from decoder: any Decoder) throws { try self.init(wire: RelayJSON(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
}

public struct RelayHookReviewSummary: Codable, Sendable, Equatable {
    public let eventCount: Int
    public let hookCount: Int
    public let pendingCount: Int
    public let wire: RelayJSON
    public init(wire: RelayJSON) throws {
        _ = try HookWire.object(wire, keys: ["eventCount", "hookCount", "pendingCount"])
        eventCount = try wire.requiringInt("eventCount"); hookCount = try wire.requiringInt("hookCount"); pendingCount = try wire.requiringInt("pendingCount"); self.wire = wire
    }
    public init(from decoder: any Decoder) throws { try self.init(wire: RelayJSON(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
}

public struct RelayHookReviewItem: Codable, Sendable, Equatable, Identifiable {
    public let reviewItemId: String
    public var id: String { reviewItemId }
    public let event: String
    public let matcher: String?
    public let type: String
    public let displayName: String
    public let displayCommand: String
    public let sourcePath: String
    public let resolvedTimeoutMs: Int
    public let resolvedMaxOutputBytes: Int
    public let executionMode: String
    public let configuredEnabled: Bool
    public let editable: Bool
    public let trustState: String
    public let wire: RelayJSON
    public var needsTrust: Bool { ["pending_trust", "revoked", "stale_digest"].contains(trustState) }
    public init(wire: RelayJSON) throws {
        let required: Set<String> = ["reviewItemId", "event", "type", "displayName", "displayCommand", "sourcePath", "resolvedTimeoutMs", "resolvedMaxOutputBytes", "executionMode", "configuredEnabled", "editable", "trustState"]
        _ = try HookWire.object(wire, keys: required.union(["matcher"]), required: required)
        reviewItemId = try HookWire.text(wire, "reviewItemId"); event = try HookWire.text(wire, "event"); type = try HookWire.text(wire, "type")
        displayName = try HookWire.text(wire, "displayName"); displayCommand = try HookWire.text(wire, "displayCommand"); sourcePath = try HookWire.text(wire, "sourcePath")
        resolvedTimeoutMs = try wire.requiringInt("resolvedTimeoutMs", minimum: 1); resolvedMaxOutputBytes = try wire.requiringInt("resolvedMaxOutputBytes", minimum: 1)
        executionMode = try HookWire.text(wire, "executionMode"); trustState = try HookWire.text(wire, "trustState")
        configuredEnabled = try HookWire.flag(wire, "configuredEnabled"); editable = try HookWire.flag(wire, "editable")
        guard ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure", "Stop"].contains(event), ["command", "process"].contains(type), ["foreground", "background"].contains(executionMode), ["not_applicable", "pending_trust", "trusted_persistent", "blocked_untrusted", "blocked_policy", "revoked", "stale_digest"].contains(trustState), wire.object?["matcher"] == nil || wire["matcher"].string != nil else { throw RelayFailure("hook_review_invalid", "Unknown hook event, execution mode or trust state.") }
        matcher = wire["matcher"].string; self.wire = wire
    }
    public init(from decoder: any Decoder) throws { try self.init(wire: RelayJSON(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
}

public struct RelayHookReviewTarget: Codable, Sendable, Equatable {
    public let sessionId: String
    public let taskId: String
    public let runId: String
    public let remoteSessionId: String?
    public let workspaceIdentity: String
    public let bundleDigest: String
    public let reviewFlowId: String
    public let generation: Int
    public let interactionId: String
    public let wire: RelayJSON
    public init(wire: RelayJSON) throws {
        let required: Set<String> = ["sessionId", "taskId", "runId", "workspaceIdentity", "bundleDigest", "reviewFlowId", "generation", "interactionId"]
        _ = try HookWire.object(wire, keys: required.union(["remoteSessionId"]), required: required)
        sessionId = try HookWire.text(wire, "sessionId"); taskId = try HookWire.text(wire, "taskId"); runId = try HookWire.text(wire, "runId")
        workspaceIdentity = try HookWire.text(wire, "workspaceIdentity"); bundleDigest = try HookWire.text(wire, "bundleDigest"); try HookWire.digest(bundleDigest)
        reviewFlowId = try HookWire.text(wire, "reviewFlowId"); generation = try wire.requiringInt("generation", minimum: 1); interactionId = try HookWire.text(wire, "interactionId")
        remoteSessionId = wire.object?["remoteSessionId"] == nil ? nil : try HookWire.text(wire, "remoteSessionId"); self.wire = wire
    }
    public init(from decoder: any Decoder) throws { try self.init(wire: RelayJSON(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
}

public enum RelayHookReviewOperation: Sendable, Equatable {
    case trustSelected(itemIDs: [String])
    case revokeSelected(itemIDs: [String])
    case setEnabled(itemID: String, enabled: Bool)
    public var commandType: String {
        switch self { case .trustSelected: "respondWorkspaceHookReview"; case .revokeSelected: "revokeWorkspaceHookTrust"; case .setEnabled: "toggleWorkspaceHookReviewItem" }
    }
    public var action: String {
        switch self { case .trustSelected: "trust_selected"; case .revokeSelected: "revoke_selected"; case .setEnabled: "set_enabled" }
    }
    public var itemIDs: [String] {
        switch self { case .trustSelected(let ids), .revokeSelected(let ids): ids; case .setEnabled(let id, _): [id] }
    }
    public func payload(target: RelayHookReviewTarget) throws -> RelayJSON {
        var value = try target.wire.requiringObject()
        switch self {
        case .trustSelected(let ids): value["decision"] = .object(["action": .string("trust_selected"), "reviewItemIds": .array(ids.sorted().map(RelayJSON.string))])
        case .revokeSelected(let ids): value["reviewItemIds"] = .array(ids.sorted().map(RelayJSON.string))
        case .setEnabled(let id, let enabled): value["reviewItemId"] = .string(id); value["enabled"] = .bool(enabled)
        }; return .object(value)
    }
    var canonical: RelayJSON {
        var fields: [String: RelayJSON] = ["action": .string(action), "reviewItemIds": .array(itemIDs.sorted().map(RelayJSON.string))]
        if case .setEnabled(_, let enabled) = self { fields["enabled"] = .bool(enabled) }; return .object(fields)
    }
}

/// App-local consent binding; never forwarded as an official permission option.
public struct RelayHookReviewConfirmation: Codable, Sendable, Equatable {
    public let action: String
    public let fingerprint: String
    public let confirmedAt: Double
    fileprivate init(action: String, fingerprint: String, confirmedAt: Double) { self.action = action; self.fingerprint = fingerprint; self.confirmedAt = confirmedAt }
    public init(from decoder: any Decoder) throws {
        let value = try RelayJSON(from: decoder)
        _ = try HookWire.object(value, keys: ["action", "fingerprint", "confirmedAt"])
        let action = try HookWire.text(value, "action"), fingerprint = try HookWire.text(value, "fingerprint")
        try HookWire.digest(fingerprint)
        guard ["trust_selected", "revoke_selected", "set_enabled"].contains(action), let at = value["confirmedAt"].number, at.isFinite else { throw RelayFailure("hook_review_confirmation_required", "Use a dedicated, valid hook review confirmation.") }
        self.init(action: action, fingerprint: fingerprint, confirmedAt: at)
    }
}

public struct RelayHookReviewRequest: Codable, Sendable, Equatable, Identifiable {
    public let kind = "workspaceHookReview"
    public var id: String { interactionId }
    public let target: RelayHookReviewTarget
    public var sessionId: String { target.sessionId }
    public var taskId: String { target.taskId }
    public var runId: String { target.runId }
    public var remoteSessionId: String? { target.remoteSessionId }
    public var workspaceIdentity: String { target.workspaceIdentity }
    public var bundleDigest: String { target.bundleDigest }
    public var reviewFlowId: String { target.reviewFlowId }
    public var generation: Int { target.generation }
    public var interactionId: String { target.interactionId }
    public let workspaceLabel: String
    public let createdAt: Double
    public let deadlineAt: Double
    public let sourceFiles: [RelayHookReviewSourceFile]
    public let summary: RelayHookReviewSummary
    public let items: [RelayHookReviewItem]
    public let warningCode: String
    public let wire: RelayJSON
    /// Whole immutable displayed content, not only its host target tuple.
    public let fingerprint: String
    public init(wire: RelayJSON) throws {
        let required: Set<String> = ["kind", "reviewFlowId", "generation", "interactionId", "sessionId", "taskId", "runId", "workspaceIdentity", "workspaceLabel", "bundleDigest", "createdAt", "deadlineAt", "sourceFiles", "summary", "items", "warningCode"]
        let fields = try HookWire.object(wire, keys: required.union(["remoteSessionId"]), required: required)
        guard try wire.data().count <= 512 * 1024, wire["kind"].string == "workspaceHookReview", wire["warningCode"].string == "workspace_hooks_execute_code", let start = wire["createdAt"].number, let end = wire["deadlineAt"].number, start.isFinite, end.isFinite, abs(start) <= 9_007_199_254_740_991, abs(end) <= 9_007_199_254_740_991, end >= start, let source = wire["sourceFiles"].array, let values = wire["items"].array, source.count <= 256, values.count <= 1000 else { throw RelayFailure("hook_review_invalid", "Malformed or oversized workspace hook review.") }
        let keys: Set<String> = ["sessionId", "taskId", "runId", "remoteSessionId", "workspaceIdentity", "bundleDigest", "reviewFlowId", "generation", "interactionId"]
        target = try .init(wire: .object(fields.filter { keys.contains($0.key) }))
        workspaceLabel = try HookWire.text(wire, "workspaceLabel"); createdAt = start; deadlineAt = end
        sourceFiles = try source.map(RelayHookReviewSourceFile.init(wire:)); summary = try .init(wire: wire["summary"]); items = try values.map(RelayHookReviewItem.init(wire:))
        guard summary.hookCount == items.count, summary.eventCount == Set(items.map(\.event)).count, summary.pendingCount == items.filter(\.needsTrust).count, Set(items.map(\.id)).count == items.count else { throw RelayFailure("hook_review_invalid", "Hook summary or unique item identities do not match the request.") }
        warningCode = "workspace_hooks_execute_code"; self.wire = wire; fingerprint = try HookWire.hash(wire)
    }
    public init(from decoder: any Decoder) throws { try self.init(wire: RelayJSON(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
    public func validate(_ operation: RelayHookReviewOperation) throws {
        let ids = operation.itemIDs
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy({ id in items.contains { $0.id == id } }) else { throw RelayFailure("hook_review_selection_invalid", "Choose unique items from this exact workspace hook review.") }
        switch operation {
        case .trustSelected:
            guard ids.allSatisfy({ id in items.first { $0.id == id }?.needsTrust == true }) else { throw RelayFailure("hook_review_selection_invalid", "Only hooks awaiting trust can be selected for persistent trust.") }
        case .setEnabled(let id, _):
            guard items.first(where: { $0.id == id })?.editable == true else { throw RelayFailure("hook_review_item_read_only", "This hook's workspace configuration is not editable.") }
        case .revokeSelected: break
        }
    }
    public func operationFingerprint(_ operation: RelayHookReviewOperation) throws -> String {
        try validate(operation); return try HookWire.hash(.object(["request": wire, "operation": operation.canonical]))
    }
    /// Call only from the dedicated operation confirmation's affirmative action.
    public func confirmation(for operation: RelayHookReviewOperation, userConfirmed: Bool, now: Double = Date().timeIntervalSince1970 * 1000) throws -> RelayHookReviewConfirmation {
        guard userConfirmed else { throw RelayFailure("hook_review_confirmation_required", "This hook operation requires its own explicit confirmation.") }
        guard now.isFinite, now < deadlineAt else { throw RelayFailure("hook_review_expired", "The workspace hook review expired. Reload it before confirming.") }
        return try .init(action: operation.action, fingerprint: operationFingerprint(operation), confirmedAt: now)
    }
    public func validateConfirmation(_ confirmation: RelayHookReviewConfirmation, operation: RelayHookReviewOperation) throws {
        guard confirmation.action == operation.action, confirmation.fingerprint == (try operationFingerprint(operation)), confirmation.confirmedAt.isFinite, confirmation.confirmedAt < deadlineAt else { throw RelayFailure("hook_review_confirmation_required", "The dedicated confirmation does not match this exact review and selection.") }
    }
}

public struct RelayHookReviewAuthorization: Sendable, Equatable {
    public let request: RelayHookReviewRequest
    public let operation: RelayHookReviewOperation
    public let confirmation: RelayHookReviewConfirmation
    public init(request: RelayHookReviewRequest, operation: RelayHookReviewOperation, confirmation: RelayHookReviewConfirmation) throws {
        try request.validateConfirmation(confirmation, operation: operation)
        self.request = request; self.operation = operation; self.confirmation = confirmation
    }
}

public extension RelayPendingInteraction {
    func workspaceHookReview() throws -> RelayHookReviewRequest? {
        guard kind == "workspaceHookReview" else { return nil }
        let value = try RelayHookReviewRequest(wire: payload)
        guard value.interactionId == id, raw.object?["autoResolution"] == nil else { throw RelayFailure("hook_review_invalid", "Hook review identity mismatch or forbidden automatic resolution.") }; return value
    }
}
