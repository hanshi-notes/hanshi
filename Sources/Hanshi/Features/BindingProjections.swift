extension Optional {
    nonisolated var isPresented: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}

extension Double {
    nonisolated subscript(clampedTo range: ClosedRange<Double>, fallback fallback: Double) -> Double {
        get { isFinite ? Swift.min(Swift.max(self, range.lowerBound), range.upperBound) : fallback }
        set { self = newValue[clampedTo: range, fallback: fallback] }
    }
}

extension Int {
    nonisolated subscript(clampedTo range: ClosedRange<Int>) -> Int {
        get { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
        set { self = newValue[clampedTo: range] }
    }
}
