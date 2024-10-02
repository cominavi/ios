//
//  UserDefaultBacked.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Foundation

@propertyWrapper
struct UserDefaultBacked<Value: Codable> {
    private let key: String
    private let defaultValue: Value
    private let userDefaults: UserDefaults

    init(key: String, defaultValue: Value, userDefaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.userDefaults = userDefaults
    }

    var wrappedValue: Value {
        get {
            guard let data = userDefaults.data(forKey: key) else {
                return defaultValue
            }
            do {
                let value = try JSONDecoder().decode(Value.self, from: data)
                return value
            } catch {
                print("Failed to decode \(Value.self) from UserDefaults for key \(key): \(error)")
                return defaultValue
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                userDefaults.set(data, forKey: key)
            } catch {
                print("Failed to encode \(Value.self) to UserDefaults for key \(key): \(error)")
            }
        }
    }
}
