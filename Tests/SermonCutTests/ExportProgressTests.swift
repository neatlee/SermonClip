import XCTest
@testable import SermonCut

final class ExportProgressTests: XCTestCase {
    func testReportedMediaTimeProducesBoundedProgress() {
        XCTAssertEqual(ExportProgress.fraction(line: "out_time_us=5000000", duration: 20), 0.25)
        XCTAssertEqual(ExportProgress.fraction(line: "out_time_us=-200", duration: 20), 0)
        XCTAssertEqual(ExportProgress.fraction(line: "out_time_us=22000000", duration: 20), 0.99)
        XCTAssertNil(ExportProgress.fraction(line: "out_time_us=N/A", duration: 20))
        XCTAssertNil(ExportProgress.fraction(line: "out_time_us=500", duration: 0))
        XCTAssertNil(ExportProgress.fraction(line: "unrelated diagnostic", duration: 20))
    }
}
