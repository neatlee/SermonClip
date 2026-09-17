import XCTest
@testable import SermonCut

final class H264BumperRecipeTests: XCTestCase {
    private func configuration(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0 + 1]), radix: 16)!
        })
    }

    func testOptionalDefaultHighExtensionDoesNotChangeDecoderParameters() {
        let source = configuration("01640028ffe1001e67640028acd100780227e5c05a808080a0000003002000000781e306224001000468eb8f2c")
        let extended = source + Data([0xfd, 0xf8, 0xf8, 0])
        XCTAssertEqual(H264Configuration.compatibilityKey(source), H264Configuration.compatibilityKey(extended))
        var changedSPS = extended
        changedSPS[12] ^= 1
        XCTAssertNotEqual(H264Configuration.compatibilityKey(source), H264Configuration.compatibilityKey(changedSPS))
        XCTAssertNotEqual(H264Configuration.compatibilityKey(source), H264Configuration.compatibilityKey(source + Data([0xfd, 0xf9, 0xf8, 0])))
    }

    func testTruncatedConfigurationsAreNotRewritten() {
        for data in [Data(), Data([1, 100]), Data([1, 100, 0, 40, 255, 225, 255, 255])] {
            XCTAssertEqual(H264Configuration.compatibilityKey(data), data)
        }
    }

    func testSourceDerivedRecipeAndMissingHeaderFallback() throws {
        let fields = ["num_units_in_tick": 1, "time_scale": 60,
                      "num_ref_idx_l0_default_active_minus1": 2, "max_num_reorder_frames": 1,
                      "log2_max_pic_order_cnt_lsb_minus4": 1, "pic_init_qp_minus26": 0,
                      "chroma_qp_index_offset": 0, "frame_mbs_only_flag": 1,
                      "transform_8x8_mode_flag": 1, "weighted_pred_flag": 0]
        let trace = fields.map { "[trace_headers @ 0x123] 42  \($0.key)  010 = \($0.value)" }.joined(separator: "\n")
        let args = try XCTUnwrap(H264BumperRecipe(trace: trace).arguments)
        XCTAssertTrue(args.contains("2:60"))
        XCTAssertTrue(args.contains("-b:v"))
        XCTAssertFalse(args.contains("-crf"))
        let params = try XCTUnwrap(args.first { $0.hasPrefix("ref=") })
        XCTAssertTrue(params.contains("ref=3:bframes=3:b-pyramid=none"))
        XCTAssertTrue(params.contains("weightp=0"))
        XCTAssertNil(try H264BumperRecipe(trace: "unrecognized trace").arguments)
    }
}
