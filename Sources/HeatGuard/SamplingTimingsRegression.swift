/// Pure numeric regressions. No timers, process sampling, settings or I/O.
enum SamplingTimingsRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let empty = SamplingTimingBuffer()
        let zero = SamplingTimings()

        var pair = SamplingTimingBuffer()
        pair.append(SamplingTimings(snapshotMilliseconds: 1, deltaMilliseconds: 4,
                                    metadataMilliseconds: 7, analysisMilliseconds: 3))
        pair.append(SamplingTimings(snapshotMilliseconds: 9, deltaMilliseconds: 2,
                                    metadataMilliseconds: 5, analysisMilliseconds: 6))
        let expectedMean = SamplingTimings(snapshotMilliseconds: 5, deltaMilliseconds: 3,
                                          metadataMilliseconds: 6, analysisMilliseconds: 4.5)
        let expectedMaximum = SamplingTimings(snapshotMilliseconds: 9, deltaMilliseconds: 4,
                                             metadataMilliseconds: 7, analysisMilliseconds: 6)

        var wrapped = SamplingTimingBuffer()
        for index in 0..<192 {
            let value = Double(index)
            wrapped.append(SamplingTimings(snapshotMilliseconds: value, deltaMilliseconds: value,
                                           metadataMilliseconds: value, analysisMilliseconds: value))
        }
        let retainedMean = SamplingTimings(snapshotMilliseconds: 159.5, deltaMilliseconds: 159.5,
                                          metadataMilliseconds: 159.5, analysisMilliseconds: 159.5)
        let retainedMaximum = SamplingTimings(snapshotMilliseconds: 191, deltaMilliseconds: 191,
                                             metadataMilliseconds: 191, analysisMilliseconds: 191)

        var invalidsRejected = true
        let beforeCount = wrapped.count
        let beforeMean = wrapped.mean
        let beforeMaximum = wrapped.maximum
        for invalid in [Double(-1), .nan, .infinity, -.infinity] {
            invalidsRejected = !wrapped.append(SamplingTimings(snapshotMilliseconds: invalid)) && invalidsRejected
            invalidsRejected = !wrapped.append(SamplingTimings(deltaMilliseconds: invalid)) && invalidsRejected
            invalidsRejected = !wrapped.append(SamplingTimings(metadataMilliseconds: invalid)) && invalidsRejected
            invalidsRejected = !wrapped.append(SamplingTimings(analysisMilliseconds: invalid)) && invalidsRejected
        }
        invalidsRejected = !wrapped.append(SamplingTimings(snapshotMilliseconds: .greatestFiniteMagnitude,
                                                           deltaMilliseconds: .greatestFiniteMagnitude))
            && invalidsRejected
        invalidsRejected = invalidsRejected && wrapped.count == beforeCount
            && wrapped.mean == beforeMean && wrapped.maximum == beforeMaximum

        return [
            ("采样阶段计时空缓冲返回零值", empty.count == 0 && empty.mean == zero && empty.maximum == zero),
            ("采样阶段计时均值和总墙钟时长正确", pair.count == 2 && pair.mean == expectedMean
             && pair.mean.totalMeasuredMilliseconds == 18.5),
            ("采样阶段峰值独立计算而不是选取单条样本", pair.maximum == expectedMaximum),
            ("采样计时环形缓冲多次覆盖后只保留最新64条", wrapped.count == 64
             && beforeMean == retainedMean && beforeMaximum == retainedMaximum),
            ("非有限负数及溢出计时不会污染或挤掉有效样本", invalidsRejected)
        ]
    }
}
