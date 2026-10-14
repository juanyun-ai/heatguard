import Foundation

/// A conservative, local-only daily thermal exposure record. It is an
/// exposure ledger, not a hardware-life or failure prediction: an interval is
/// counted only when both endpoint temperature samples are valid and the
/// gap is short enough to represent continuous awake monitoring.
struct ThermalExposureDay: Identifiable, Codable, Sendable, Equatable {
    let day: Date
    var coveredMinutes: Double = 0
    var above65Minutes: Double = 0
    var above70Minutes: Double = 0
    var peakTemperatureCelsius: Double = 0
    var peakHostCPUPercent: Double = 0
    var sampleCount: Int = 0

    var id: Date { day }
}

enum ThermalExposureLedger {
    static let maximumDays = 400
    static let maximumContinuousGap: TimeInterval = 90

    /// Add one known-continuous interval. The lower-bound temperature is used
    /// for threshold minutes, so a single high endpoint cannot inflate the
    /// ledger. The peak values remain descriptive only.
    static func appendInterval(from start: Date, to end: Date,
                               lowerBoundTemperature: Double,
                               peakTemperature: Double,
                               hostCPUPercent: Double,
                               into days: inout [ThermalExposureDay],
                               calendar: Calendar = .autoupdatingCurrent) {
        let duration = end.timeIntervalSince(start)
        guard duration > 0, duration <= maximumContinuousGap,
              lowerBoundTemperature.isFinite, lowerBoundTemperature > 0,
              lowerBoundTemperature < 150,
              peakTemperature.isFinite, peakTemperature > 0, peakTemperature < 150,
              hostCPUPercent.isFinite else { return }
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
            let segmentEnd = min(end, nextDay)
            let minutes = segmentEnd.timeIntervalSince(cursor) / 60
            guard minutes > 0, minutes.isFinite else { return }
            if let index = days.firstIndex(where: { $0.day == dayStart }) {
                days[index].coveredMinutes += minutes
                if lowerBoundTemperature >= 65 { days[index].above65Minutes += minutes }
                if lowerBoundTemperature >= 70 { days[index].above70Minutes += minutes }
                days[index].peakTemperatureCelsius = max(days[index].peakTemperatureCelsius, peakTemperature)
                days[index].peakHostCPUPercent = max(days[index].peakHostCPUPercent, max(0, hostCPUPercent))
                days[index].sampleCount += 1
            } else {
                days.append(ThermalExposureDay(day: dayStart,
                    coveredMinutes: minutes,
                    above65Minutes: lowerBoundTemperature >= 65 ? minutes : 0,
                    above70Minutes: lowerBoundTemperature >= 70 ? minutes : 0,
                    peakTemperatureCelsius: peakTemperature,
                    peakHostCPUPercent: max(0, hostCPUPercent),
                    sampleCount: 1))
            }
            cursor = segmentEnd
        }
        days = bounded(days, now: end, calendar: calendar)
    }

    static func bounded(_ input: [ThermalExposureDay], now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> [ThermalExposureDay] {
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -(maximumDays - 1), to: today) ?? today
        return input
            .filter { $0.day >= oldest && $0.day <= today && $0.day == calendar.startOfDay(for: $0.day) }
            .sorted { $0.day < $1.day }
            .suffix(maximumDays)
            .map { $0 }
    }
}
