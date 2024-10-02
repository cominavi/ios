//
//  DecodableDefault.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Foundation
import UIKit

// https://www.swiftbysundell.com/tips/default-decoding-values/
protocol DecodableDefaultSource {
    associatedtype Value: Decodable
    static var defaultValue: Value { get }
}

public enum DecodableDefault {}

extension DecodableDefault {
    @propertyWrapper struct Wrapper<Source: DecodableDefaultSource> {
        typealias Value = Source.Value
        var wrappedValue = Source.defaultValue
    }
}

extension DecodableDefault.Wrapper: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decode(Value.self)
    }
}

extension KeyedDecodingContainer {
    func decode<T>(
        _ type: DecodableDefault.Wrapper<T>.Type,
        forKey key: Key
    ) throws -> DecodableDefault.Wrapper<T> {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}

extension DecodableDefault {
    typealias Source = DecodableDefaultSource
    typealias List = Decodable & ExpressibleByArrayLiteral
    typealias Map = Decodable & ExpressibleByDictionaryLiteral

    enum Sources {
        enum True: Source {
            static var defaultValue: Bool { true }
        }

        enum False: Source {
            static var defaultValue: Bool { false }
        }

        enum EmptyString: Source {
            static var defaultValue: String { "" }
        }

        enum Now: Source {
            static var defaultValue: Date { Date() }
        }

        enum EmptyList<T: List>: Source {
            static var defaultValue: T { [] }
        }

        enum EmptyMap<T: Map>: Source {
            static var defaultValue: T { [:] }
        }

        enum IntZero: Source {
            static var defaultValue: Swift.Int { 0 }
        }

        enum IntNegativeOne: Source {
            static var defaultValue: Swift.Int { -1 }
        }

        enum Int64Zero: Source {
            static var defaultValue: Swift.Int64 { 0 }
        }

        enum DoubleZero: Source {
            static var defaultValue: Swift.Double { 0.00 }
        }

        enum CGFloatZero: Source {
            static var defaultValue: UIKit.CGFloat { 0.00 }
        }
    }
}

extension DecodableDefault {
    typealias Now = Wrapper<Sources.Now>
    typealias True = Wrapper<Sources.True>
    typealias False = Wrapper<Sources.False>
    typealias EmptyString = Wrapper<Sources.EmptyString>
    typealias EmptyList<T: List> = Wrapper<Sources.EmptyList<T>>
    typealias EmptyMap<T: Map> = Wrapper<Sources.EmptyMap<T>>
    typealias IntZero = Wrapper<Sources.IntZero>
    /// Sometimes `IntZero` (`0`) *does* have semantic meaning in places like enums. Therefore a different default value is needed for such cases.
    typealias IntNegativeOne = Wrapper<Sources.IntNegativeOne>
    typealias Int64Zero = Wrapper<Sources.Int64Zero>
    typealias DoubleZero = Wrapper<Sources.DoubleZero>
    typealias CGFloatZero = Wrapper<Sources.CGFloatZero>
}

extension DecodableDefault.Wrapper: Equatable where Value: Equatable {}
extension DecodableDefault.Wrapper: Hashable where Value: Hashable {}

extension DecodableDefault.Wrapper: Encodable where Value: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

protocol DefaultValue {
    associatedtype Value: Decodable
    static var defaultValue: Value { get }
}

@propertyWrapper
struct Default<T: DefaultValue> {
    var wrappedValue: T.Value
}

extension Default: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(T.Value.self)) ?? T.defaultValue
    }
}

extension KeyedDecodingContainer {
    func decode<T>(
        _ type: Default<T>.Type,
        forKey key: Key
    ) throws -> Default<T> where T: DefaultValue {
        try decodeIfPresent(type, forKey: key) ?? Default(wrappedValue: T.defaultValue)
    }
}
