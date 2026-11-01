import Foundation
import XCTest
@testable import WinDACore

private let validSHA = String(repeating: "a", count: 64)

private func recipeJSON(actions: String = "[]", rating: String = "gold") -> Data {
    Data("""
    {"schemaVersion":1,"id":"example-game","name":"Example Game","category":"game",
     "match":{"exeNames":["game.exe"],"sha256":[]},
     "engine":{"graphics":"dxvk","package":"wine-gcenx-10.0"},
     "actions":\(actions),"rating":"\(rating)"}
    """.utf8)
}

final class RecipeTests: XCTestCase {
    func testDecodesValidRecipe() throws {
        let r = try Recipe.decode(from: recipeJSON(actions: """
        [{"type":"setEnv","key":"DXVK_ASYNC","value":"1"},{"type":"winetricks","verb":"vcrun2022"}]
        """))
        XCTAssertEqual(r.actions.count, 2)
        XCTAssertTrue(RecipeValidator.validate(r).isEmpty)
    }

    func testRejectsUnknownActionType() {
        XCTAssertThrowsError(try Recipe.decode(
            from: recipeJSON(actions: #"[{"type":"shell","command":"rm -rf ~"}]"#)))
    }

    func testRejectsInsecureDownloads() throws {
        let r = try Recipe.decode(from: recipeJSON(actions: """
        [{"type":"download","url":"http://example.com/a.dll","sha256":"abc","destination":"../../etc/x"}]
        """))
        XCTAssertEqual(RecipeValidator.validate(r).count, 3)
    }

    func testAcceptsHashedHTTPSDownload() throws {
        let r = try Recipe.decode(from: recipeJSON(actions: """
        [{"type":"download","url":"https://example.com/a.dll","sha256":"\(validSHA)","destination":"drive_c/a.dll"}]
        """))
        XCTAssertTrue(RecipeValidator.validate(r).isEmpty)
    }

    func testRejectsReservedEnvAndBadVerb() throws {
        let r = try Recipe.decode(from: recipeJSON(actions: """
        [{"type":"setEnv","key":"DYLD_INSERT_LIBRARIES","value":"/x"},{"type":"winetricks","verb":"x; rm"}]
        """))
        XCTAssertEqual(RecipeValidator.validate(r).count, 2)
    }

    func testAntiCheatRecipesCarryNoActions() throws {
        let r = try Recipe.decode(from: recipeJSON(
            actions: #"[{"type":"winetricks","verb":"vcrun2022"}]"#, rating: "incompatible-anticheat"))
        XCTAssertFalse(RecipeValidator.validate(r).isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        let r = try Recipe.decode(from: recipeJSON(actions: #"[{"type":"winetricks","verb":"dotnet48"}]"#))
        let again = try Recipe.decode(from: JSONEncoder().encode(r))
        XCTAssertEqual(again, r)
    }
}
