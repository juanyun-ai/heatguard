/// Deterministic state tests. No notifications, windows, user preferences or
/// real session state are changed or queried by these cases.
enum ProtectionSessionSnapshotRegression {
    static func results() -> [(name: String, passed: Bool)] {
        var results: [(name: String, passed: Bool)] = [
            ("当前控制台、登录完成且显示器醒着才通过会话快照门禁",
             ProtectionSessionSnapshot(onConsole: true, loginDone: true,
                                       anyDisplayAwake: true).isInteractive)
        ]
        let fields = ["控制台状态", "登录状态", "显示器唤醒状态"]
        for index in fields.indices {
            for value: Bool? in [false, nil] {
                var values: [Bool?] = [true, true, true]
                values[index] = value
                let snapshot = ProtectionSessionSnapshot(onConsole: values[0], loginDone: values[1],
                                                         anyDisplayAwake: values[2])
                results.append(("\(fields[index])\(value == nil ? "未知" : "为否")时禁止自动动作",
                                !snapshot.isInteractive))
            }
        }
        results.append(("全部会话信息未知时不会默认允许自动动作",
                        !ProtectionSessionSnapshot(onConsole: nil, loginDone: nil,
                                                   anyDisplayAwake: nil).isInteractive))
        return results
    }
}
