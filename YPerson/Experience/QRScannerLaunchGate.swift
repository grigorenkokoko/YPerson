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

    mutating func reset() {
        isPending = false
    }
}

enum QRScannerPermissionPolicy {
    enum AuthorizationState {
        case authorized
        case notDetermined
        case denied
        case restricted
        case unavailable
    }

    enum Action: Equatable {
        case openScanner
        case explainPermission
    }

    static func action(for state: AuthorizationState) -> Action {
        switch state {
        case .notDetermined:
            return .explainPermission
        case .authorized, .denied, .restricted, .unavailable:
            return .openScanner
        }
    }
}
