//
//  AutoPersistable.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Foundation

@propertyWrapper
public struct UserDefaultsBacked<Value> where Value: Codable {
    public let key: String
    public let defaultValue: Value
    public let userDefaults: UserDefaults

    public init(_ key: String, defaultValue: Value, userDefaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.userDefaults = userDefaults
    }

    public var wrappedValue: Value {
        get {
            value(for: key)
        }
        set {
            set(newValue, for: key)
        }
    }

    // MARK: Private

    private func value(for key: String) -> Value {
        if isCodableType(Value.self) {
            guard let value = userDefaults.value(forKey: key) as? Value else {
                return defaultValue
            }
            return value
        }
        guard let data = userDefaults.data(forKey: key) else {
            return defaultValue
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            return defaultValue
        }
    }

    private func isOptional(_ type: Any.Type) -> Bool {
        let typeName = String(describing: type)
        return typeName.hasPrefix("Optional<")
    }

    private func set(_ value: Value, for key: String) {
        if let optional = value as? AnyOptional, optional.isNil {
            userDefaults.removeObject(forKey: key)
        } else if isCodableType(Value.self) {
            userDefaults.set(value, forKey: key)
        } else {
            do {
                let encoded = try JSONEncoder().encode(value)
                userDefaults.set(encoded, forKey: key)
            } catch {
                userDefaults.removeObject(forKey: key)
            }
        }
    }

    private func isCodableType<V>(_ type: V.Type) -> Bool {
        switch type {
        case is String.Type,
             is Optional<String>.Type,

             is Bool.Type,
             is Bool?.Type,

             is Int.Type,
             is Int?.Type,

             is Float.Type,
             is Float?.Type,

             is Double.Type,
             is Double?.Type,

             is Date.Type,
             is Date?.Type:

            return true
        default:
            return false
        }
    }
}

public extension UserDefaultsBacked where Value: ExpressibleByNilLiteral {
    init(_ key: String, userDefaults: UserDefaults = .standard) {
        self.init(key, defaultValue: nil, userDefaults: userDefaults)
    }
}

private protocol AnyOptional {
    var isNil: Bool { get }
}

extension Optional: AnyOptional {
    var isNil: Bool { self == nil }
}

protocol OptionalProtocol {
    func wrappedType() -> Any.Type
}

extension Optional: OptionalProtocol {
    func wrappedType() -> Any.Type {
        return Wrapped.self
    }
}
