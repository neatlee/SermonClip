import Foundation

/// Reads only the first packet/header, never scans or transcodes the sermon.
struct H264BumperRecipe {
    let fields: [String: Int]

    init(trace: String) throws {
        let regex = try NSRegularExpression(pattern: #"\]\s+\d+\s+([a-zA-Z0-9_]+)\s+[01]+\s+=\s+(-?\d+)"#)
        var values: [String: Int] = [:]
        for match in regex.matches(in: trace, range: NSRange(trace.startIndex..., in: trace)) {
            guard let nameRange = Range(match.range(at: 1), in: trace),
                  let valueRange = Range(match.range(at: 2), in: trace),
                  let value = Int(trace[valueRange]) else { continue }
            let name = String(trace[nameRange])
            if values[name] == nil { values[name] = value }
        }
        fields = values
    }

    static func read(source: URL) async throws -> H264BumperRecipe {
        let trace = try await FFmpegRunner.run([
            "-v", "info", "-i", source.path, "-map", "0:v:0", "-frames:v", "1",
            "-c:v", "copy", "-bsf:v", "trace_headers", "-an", "-f", "null", "-"
        ], background: true)
        return try H264BumperRecipe(trace: trace)
    }

    var arguments: [String]? {
        guard let units = fields["num_units_in_tick"], units > 0, units < 1_000_000_000,
              let ticks = fields["time_scale"], ticks > 0,
              let refs = fields["num_ref_idx_l0_default_active_minus1"], (0...15).contains(refs),
              let reorder = fields["max_num_reorder_frames"], (0...2).contains(reorder),
              let poc = fields["log2_max_pic_order_cnt_lsb_minus4"], (0...1).contains(poc),
              let qp = fields["pic_init_qp_minus26"], (-26...25).contains(qp),
              let chroma = fields["chroma_qp_index_offset"], (-12...12).contains(chroma),
              fields["frame_mbs_only_flag"] == 1 else { return nil }
        let parameters = [
            "ref=\(refs + 1)", "bframes=\(reorder == 0 ? 0 : poc == 0 ? 1 : 3)",
            "b-pyramid=\(reorder >= 2 ? "normal" : "none")",
            "weightp=\(fields["weighted_pred_flag"] == 1 ? 1 : 0)",
            "weightb=\(fields["weighted_bipred_idc"] == 2 ? 1 : 0)",
            "cabac=\(fields["entropy_coding_mode_flag"] ?? 1)",
            "8x8dct=\(fields["transform_8x8_mode_flag"] ?? 0)",
            "chroma-qp-offset=\(chroma)", "psy=0",
            "force-cfr=\(fields["fixed_frame_rate_flag"] ?? 0)"
        ].joined(separator: ":")
        // ABR uses the standard initial QP; CRF embeds its initial QP in PPS.
        return ["-enc_time_base", "\(units * 2):\(ticks)", "-x264-params", parameters]
            + (qp == 0 ? ["-b:v", "9M"] : ["-crf", String(26 + qp)])
    }
}

enum H264Configuration {
    /// Some muxers omit the optional AVC High-profile extension. Its default
    /// 4:2:0 / 8-bit / zero-extra-SPS form adds no information to the SPS.
    /// All SPS/PPS bytes, profile flags and NAL length size still match exactly.
    static func compatibilityKey(_ data: Data) -> Data {
        let bytes = Array(data)
        guard bytes.count >= 7, bytes[0] == 1, bytes[1] == 100 else { return data }
        var offset = 6
        func skipSets(_ count: Int) -> Bool {
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return false }
                let size = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
                offset += 2
                guard size > 0, offset + size <= bytes.count else { return false }
                offset += size
            }
            return true
        }
        guard skipSets(Int(bytes[5] & 31)), offset < bytes.count else { return data }
        let count = Int(bytes[offset]); offset += 1
        guard skipSets(count), Array(bytes[offset...]) == [0xfd, 0xf8, 0xf8, 0] else { return data }
        return Data(bytes[..<offset])
    }
}
