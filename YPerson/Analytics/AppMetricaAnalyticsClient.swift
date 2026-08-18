import AppMetricaCore
import Foundation

final class AppMetricaAnalyticsClient {
    private let apiKey: String
    private var consentEnabled: Bool
    private var trackingAuthorized = false
    private var remoteKillSwitch = false
    private var launchReported = false
    private(set) var isActivated = false

    init(apiKey: String, initialConsent: Bool) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.consentEnabled = initialConsent
    }

    @discardableResult
    func activateIfConsented() -> Bool {
        guard consentEnabled, !remoteKillSwitch, !isActivated, UUID(uuidString: apiKey) != nil,
              let configuration = AppMetricaConfiguration(apiKey: apiKey) else { return false }
        configuration.dataSendingEnabled = true
        configuration.locationTracking = false
        configuration.accurateLocationTracking = false
        configuration.allowsBackgroundLocationUpdates = false
        configuration.customLocation = nil
        configuration.userProfileID = nil
        configuration.revenueAutoTrackingEnabled = false
        configuration.advertisingIdentifierTrackingEnabled = trackingAuthorized
        AppMetrica.activate(with: configuration)
        isActivated = AppMetrica.isActivated
        if isActivated { report(.launch) }
        return isActivated
    }

    func setConsent(_ enabled: Bool) {
        consentEnabled = enabled
        if enabled {
            if isActivated { AppMetrica.setDataSendingEnabled(!remoteKillSwitch) }
            else { _ = activateIfConsented() }
        } else if isActivated {
            AppMetrica.setDataSendingEnabled(false)
        }
    }

    func setRemoteKillSwitch(_ enabled: Bool) {
        remoteKillSwitch = enabled
        if isActivated { AppMetrica.setDataSendingEnabled(consentEnabled && !enabled) }
    }

    func setTrackingAuthorized(_ authorized: Bool) {
        trackingAuthorized = authorized
        if isActivated { AppMetrica.isAdvertisingIdentifierTrackingEnabled = authorized }
    }

    func report(_ event: AnalyticsEvent) {
        guard isActivated, consentEnabled, !remoteKillSwitch else { return }
        if case .launch = event {
            guard !launchReported else { return }
            launchReported = true
        }
        if let parameters = event.parameters {
            AppMetrica.reportEvent(name: event.name, parameters: parameters, onFailure: nil)
        } else {
            AppMetrica.reportEvent(name: event.name, onFailure: nil)
        }
    }
}
