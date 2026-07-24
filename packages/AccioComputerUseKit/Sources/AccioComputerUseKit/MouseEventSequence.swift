import Foundation

struct TargetedClickEventNumberPlan: Equatable {
    let move: Int
    let primer: Int
    let clicks: [Int]
}

func shouldUseAXClickActions(clickCount: Int) -> Bool {
    clickCount == 1
}

func targetedClickEventNumberPlan(clickCount: Int, seed: Int) -> TargetedClickEventNumberPlan {
    let count = max(clickCount, 1)
    return TargetedClickEventNumberPlan(
        move: seed,
        primer: seed + 1,
        clicks: (0..<count).map { seed + 2 + $0 }
    )
}

func syntheticMouseEventNumberSeed() -> Int {
    let milliseconds = UInt64(ProcessInfo.processInfo.systemUptime * 1_000)
    return Int(milliseconds % UInt64(Int32.max - 64))
}
