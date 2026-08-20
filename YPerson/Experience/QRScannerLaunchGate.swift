struct QRScannerLaunchGate {
    private(set) var isPending = false

    mutating func begin(alreadyPresenting: Bool) -> Bool {
        guard !isPending, !alreadyPresenting else { return false }
        isPending = true
        return true
    }

    mutating func complete() {
        isPending = false
    }
}
