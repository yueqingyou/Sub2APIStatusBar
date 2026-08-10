import Sub2APIStatusCore
import XCTest

final class MenuBarStatusDisplayModeTests: XCTestCase {
    func testRequiresAuthenticationBeforeMetrics() {
        let signedOut = AppConfig(
            baseURL: "https://tokenrouter.example.com",
            authToken: "",
            showsMenuBarText: true
        )
        let iconOnly = AppConfig(
            baseURL: "https://tokenrouter.example.com",
            authToken: "access-token",
            showsMenuBarText: false
        )
        let metrics = AppConfig(
            baseURL: "https://tokenrouter.example.com",
            authToken: "access-token",
            showsMenuBarText: true
        )
        let whitespaceToken = AppConfig(
            baseURL: "https://tokenrouter.example.com",
            authToken: " \n\t",
            showsMenuBarText: true
        )

        XCTAssertEqual(signedOut.menuBarStatusDisplayMode, .signedOut)
        XCTAssertEqual(whitespaceToken.menuBarStatusDisplayMode, .signedOut)
        XCTAssertEqual(iconOnly.menuBarStatusDisplayMode, .iconOnly)
        XCTAssertEqual(metrics.menuBarStatusDisplayMode, .metrics)
    }
}
