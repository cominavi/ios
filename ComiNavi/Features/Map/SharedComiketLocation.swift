import Foundation
import Observation
import UIKit

struct SharedComiketLocation: Equatable, Sendable {
  static let scheme = "cominavi"
  static let host = "p"
  static let legacyHost = "place"
  static let version = 1

  let eventNumber: Int
  let sceneID: CatalogMapScene.ID
  let tableID: CatalogMapTable.ID
  let subspace: Int?

  init?(
    eventNumber: Int,
    sceneID: CatalogMapScene.ID,
    tableID: CatalogMapTable.ID,
    subspace: Int?
  ) {
    guard eventNumber > 0,
      (1...7).contains(sceneID.day),
      sceneID.mapID > 0,
      tableID.blockID > 0,
      tableID.spaceNumber > 0,
      subspace == nil || subspace == 0 || subspace == 1
    else {
      return nil
    }

    self.eventNumber = eventNumber
    self.sceneID = sceneID
    self.tableID = tableID
    self.subspace = subspace
  }

  init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme else {
      return nil
    }

    if url.host?.lowercased() == Self.host {
      self.init(binaryURL: url)
      return
    }

    guard url.host?.lowercased() == Self.legacyHost,
      url.path.isEmpty || url.path == "/",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = components.queryItems
    else {
      return nil
    }

    let values = Dictionary(grouping: items, by: \.name)
    let requiredNames = ["v", "event", "day", "map", "block_id", "space"]
    guard requiredNames.allSatisfy({ values[$0]?.count == 1 }),
      (values["side"]?.count ?? 0) <= 1,
      let version = Self.integer("v", in: values),
      version == Self.version,
      let eventNumber = Self.integer("event", in: values),
      let day = Self.integer("day", in: values),
      let mapID = Self.integer("map", in: values),
      let blockID = Self.integer("block_id", in: values),
      let spaceNumber = Self.integer("space", in: values)
    else {
      return nil
    }

    let subspace: Int?
    switch values["side"]?.first?.value?.lowercased() {
    case nil:
      subspace = nil
    case "a":
      subspace = 0
    case "b":
      subspace = 1
    default:
      return nil
    }

    self.init(
      eventNumber: eventNumber,
      sceneID: .init(day: day, mapID: mapID),
      tableID: .init(blockID: blockID, spaceNumber: spaceNumber),
      subspace: subspace
    )
  }

  init?(location: LocatedMapUser, eventNumber: Int) {
    self.init(
      eventNumber: eventNumber,
      sceneID: location.sceneID,
      tableID: location.tableID,
      subspace: location.subspace
    )
  }

  var url: URL {
    var payload = Data([UInt8(Self.version)])
    for value in [
      eventNumber,
      sceneID.day,
      sceneID.mapID,
      tableID.blockID,
      tableID.spaceNumber,
      subspace.map { $0 + 1 } ?? 0,
    ] {
      Self.appendUnsignedLEB128(value, to: &payload)
    }
    let encoded = payload.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    guard let url = URL(string: "\(Self.scheme)://\(Self.host)/\(encoded)") else {
      preconditionFailure("Fixed shared-location payload must form a URL")
    }
    return url
  }

  func clipboardText(locationText: String) -> String {
    "\(locationText)\n\(url.absoluteString)"
  }

  static func first(in text: String) -> Self? {
    let candidates = text.split(whereSeparator: \.isWhitespace)
    for candidate in candidates {
      let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "<>[](){}\"'.,"))
      if let url = URL(string: trimmed), let location = Self(url: url) {
        return location
      }
    }
    return nil
  }

  static func isLocationURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == scheme else { return false }
    let host = url.host?.lowercased()
    return host == Self.host || host == legacyHost
  }

  private init?(binaryURL url: URL) {
    guard url.query == nil,
      url.fragment == nil,
      !url.path.isEmpty,
      url.path.split(separator: "/").count == 1
    else {
      return nil
    }

    let encoded = String(url.path.dropFirst())
    guard !encoded.isEmpty,
      encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      return nil
    }
    let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    let base64 = encoded
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      + padding
    guard let payload = Data(base64Encoded: base64),
      payload.first == UInt8(Self.version)
    else {
      return nil
    }

    var offset = 1
    var values: [Int] = []
    for _ in 0..<6 {
      guard let value = Self.readUnsignedLEB128(from: payload, offset: &offset) else {
        return nil
      }
      values.append(value)
    }
    guard offset == payload.count else { return nil }

    let subspace: Int?
    switch values[5] {
    case 0: subspace = nil
    case 1: subspace = 0
    case 2: subspace = 1
    default: return nil
    }
    self.init(
      eventNumber: values[0],
      sceneID: .init(day: values[1], mapID: values[2]),
      tableID: .init(blockID: values[3], spaceNumber: values[4]),
      subspace: subspace
    )

    // Reject alternate encodings so the compact URL has one stable form.
    guard self.url.absoluteString == url.absoluteString else { return nil }
  }

  private static func appendUnsignedLEB128(_ value: Int, to data: inout Data) {
    precondition(value >= 0)
    var remainder = UInt(value)
    repeat {
      var byte = UInt8(remainder & 0x7f)
      remainder >>= 7
      if remainder != 0 { byte |= 0x80 }
      data.append(byte)
    } while remainder != 0
  }

  private static func readUnsignedLEB128(from data: Data, offset: inout Int) -> Int? {
    var value: UInt = 0
    var shift = 0
    var byteCount = 0
    while offset < data.count, byteCount < 10 {
      let byte = data[offset]
      offset += 1
      byteCount += 1
      let fragment = UInt(byte & 0x7f)
      guard shift < UInt.bitWidth,
        fragment <= (UInt.max >> shift)
      else {
        return nil
      }
      value |= fragment << shift
      if byte & 0x80 == 0 {
        guard byteCount == 1 || fragment != 0,
          value <= UInt(Int.max)
        else {
          return nil
        }
        return Int(value)
      }
      shift += 7
    }
    return nil
  }

  private static func integer(
    _ name: String,
    in values: [String: [URLQueryItem]]
  ) -> Int? {
    guard let value = values[name]?.first?.value,
      !value.isEmpty,
      value.allSatisfy(\.isNumber)
    else {
      return nil
    }
    return Int(value)
  }
}

