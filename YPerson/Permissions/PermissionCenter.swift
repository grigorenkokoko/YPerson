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

enum ContactReconciliationAction: Equatable {
    case add
    case update
    case noChange
}

struct ContactReconciliationCandidate {
    let identifier: String
    let name: String
    let detail: String
}

struct ContactReconciliationPlan {
    let action: ContactReconciliationAction
    let candidate: ContactReconciliationCandidate?
    let changedFields: [String]
}

enum ContactReconciliationResult {
    case plan(ContactReconciliationPlan)
    case chooseCandidate([ContactReconciliationCandidate])
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

    func reconciliation(for card: PersonCard, choosing candidateIdentifier: String? = nil) throws -> ContactReconciliationResult {
        let keys = contactKeys
        let request = CNContactFetchRequest(keysToFetch: keys)
        var matches: [CNContact] = []
        try contactStore.enumerateContacts(with: request) { contact, _ in
            if ContactMatchPolicy.matches(
                phone: card.phone,
                email: card.email,
                candidatePhones: contact.phoneNumbers.map { $0.value.stringValue },
                candidateEmails: contact.emailAddresses.map { $0.value as String }
            ) {
                matches.append(contact)
            }
        }
        guard !matches.isEmpty else { return .plan(plan(for: card, contact: nil)) }

        if matches.count > 1, candidateIdentifier == nil {
            return .chooseCandidate(matches.map(candidate(from:)))
        }
        guard let contact = candidateIdentifier.flatMap({ identifier in matches.first { $0.identifier == identifier } }) ?? (matches.count == 1 ? matches[0] : nil) else {
            return .chooseCandidate(matches.map(candidate(from:)))
        }
        return .plan(plan(for: card, contact: contact))
    }

    func apply(_ plan: ContactReconciliationPlan, for card: PersonCard) throws -> ContactReconciliationAction {
        let request = CNSaveRequest()
        switch plan.action {
        case .add:
            request.add(makeContact(card), toContainerWithIdentifier: nil)
        case .update:
            guard let identifier = plan.candidate?.identifier else {
                throw NSError(domain: "YPerson.Contacts", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось определить контакт для обновления."])
            }
            let contact = try contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: contactKeys)
            guard let mutableContact = contact.mutableCopy() as? CNMutableContact else {
                throw NSError(domain: "YPerson.Contacts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить контакт к обновлению."])
            }
            apply(card, to: mutableContact)
            request.update(mutableContact)
        case .noChange:
            return .noChange
        }
        try contactStore.execute(request)
        return plan.action
    }

    func saveContact(_ card: PersonCard) throws {
        let request = CNSaveRequest()
        request.add(makeContact(card), toContainerWithIdentifier: nil)
        try contactStore.execute(request)
    }

    private var contactKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ] as [CNKeyDescriptor]
    }

    private func candidate(from contact: CNContact) -> ContactReconciliationCandidate {
        let name = [contact.givenName, contact.familyName]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let detail = [contact.organizationName, contact.jobTitle]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        return ContactReconciliationCandidate(
            identifier: contact.identifier,
            name: name.isEmpty ? (contact.organizationName.isEmpty ? "Без имени" : contact.organizationName) : name,
            detail: detail
        )
    }

    private func plan(for card: PersonCard, contact: CNContact?) -> ContactReconciliationPlan {
        guard let contact else {
            return ContactReconciliationPlan(action: .add, candidate: nil, changedFields: fieldsForNewContact(card))
        }
        let fields = changedFields(from: card, comparedTo: contact)
        return ContactReconciliationPlan(
            action: fields.isEmpty ? .noChange : .update,
            candidate: candidate(from: contact),
            changedFields: fields
        )
    }

    private func fieldsForNewContact(_ card: PersonCard) -> [String] {
        var fields: [String] = []
        if !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("Имя") }
        if !card.company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("Компания") }
        if !card.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("Должность") }
        if ContactMatchPolicy.normalizedPhone(card.phone) != nil { fields.append("Телефон") }
        if ContactMatchPolicy.normalizedEmail(card.email) != nil { fields.append("Email") }
        return fields
    }

    private func changedFields(from card: PersonCard, comparedTo contact: CNContact) -> [String] {
        let names = card.name.split(separator: " ", maxSplits: 1).map(String.init)
        let givenName = names.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let familyName = names.count > 1 ? names[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var fields: [String] = []
        if (!givenName.isEmpty && givenName != contact.givenName) || (!familyName.isEmpty && familyName != contact.familyName) { fields.append("Имя") }
        if !card.company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, card.company != contact.organizationName { fields.append("Компания") }
        if !card.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, card.role != contact.jobTitle { fields.append("Должность") }
        if let phone = ContactMatchPolicy.normalizedPhone(card.phone), !contact.phoneNumbers.contains(where: { existing in
            ContactMatchPolicy.normalizedPhone(existing.value.stringValue) == phone || ContactMatchPolicy.phoneMatches(existing.value.stringValue, card.phone)
        }) { fields.append("Телефон") }
        if let email = ContactMatchPolicy.normalizedEmail(card.email), !contact.emailAddresses.contains(where: { existing in
            ContactMatchPolicy.normalizedEmail(existing.value as String) == email
        }) { fields.append("Email") }
        return fields
    }

    private func apply(_ card: PersonCard, to contact: CNMutableContact) {
        let names = card.name.split(separator: " ", maxSplits: 1).map(String.init)
        if let givenName = names.first?.trimmingCharacters(in: .whitespacesAndNewlines), !givenName.isEmpty { contact.givenName = givenName }
        if names.count > 1 {
            let familyName = names[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !familyName.isEmpty { contact.familyName = familyName }
        }
        let company = card.company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty { contact.organizationName = company }
        let role = card.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { contact.jobTitle = role }
        if let phone = ContactMatchPolicy.normalizedPhone(card.phone), !contact.phoneNumbers.contains(where: { existing in
            ContactMatchPolicy.normalizedPhone(existing.value.stringValue) == phone || ContactMatchPolicy.phoneMatches(existing.value.stringValue, card.phone)
        }) {
            contact.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: card.phone)))
        }
        if let email = ContactMatchPolicy.normalizedEmail(card.email), !contact.emailAddresses.contains(where: { existing in
            ContactMatchPolicy.normalizedEmail(existing.value as String) == email
        }) {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelWork, value: card.email.trimmingCharacters(in: .whitespacesAndNewlines) as NSString))
        }
    }

    func makeContact(_ card: PersonCard) -> CNMutableContact {
        let contact = CNMutableContact()
        let names = card.name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = names.first ?? card.name
        contact.familyName = names.count > 1 ? names[1] : ""
        contact.organizationName = card.company
        contact.jobTitle = card.role
        if ContactMatchPolicy.normalizedPhone(card.phone) != nil {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: card.phone))]
        }
        if ContactMatchPolicy.normalizedEmail(card.email) != nil {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: card.email.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)]
        }
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
