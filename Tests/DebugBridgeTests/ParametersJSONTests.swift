import DebugBridge
import Foundation
import XCTest

final class ParametersJSONTests: XCTestCase {
    func testEncodedJSONPreservesArbitraryKeysAndNestedValues() throws {
        let original: [String: Any] = [
            "enabled": true,
            "count": 17,
            "fraction": 2.75,
            "items": ["first", "second"],
            "null": NSNull(),
            "arbitraryFutureParameter": [
                "nested": [["name": "Caf\u{00e9}", "enabled": false]],
                "empty": [String](),
            ],
        ]

        let data = try Parameters(original).encodedJSON()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: decoded))
        XCTAssertEqual(decoded["enabled"] as? Bool, true)
        XCTAssertEqual(decoded["count"] as? Int, 17)
        XCTAssertEqual(decoded["fraction"] as? Double, 2.75)
        XCTAssertEqual(decoded["items"] as? [String], ["first", "second"])
        XCTAssertTrue(decoded["null"] is NSNull)
    }

    func testEncodedJSONDetachesMutableNestedValues() throws {
        let nested = NSMutableDictionary(dictionary: ["title": "Before"])
        let parameters = Parameters(["nested": nested])

        let data = try parameters.encodedJSON()
        nested["title"] = "After"
        nested["addedLater"] = true

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedNested = try XCTUnwrap(decoded["nested"] as? [String: Any])
        XCTAssertEqual(decodedNested["title"] as? String, "Before")
        XCTAssertNil(decodedNested["addedLater"])
    }

    func testEmptyParametersEncodeAsJSONObject() throws {
        let data = try Parameters().encodedJSON()
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(decoded.isEmpty)
    }

    func testNonJSONValueThrowsInsteadOfDroppingParameter() {
        let parameters = Parameters(["unsupported": Date(timeIntervalSince1970: 0)])

        XCTAssertThrowsError(try parameters.encodedJSON())
    }
}
