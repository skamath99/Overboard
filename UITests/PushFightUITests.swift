import XCTest

/// Smoke test: plays the opening of a real pass-and-play game end to end —
/// full placement for both players, a move, an undo, and a push.
final class PushFightUITests: XCTestCase {
    func testPassAndPlayPlacementMoveAndPush() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Pass & Play"].firstMatch.tap()

        let status = app.staticTexts["game-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        // Ivory places 3 squares then 2 rounds (tray auto-switches kinds).
        for tile in ["d2", "d3", "d1", "c2", "c3"] {
            tapTile(app, tile)
        }
        XCTAssertTrue(status.label.contains("Walnut"), "Walnut should be placing, got: \(status.label)")
        // The tray must reset for the second placer (3 squares, 2 rounds).
        XCTAssertTrue(status.label.contains("3 squares"), "Walnut's tray should be full, got: \(status.label)")

        // Walnut places 3 squares then 2 rounds.
        for tile in ["e2", "e3", "e1", "f2", "f3"] {
            tapTile(app, tile)
        }
        XCTAssertTrue(status.label.contains("Ivory"), "Ivory should start, got: \(status.label)")
        XCTAssertTrue(status.label.contains("2 moves"), "Expected fresh turn, got: \(status.label)")

        // Ivory moves the round at c2 to b2.
        tapTile(app, "c2")
        tapTile(app, "b2")
        XCTAssertTrue(status.label.contains("1 move"), "Expected 1 move left, got: \(status.label)")

        // Undo restores the move.
        app.buttons["Undo move"].firstMatch.tap()
        XCTAssertTrue(status.label.contains("2 moves"), "Undo should restore moves, got: \(status.label)")

        // Ivory pushes right with the square at d2 (into Walnut's e2).
        tapTile(app, "d2")
        saveScreenshot("game-selected")
        tapTile(app, "e2")
        XCTAssertTrue(status.label.contains("Walnut"), "Turn should pass to Walnut, got: \(status.label)")
        saveScreenshot("game-after-push")
    }

    /// Writes a screenshot to the host filesystem (simulator only) so design
    /// can be reviewed without driving the app manually.
    private func saveScreenshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }

    private func tapTile(_ app: XCUIApplication, _ notation: String) {
        let tile = app.buttons["tile-\(notation)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 3), "tile \(notation) not found")
        tile.tap()
    }
}