@MainActor
@Observable
final class SharedLocationInbox {
  struct Request: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
      case url
      case clipboard
    }

    let id: UUID
    let location: SharedComiketLocation
    let source: Source
  }

  enum Issue: Equatable, Sendable {
    case invalidLink
    case clipboardDoesNotContainLocation
    case unsupportedEvent(Int)
    case locationUnavailable
  }

  private(set) var pending: Request?
  var issue: Issue?

  @discardableResult
  func receive(url: URL, source: Request.Source = .url) -> Bool {
    guard SharedComiketLocation.isLocationURL(url) else { return false }
    guard let location = SharedComiketLocation(url: url) else {
      issue = .invalidLink
      return true
    }
    pending = Request(id: UUID(), location: location, source: source)
    issue = nil
    return true
  }

  @discardableResult
  func receiveClipboardText(_ text: String, reportFailure: Bool = true) -> Bool {
    guard let location = SharedComiketLocation.first(in: text) else {
      if reportFailure {
        issue = .clipboardDoesNotContainLocation
      }
      return false
    }
    pending = Request(id: UUID(), location: location, source: .clipboard)
    issue = nil
    return true
  }

  func acknowledge(_ requestID: UUID) {
    guard pending?.id == requestID else { return }
    pending = nil
  }

  func fail(_ requestID: UUID, with issue: Issue) {
    guard pending?.id == requestID else { return }
    pending = nil
    self.issue = issue
  }
}

@MainActor
protocol SharedLocationPasteboard: AnyObject {
  var changeCount: Int { get }
  var hasStrings: Bool { get }
  var string: String? { get }
}

extension UIPasteboard: SharedLocationPasteboard {}

@MainActor
final class SharedLocationClipboardImporter {
  static let enabledDefaultsKey = "SharedLocation.autoClipboard.enabled"
  private static let changeCountDefaultsKey = "SharedLocation.autoClipboard.lastChangeCount"

  private let pasteboard: any SharedLocationPasteboard
  private let defaults: UserDefaults

  init(
    pasteboard: any SharedLocationPasteboard = UIPasteboard.general,
    defaults: UserDefaults = .standard
  ) {
    self.pasteboard = pasteboard
    self.defaults = defaults
  }

  @discardableResult
  func importIfChanged(into inbox: SharedLocationInbox) -> Bool {
    let changeCount = pasteboard.changeCount
    guard defaults.object(forKey: Self.changeCountDefaultsKey) as? Int != changeCount else {
      return false
    }

    // Record the change before reading so a non-location value never causes
    // repeated system paste prompts on every foreground transition.
    defaults.set(changeCount, forKey: Self.changeCountDefaultsKey)
    guard pasteboard.hasStrings, let text = pasteboard.string else { return false }
    return inbox.receiveClipboardText(text, reportFailure: false)
  }
}
