/// Measured wall-clock time spent in sampling stages, in milliseconds.
/// These durations are not process CPU percentages or CPU time measurements.
struct SamplingTimings: Sendable, Equatable {
    var snapshotMilliseconds: Double = 0
    var deltaMilliseconds: Double = 0
    var metadataMilliseconds: Double = 0
    var analysisMilliseconds: Double = 0

    var totalMeasuredMilliseconds: Double {
        snapshotMilliseconds + deltaMilliseconds + metadataMilliseconds + analysisMilliseconds
    }

    fileprivate var isValid: Bool {
        snapshotMilliseconds.isFinite && snapshotMilliseconds >= 0
            && deltaMilliseconds.isFinite && deltaMilliseconds >= 0
            && metadataMilliseconds.isFinite && metadataMilliseconds >= 0
            && analysisMilliseconds.isFinite && analysisMilliseconds >= 0
            && totalMeasuredMilliseconds.isFinite
    }
}

/// A bounded in-memory diagnostic ring. No timers, disk writes or process calls.
/// Statistics describe the most recent 64 valid wall-clock measurements only.
struct SamplingTimingBuffer: Sendable {
    private static let capacity = 64
    private var samples: [SamplingTimings] = []
    private var nextReplacementIndex = 0

    var count: Int { samples.count }

    /// Invalid measurements neither consume a slot nor evict an earlier sample.
    @discardableResult
    mutating func append(_ timings: SamplingTimings) -> Bool {
        guard timings.isValid else { return false }
        if samples.count < Self.capacity {
            samples.append(timings)
        } else {
            samples[nextReplacementIndex] = timings
            nextReplacementIndex = (nextReplacementIndex + 1) % Self.capacity
        }
        return true
    }

    var mean: SamplingTimings {
        var result = SamplingTimings()
        for (index, sample) in samples.enumerated() {
            let divisor = Double(index + 1)
            // Incremental means avoid overflowing an intermediate running sum.
            result.snapshotMilliseconds += (sample.snapshotMilliseconds - result.snapshotMilliseconds) / divisor
            result.deltaMilliseconds += (sample.deltaMilliseconds - result.deltaMilliseconds) / divisor
            result.metadataMilliseconds += (sample.metadataMilliseconds - result.metadataMilliseconds) / divisor
            result.analysisMilliseconds += (sample.analysisMilliseconds - result.analysisMilliseconds) / divisor
        }
        return result
    }

    /// Per-stage maxima; the four peaks need not come from the same sample.
    var maximum: SamplingTimings {
        var result = SamplingTimings()
        for sample in samples {
            result.snapshotMilliseconds = max(result.snapshotMilliseconds, sample.snapshotMilliseconds)
            result.deltaMilliseconds = max(result.deltaMilliseconds, sample.deltaMilliseconds)
            result.metadataMilliseconds = max(result.metadataMilliseconds, sample.metadataMilliseconds)
            result.analysisMilliseconds = max(result.analysisMilliseconds, sample.analysisMilliseconds)
        }
        return result
    }
}
