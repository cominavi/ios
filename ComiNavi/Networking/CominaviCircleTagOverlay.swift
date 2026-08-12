import CryptoKit
import Foundation

enum CominaviCircleTagKind: String, Codable, CaseIterable, Sendable {
    case work
    case character
    case content
    case theme
    case format
    case activity
}

struct CominaviCircleTagTerm: Codable, Equatable, Hashable, Sendable {
    let id: String
    let label: String
    let kind: CominaviCircleTagKind
}

struct CominaviCircleTagAssignment: Codable, Equatable, Hashable, Sendable {
    let wcID: Int
    let tagIDs: [String]
}

struct CominaviCircleTagOverlay: Codable, Equatable, Sendable {
    static let absentRevision = "none"

    static func isValidRevisionToken(_ value: String) -> Bool {
        value == absentRevision || isDigest(value)
    }

    let schemaVersion: Int
    let revision: String
    let catalogPayloadSHA256: String
    let taxonomyRevision: String
    let matchingPolicyRevision: String
    let evaluatedCircleCount: Int
    let taggedCircleCount: Int
    let terms: [CominaviCircleTagTerm]
    let circles: [CominaviCircleTagAssignment]

    func validate() throws {
        guard schemaVersion == 1,
              Self.isDigest(revision),
              Self.isDigest(catalogPayloadSHA256),
              Self.isConstrainedIdentifier(taxonomyRevision),
              Self.isConstrainedIdentifier(matchingPolicyRevision),
              (0...1_000_000).contains(evaluatedCircleCount),
              (0...100_000).contains(taggedCircleCount),
              terms.count <= 10_000,
              circles.count <= 100_000,
              taggedCircleCount == circles.count,
              evaluatedCircleCount >= taggedCircleCount
        else {
            throw CominaviServiceError.invalidResponse
        }

        var termIDs: Set<String> = []
        var previousTermID: String?
        for term in terms {
            guard Self.isConstrainedIdentifier(term.id),
                  !term.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  term.label.unicodeScalars.count <= 200,
                  term.label.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  previousTermID.map({ $0 < term.id }) ?? true,
                  termIDs.insert(term.id).inserted
            else {
                throw CominaviServiceError.invalidResponse
            }
            previousTermID = term.id
        }

        var referencedTermIDs: Set<String> = []
        var previousWCID: Int?
        for circle in circles {
            guard (1...9_007_199_254_740_991).contains(circle.wcID),
                  previousWCID.map({ $0 < circle.wcID }) ?? true,
                  !circle.tagIDs.isEmpty,
                  circle.tagIDs.count <= 512
            else {
                throw CominaviServiceError.invalidResponse
            }

            var previousTagID: String?
            for tagID in circle.tagIDs {
                guard Self.isConstrainedIdentifier(tagID),
                      termIDs.contains(tagID),
                      previousTagID.map({ $0 < tagID }) ?? true
                else {
                    throw CominaviServiceError.invalidResponse
                }
                previousTagID = tagID
                referencedTermIDs.insert(tagID)
            }
            previousWCID = circle.wcID
        }

        guard referencedTermIDs == termIDs,
              semanticRevision == revision
        else {
            throw CominaviServiceError.invalidResponse
        }
    }

    var semanticRevision: String {
        SHA256.hash(data: canonicalSemanticData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var canonicalSemanticData: Data {
        var json = "{\"schemaVersion\":1"
        json += ",\"catalogPayloadSHA256\":\(Self.jsonString(catalogPayloadSHA256))"
        json += ",\"taxonomyRevision\":\(Self.jsonString(taxonomyRevision))"
        json += ",\"matchingPolicyRevision\":\(Self.jsonString(matchingPolicyRevision))"
        json += ",\"evaluatedCircleCount\":\(evaluatedCircleCount)"
        json += ",\"taggedCircleCount\":\(taggedCircleCount)"
        json += ",\"terms\":["
        json += terms.map { term in
            "{\"id\":\(Self.jsonString(term.id)),"
                + "\"label\":\(Self.jsonString(term.label)),"
                + "\"kind\":\(Self.jsonString(term.kind.rawValue))}"
        }
        .joined(separator: ",")
        json += "],\"circles\":["
        json += circles.map { circle in
            let tagIDs = circle.tagIDs.map(Self.jsonString).joined(separator: ",")
            return "{\"wcID\":\(circle.wcID),\"tagIDs\":[\(tagIDs)]}"
        }
        .joined(separator: ",")
        json += "]}"
        return Data(json.utf8)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isConstrainedIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              isASCIILetterOrDigit(bytes[0])
        else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIILetterOrDigit(byte) || [46, 95, 58, 45].contains(byte)
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
    }

    /// Matches `JSON.stringify` for valid Swift strings without escaping `/`.
    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x00...0x1f:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
