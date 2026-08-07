import XCTest
@testable import Sub2APIStatusCore

final class QuotaResetDurationFormatterTests: XCTestCase {
    func testAlwaysShowsDaysHoursAndMinutes() {
        XCTAssertEqual(
            StatusFormatters.quotaResetDuration(seconds: 17_940, language: .zhHans),
            "0天4小时59分钟"
        )
        XCTAssertEqual(
            StatusFormatters.quotaResetDuration(seconds: 604_740, language: .zhHans),
            "6天23小时59分钟"
        )
        XCTAssertEqual(
            StatusFormatters.quotaResetDuration(seconds: 90_061, language: .en),
            "1d 1h 1m"
        )
        XCTAssertEqual(
            StatusFormatters.quotaResetDuration(seconds: -1, language: .zhHans),
            "0天0小时0分钟"
        )
    }
}
