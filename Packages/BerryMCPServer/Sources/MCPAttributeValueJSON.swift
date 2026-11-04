import BerryDriverKit
import Foundation
import MCP

/// DynamoDB items as MCP values in the attribute-value shape the service
/// measured them in (`DynamoDBAttributeValue.encode(to:)`): one tagged entry
/// per value, numbers as their decimal text and binary as base64.
///
/// Built case by case rather than through `MCPStructuredEncoding`: its
/// snake_case key strategy rewrites the tags, which are coding keys, so
/// `BOOL` became `b_ool` and `SS` became `s_s` when tried, while attribute
/// names, being dictionary keys, were left alone. Numbers stay text and
/// never pass through `Double`, which would round a 38-digit DynamoDB number.
enum MCPAttributeValueJSON {
    static func value(_ item: [String: DynamoDBAttributeValue]) -> Value {
        .object(item.mapValues(value(of:)))
    }

    private static func value(of attribute: DynamoDBAttributeValue) -> Value {
        switch attribute {
        case let .string(text): ["S": .string(text)]
        case let .number(text): ["N": .string(text)]
        case let .binary(bytes): ["B": .string(bytes.base64EncodedString())]
        case let .bool(flag): ["BOOL": .bool(flag)]
        case .null: ["NULL": .bool(true)]
        case let .list(items): ["L": .array(items.map(value(of:)))]
        case let .map(members): ["M": .object(members.mapValues(value(of:)))]
        case let .stringSet(texts): ["SS": .array(texts.map { .string($0) })]
        case let .numberSet(texts): ["NS": .array(texts.map { .string($0) })]
        case let .binarySet(values): ["BS": .array(values.map { .string($0.base64EncodedString()) })]
        }
    }
}
