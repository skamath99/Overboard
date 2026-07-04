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

    /// Marketing screenshots: the home page and a lively mid-game position
    /// with both anchors having moved and no selection highlights.
    func testMarketingScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        let passAndPlay = app.buttons["Pass & Play"].firstMatch
        XCTAssertTrue(passAndPlay.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        saveScreenshot("shot-home")

        passAndPlay.tap()
        let status = app.staticTexts["game-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        for tile in ["d2", "d3", "d1", "c2", "c3", "e2", "e3", "e1", "f2", "f3"] {
            tapTile(app, tile)
        }
        // Ivory shoves the centre line; Walnut answers with a flank push.
        tapTile(app, "d2")
        tapTile(app, "e2")
        tapTile(app, "f2")
        tapTile(app, "f3")
        XCTAssertTrue(status.label.contains("Ivory"), "Should be Ivory's turn, got: \(status.label)")
        Thread.sleep(forTimeInterval: 1.0)
        saveScreenshot("shot-game")
    }

    /// Regression: finished games must open from Match History instead of
    /// bouncing straight back to the list.
    func testHistoryReplayOpens() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Pass & Play"].firstMatch.tap()
        let status = app.staticTexts["game-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        // Fast win: Ivory pushes its own round off the open left edge.
        for tile in ["b2", "c1", "d1", "a2", "a3", "e2", "f2", "g2", "f3", "g3"] {
            tapTile(app, tile)
        }
        tapTile(app, "b2")
        tapTile(app, "a2")
        XCTAssertTrue(status.label.contains("wins"), "Game should be over, got: \(status.label)")

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Match History"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Match History"].firstMatch.tap()

        let row = app.staticTexts["Walnut won"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "History row should exist")
        row.tap()

        // The replay screen has the scrubber; it must still be there after
        // the push animation settles (no bounce-back).
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Replay scrubber should appear")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(slider.exists, "Replay screen must not pop back to the list")
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
