import Foundation

struct TopRow: Sendable {
    let pid: pid_t
    let uid: uid_t
    let cpuPercent: Double
    let command: String
}

enum TopSampler {
    static func capture() async -> TopScanResult {
        let before = NativeSampler.processes()
        let result = await CommandRunner.run("/usr/bin/top", [
                    "-l", "2",
                    "-s", "1",
                    "-F", "-R",
                    "-n", "40",
                    "-ncols", "512",
                    "-o", "cpu",
                    "-stats", "pid,uid,cpu,command"
        ], timeout: 8)
        guard !Task.isCancelled, result.succeeded, let text = String(data: result.output, encoding: .utf8) else {
            return TopScanResult(deltas: [], succeeded: false)
        }
        let rows = parseRows(text)
        return TopScanResult(deltas: enrich(rows, before: before, with: NativeSampler.processes()),
                             succeeded: !rows.isEmpty)
    }

    static func parseRows(_ text: String) -> [TopRow] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headers = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("PID")
                && lines[$0].contains("UID") && lines[$0].contains("%CPU")
        }
        guard headers.count >= 2, let header = headers.last, header + 1 < lines.count else { return [] }

        var results: [TopRow] = []

        for line in lines[(header + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            let columns = trimmed.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard columns.count == 4,
                  let pid = Int32(columns[0]),
                  let uid = UInt32(columns[1]),
                  let cpu = Double(columns[2]),
                  cpu.isFinite, cpu >= 0 else { break }

            let command = String(columns[3])
            if command == "top" { continue }
            results.append(TopRow(pid: pid, uid: uid, cpuPercent: cpu, command: command))
        }
        return results
    }

    private static func enrich(_ rows: [TopRow], before: [RawProcessSample], with native: [RawProcessSample]) -> [ProcessDelta] {
        let old = Dictionary(before.map { ($0.identity.pid, $0) }, uniquingKeysWith: { _, new in new })
        let nativeByPID = native.reduce(into: [pid_t: RawProcessSample]()) { result, sample in
            result[sample.identity.pid] = sample
        }
        return rows.compactMap { row in
            let raw = nativeByPID[row.pid]
            if let raw, raw.uid != row.uid { return nil }
            if let prior = old[row.pid], let raw, prior.identity != raw.identity { return nil }
            // Newly created/unverifiable identities remain protected observations.
            let verifiedIdentity = old[row.pid]?.identity == raw?.identity ? raw?.identity : nil
            return ProcessDelta(
                identity: verifiedIdentity ?? ProcessIdentity(pid: row.pid, startAbstime: 0),
                parentPID: raw?.parentPID ?? 0,
                uid: raw?.uid ?? row.uid,
                name: raw.map { $0.name.isEmpty ? row.command : $0.name } ?? row.command,
                path: raw?.path ?? "",
                cpuPercent: row.cpuPercent,
                wakeupsPerSecond: 0,
                diskBytesPerSecond: 0,
                residentBytes: raw?.residentBytes ?? 0,
                sampleDuration: 1
            )
        }
    }
}

struct TopScanResult: Sendable {
    let deltas: [ProcessDelta]
    let succeeded: Bool
}
