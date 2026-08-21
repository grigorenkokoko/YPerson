import AppTrackingTransparency
import Contacts
import CoreLocation
import LocalAuthentication
import Photos
import PhotosUI
import UIKit
import UserNotifications

enum AuthorizationState: Equatable {
    case notDetermined
    case authorized(String?)
    case limited(String?)
    case denied
    case restricted
    case unavailable(String)
}

final class PermissionCenter: NSObject, CLLocationManagerDelegate {
    private let contactStore = CNContactStore()
    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let notificationCenter: UNUserNotificationCenter
    private var locationCompletion: ((Result<String, Error>) -> Void)?

    init(notificationCenter: UNUserNotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func contactsState() -> AuthorizationState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized(nil)
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited:
            if #available(iOS 18.0, *) { return .limited("Доступна выбранная часть адресной книги") }
            return .restricted
        @unknown default: return .unavailable("Неизвестный статус Контактов")
        }
    }

    func requestContacts(completion: @escaping (AuthorizationState) -> Void) {
        contactStore.requestAccess(for: .contacts) { [weak self] _, _ in
            DispatchQueue.main.async { completion(self?.contactsState() ?? .unavailable("Контакты недоступны")) }
        }
    }

    func duplicateContactCount(for card: PersonCard) throws -> Int {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var count = 0
        let normalizedPhone = card.phone.filter(\.isNumber)
        try contactStore.enumerateContacts(with: request) { contact, _ in
            let phoneMatch = contact.phoneNumbers.contains { $0.value.stringValue.filter(\.isNumber).hasSuffix(normalizedPhone.suffix(10)) }
            let emailMatch = contact.emailAddresses.contains { ($0.value as String).caseInsensitiveCompare(card.email) == .orderedSame }
            if phoneMatch || emailMatch { count += 1 }
        }
        return count
    }

    func saveContact(_ card: PersonCard) throws {
        let contact = makeContact(card)
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try contactStore.execute(request)
    }

    func makeContact(_ card: PersonCard) -> CNMutableContact {
        let contact = CNMutableContact()
        let names = card.name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = names.first ?? card.name
        contact.familyName = names.count > 1 ? names[1] : ""
        contact.organizationName = card.company
        contact.jobTitle = card.role
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: card.phone))]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: card.email as NSString)]
        return contact
    }

    func makePersonCard(from contact: CNContact) -> PersonCard {
        let formattedName = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let organizationName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = formattedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (organizationName.isEmpty ? "Без имени" : organizationName)
        return PersonCard(
            id: "system-contact-\(contact.identifier)",
            name: name,
            role: contact.jobTitle,
            company: organizationName,
            phone: contact.phoneNumbers.first?.value.stringValue ?? "",
            email: contact.emailAddresses.first.map { $0.value as String } ?? "",
            tagline: "",
            hasAudioGreeting: false,
            meetingPlace: nil,
            isBlocked: false,
            sourceInstallationID: nil,
            syncState: .localOnly
        )
    }

    func authenticatePrivateFields(completion: @escaping (Result<Void, Error>) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = "Оставить закрытым"
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        context.evaluatePolicy(policy, localizedReason: "Открыть закрытые поля визитки") { success, error in
            DispatchQueue.main.async {
                if success { completion(.success(())) }
                else { completion(.failure(error ?? NSError(domain: "YPerson.LocalAuthentication", code: 1))) }
            }
        }
    }

    func requestCurrentPlace(completion: @escaping (Result<String, Error>) -> Void) {
        locationCompletion = completion
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: locationManager.requestLocation()
        case .denied: finishLocation(.failure(NSError(domain: "YPerson.Location", code: 2, userInfo: [NSLocalizedDescriptionKey: "Доступ к геопозиции выключен. Введите место вручную."])))
        case .restricted: finishLocation(.failure(NSError(domain: "YPerson.Location", code: 3, userInfo: [NSLocalizedDescriptionKey: "Геопозиция ограничена на этом устройстве."])))
        @unknown default: finishLocation(.failure(NSError(domain: "YPerson.Location", code: 4, userInfo: [NSLocalizedDescriptionKey: "Геопозиция недоступна."])))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            finishLocation(.failure(NSError(domain: "YPerson.Location", code: 5, userInfo: [NSLocalizedDescriptionKey: "Используйте ручную подпись места."])))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        manager.stopUpdatingLocation()
        guard let location = locations.last else { return }
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.finishLocation(.failure(error)); return }
                guard let placemark = placemarks?.first else {
                    self.finishLocation(.failure(NSError(domain: "YPerson.Location", code: 6, userInfo: [NSLocalizedDescriptionKey: "Не удалось определить подпись места."])))
                    return
                }
                let candidates = [placemark.locality, placemark.subAdministrativeArea, placemark.administrativeArea, placemark.country].compactMap { $0 }
                var unique: [String] = []
                for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
                self.finishLocation(.success(unique.prefix(2).joined(separator: ", ")))
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        finishLocation(.failure(error))
    }

    private func finishLocation(_ result: Result<String, Error>) {
        let completion = locationCompletion
        locationCompletion = nil
        completion?(result)
    }

    func requestPhotoRead(completion: @escaping (AuthorizationState) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async { completion(Self.photoState(status)) }
        }
    }

    func requestPhotoAdd(completion: @escaping (AuthorizationState) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async { completion(Self.photoState(status)) }
        }
    }

    func presentLimitedPhotoManager(from viewController: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }

    private static func photoState(_ status: PHAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized(nil)
        case .limited: return .limited("Используются только выбранные фото")
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable("Неизвестный статус Фото")
        }
    }

    func requestTracking(completion: @escaping (Bool, AuthorizationState) -> Void) {
        guard #available(iOS 14.0, *) else { completion(false, .unavailable("ATT недоступен")); return }
        ATTrackingManager.requestTrackingAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized: completion(true, .authorized(nil))
                case .denied: completion(false, .denied)
                case .restricted: completion(false, .restricted)
                case .notDetermined: completion(false, .notDetermined)
                @unknown default: completion(false, .unavailable("Неизвестный статус ATT"))
                }
            }
        }
    }

    func requestNotifications(completion: @escaping (AuthorizationState) -> Void) {
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if let error { completion(.unavailable(error.localizedDescription)) }
                else if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    completion(.authorized(nil))
                } else { completion(.denied) }
            }
        }
    }

    func scheduleReviewNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Алексей обновил визитку"
        content.body = "Изменены: роль и компания"
        content.categoryIdentifier = "YPERSON_CARD_UPDATE"
        content.userInfo = ["card_id": "person-alexey", "changed_fields": ["роль", "компания"]]
        notificationCenter.add(UNNotificationRequest(identifier: "yperson-review", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    deinit { geocoder.cancelGeocode(); locationManager.stopUpdatingLocation() }
}
