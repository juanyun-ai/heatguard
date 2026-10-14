/// Pure classification/cache regressions. No sampling, signals or app state.
enum StaticProcessFactsCacheRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let identity = ProcessIdentity(pid: 41_001, startAbstime: 101)
        let userPath = "/Applications/Example.app/Contents/MacOS/Example"
        var cache = StaticProcessFactsCache()
        let original = cache.facts(identity: identity, name: "Example", path: userPath,
                                   bundleIdentifier: nil)
        let repeated = cache.facts(identity: identity, name: "Example", path: userPath,
                                   bundleIdentifier: nil)
        let sameKeyReused = cache.count == 1 && equal(original, repeated)

        let changedPath = cache.facts(identity: identity, name: "Example",
                                      path: "/System/Library/Example", bundleIdentifier: nil)
        let pathInvalidates = cache.count == 2 && changedPath.isSystemPath
            && !original.isSystemPath
        let changedName = cache.facts(identity: identity, name: "kernel_task", path: userPath,
                                      bundleIdentifier: nil)
        let nameInvalidates = cache.count == 3 && changedName.advice.protected
            && !original.advice.protected
        let changedBundle = cache.facts(identity: identity, name: "Example", path: userPath,
                                        bundleIdentifier: "com.apple.WindowServer")
        let bundleInvalidates = cache.count == 4 && changedBundle.advice.protected
            && !original.advice.protected
        _ = cache.facts(identity: identity, name: "Example", path: userPath,
                        bundleIdentifier: "")
        let nilIsDistinctFromEmpty = cache.count == 5
        let restarted = cache.facts(identity: ProcessIdentity(pid: identity.pid, startAbstime: 102),
                                    name: "Example", path: userPath, bundleIdentifier: nil)
        let restartInvalidates = cache.count == 6 && equal(original, restarted)
        _ = cache.facts(identity: ProcessIdentity(pid: 41_002, startAbstime: identity.startAbstime),
                        name: "Example", path: userPath, bundleIdentifier: nil)
        let pidInvalidates = cache.count == 7

        var bounded = StaticProcessFactsCache()
        var alwaysBounded = true
        for index in 0..<StaticProcessFactsCache.capacity {
            _ = bounded.facts(identity: ProcessIdentity(pid: 42_000, startAbstime: UInt64(index)),
                              name: "Example", path: userPath, bundleIdentifier: nil)
            alwaysBounded = alwaysBounded && bounded.count <= StaticProcessFactsCache.capacity
        }
        let filled = bounded.count == StaticProcessFactsCache.capacity
        _ = bounded.facts(identity: ProcessIdentity(pid: 42_000, startAbstime: 0),
                          name: "Example", path: userPath, bundleIdentifier: nil)
        let fullCacheHitRetained = bounded.count == StaticProcessFactsCache.capacity
        let overflow = bounded.facts(identity: identity, name: "kernel_task", path: "/usr/bin/kernel_task",
                                     bundleIdentifier: nil)
        let overflowClears = bounded.count == 1 && overflow.isSystemPath && overflow.advice.protected
        let refetched = bounded.facts(identity: ProcessIdentity(pid: 42_000, startAbstime: 0),
                                      name: "Example", path: userPath, bundleIdentifier: nil)
        let evictionIsTransparent = bounded.count == 2 && equal(original, refetched)

        let samples: [(name: String, path: String, bundle: String?)] = [
            ("Example", userPath, nil),
            ("Example", "", nil),
            ("kernel_task", "/System/Library/Example", nil),
            ("mdworker", "/usr/libexec/mdworker", nil),
            ("Example", "/usr/local/bin/Example", nil),
            ("Example", "/usr/local/../bin/Example", nil),
            ("Example", "/usr/locality/bin/Example", nil),
            ("Example", "/Applications/Example.app/Contents/MacOS/Example", "com.apple.WindowServer"),
            ("swift-frontend", "/Applications/Xcode.app/Contents/Developer/usr/bin/swift-frontend", nil),
            ("Example", "/Applications/浏览器.app/Contents/MacOS/Example", "org.mozilla.firefox"),
            ("Example", "/opt/homebrew/bin/Example", ""),
            ("backupd", "/System/Library/CoreServices/backupd", "com.apple.backupd")
        ]
        var directEquivalent = true
        for sample in samples {
            let expected = StaticProcessFacts(
                isSystemPath: ProcessPathPolicy.isSystemExecutable(sample.path),
                advice: LocalKnowledgeBase.advice(name: sample.name, path: sample.path,
                                                  bundleIdentifier: sample.bundle),
                excludesAutomaticProtection: LocalKnowledgeBase.isAutomaticProtectionExcluded(
                    name: sample.name, path: sample.path, bundleIdentifier: sample.bundle)
            )
            let first = cache.facts(identity: identity, name: sample.name, path: sample.path,
                                    bundleIdentifier: sample.bundle)
            let hit = cache.facts(identity: identity, name: sample.name, path: sample.path,
                                  bundleIdentifier: sample.bundle)
            directEquivalent = directEquivalent && equal(expected, first) && equal(expected, hit)
        }

        return [
            ("静态分类同一完整输入命中缓存而不重复增长", sameKeyReused),
            ("相同启动身份 exec 路径变化重新分类", pathInvalidates),
            ("相同启动身份名称变化重新分类", nameInvalidates),
            ("相同启动身份 bundle 变化重新分类且保留 nil 区别", bundleInvalidates && nilIsDistinctFromEmpty),
            ("进程重启或 PID 变化不继承原缓存键", restartInvalidates && pidInvalidates),
            ("静态分类缓存硬上限 2048 且满时命中不丢弃条目", filled && alwaysBounded && fullCacheHitRetained),
            ("静态分类缓存溢出安全清空且重新计算保持结果", overflowClears && evictionIsTransparent),
            ("缓存首次计算与命中均等价于直接路径和知识库分类", directEquivalent)
        ]
    }

    private static func equal(_ lhs: StaticProcessFacts, _ rhs: StaticProcessFacts) -> Bool {
        lhs.excludesAutomaticProtection == rhs.excludesAutomaticProtection &&
        lhs.isSystemPath == rhs.isSystemPath
            && lhs.advice.explanation == rhs.advice.explanation
            && lhs.advice.recommendation == rhs.advice.recommendation
            && lhs.advice.protected == rhs.advice.protected
    }
}
