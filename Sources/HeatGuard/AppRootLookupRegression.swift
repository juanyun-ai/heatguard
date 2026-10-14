import Foundation

/// Exact result comparisons for a pure lookup optimization. No process action,
/// cache, filesystem access or permission state participates in these tests.
enum AppRootLookupRegression {
    static func results() -> [(name: String, passed: Bool)] {
        let examples: [(String, String?)] = [
            ("", nil), ("/", nil), ("/usr/bin/top", nil), ("APP", nil), ("nameapp", nil),
            ("/Applications/Example.app", "/Applications/Example.app"),
            ("/Applications/Example.APP", "/Applications/Example.APP"),
            ("/Applications/Outer.App/Contents/Helper.app/Contents/MacOS/helper", "/Applications/Outer.App"),
            ("/Users/test/not.appx/bin", nil), ("relative.app", "relative.app"),
            ("prefix.app/", "prefix.app"), ("./a", nil),
            ("folder.app//next", "folder.app"), ("/Applications/a.aPP/b", "/Applications/a.aPP")
        ]
        var ascii: [String] = ["a\0.app/b", "a\0pp"]
        for byte in 0...127 {
            let inserted = String(UnicodeScalar(byte)!)
            for split in 0...5 {
                let needle = Array(".aPp/")
                ascii.append("/tmp/Example" + String(needle.prefix(split)) + inserted
                    + String(needle.suffix(5 - split)) + "worker")
            }
        }
        var unicode: [String] = ["/Applications/中文.app/Contents/MacOS/a"]
        for dot in [".", "\u{2024}", "\u{FF0E}", "\u{FE52}", "\u{3002}"] {
            for name in ["app", "APP", "App", "a\u{034F}pp", "a\u{0307}pp", "ａｐｐ", "äpp", "αpp", "apP"] {
                for suffix in ["", "/bin/worker", "/Inner.app/bin", "x", "\0", "\n"] {
                    unicode.append("/Applications/Prefix" + dot + name + suffix)
                }
            }
        }
        var long: [String] = []
        for count in [0, 1, 8, 64, 512, 4096] {
            long.append("/" + String(repeating: "a", count: count))
            long.append("/" + String(repeating: "a", count: count) + ".App/x")
            long.append("/" + String(repeating: "测", count: count) + ".app/x")
        }
        let bridged = (examples.map(\.0) + long).map { ($0 as NSString).substring(from: 0) }
        return [
            ("ASCII 路径保持最外层 App 归属和原始大小写", examples.allSatisfy { AppResolver.appRoot(from: $0.0) == $0.1 }),
            ("所有 ASCII 字节插入边界与原 Foundation 结果完全一致", equalToReference(ascii)),
            ("Unicode 点号大小写组合字符仍走原比较语义", equalToReference(unicode)),
            ("长路径及 NSString 桥接输入不改变 App 归属", equalToReference(long + bridged))
        ]
    }

    private static func equalToReference(_ inputs: [String]) -> Bool {
        inputs.allSatisfy { AppResolver.appRoot(from: $0) == reference($0) }
    }

    /// build17 implementation kept as an oracle; never used by monitoring.
    private static func reference(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else {
            return path.lowercased().hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.upperBound].dropLast())
    }
}
