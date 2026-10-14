import Darwin

/// Pure regression cases. No process is created, signaled, or inspected.
/// SelfTest/IntegrationTest can consume each result with their existing runner.
enum ActionVerificationTests {
    static func run() -> [(name: String, passed: Bool)] {
        let original = ProcessIdentity(pid: 4242, startAbstime: 100)
        let reused = ProcessIdentity(pid: 4242, startAbstime: 200)
        var results: [(name: String, passed: Bool)] = []

        func check(_ name: String, observed: ProcessIdentity?, result: Int32,
                   error: Int32, expected: ActionVerification.State) {
            let state = ActionVerification.state(expected: original, observed: observed) {
                (result, error)
            }
            results.append((name, state == expected))
        }

        check("结束核验：读取失败但 PID 存在不能报成功", observed: nil,
              result: 0, error: 0, expected: .unknown)
        check("结束核验：EPERM 不能报成功", observed: nil,
              result: -1, error: EPERM, expected: .unknown)
        check("结束核验：ESRCH 才确认不可读目标已消失", observed: nil,
              result: -1, error: ESRCH, expected: .gone)
        check("结束核验：成功的存在探测忽略残留 ESRCH", observed: nil,
              result: 0, error: ESRCH, expected: .unknown)
        check("结束核验：其他探测错误保留未知", observed: nil,
              result: -1, error: EINVAL, expected: .unknown)

        var probeCalls = 0
        let same = ActionVerification.state(expected: original, observed: original) {
            probeCalls += 1
            return (-1, ESRCH)
        }
        results.append(("结束核验：同一身份仍存在且不作额外探测", same == .same && probeCalls == 0))

        let different = ActionVerification.state(expected: original, observed: reused) {
            probeCalls += 1
            return (0, 0)
        }
        results.append(("结束核验：PID 已复用证明原身份已消失且不探测新任务", different == .gone && probeCalls == 0))
        return results
    }
}

