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

enum PrivateFieldsAuthenticationPurpose {
    case revealPrivateFields
    case transmitPrivatePhoneByShortCode

    var localizedReason: String {
        switch self {
        case .revealPrivateFields:
            return "Открыть закрытые поля визитки"
        case .transmitPrivatePhoneByShortCode:
            return "Подтвердить передачу телефона по короткому коду"
        }
    }
}

final class PermissionCenter: NSObject, CLLocationManagerDelegate {
    private let contactStore = CNContactStore()
    private let contactQueue = DispatchQueue(label: "app.yperson.contacts-reconciliation")
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

    func reconciliation(
        for card: PersonCard,
        scope: ContactReconciliationScope,
        choosing candidateIdentifier: String? = nil,
        completion: @escaping (Result<ContactReconciliationResult, Error>) -> Void
    ) {
        let cardProjection = projection(from: card)
        contactQueue.async { [weak self] in
            guard let self else { return }
            let result = Result {
                try ContactReconciliationPlanner.reconcile(
                    card: cardProjection,
                    contacts: try self.contactProjections(),
                    scope: scope,
                    choosing: candidateIdentifier
                )
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func apply(
        _ plan: ContactReconciliationPlan,
        for card: PersonCard,
        session: ContactReconciliationSessionFence.Session,
        sessionFence: ContactReconciliationSessionFence,
        completion: @escaping (Result<ContactReconciliationAction, Error>) -> Void
    ) {
        let cardProjection = projection(from: card)
        contactQueue.async { [weak self] in
            guard let self else { return }
            let result = Result<ContactReconciliationAction, Error> {
                let currentScope = try self.currentContactScope()
                let contacts = try self.contactProjections()
                try ContactReconciliationPlanner.validate(
                    plan,
                    card: cardProjection,
                    contacts: contacts,
                    currentScope: currentScope
                )

                let request = CNSaveRequest()
                switch plan.action {
                case .add:
                    request.add(self.makeContact(card), toContainerWithIdentifier: nil)
                case .update:
                    guard let identifier = plan.candidate?.identifier else {
                        throw ContactReconciliationPlannerError.invalidCandidate
                    }
                    let contact = try self.contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: self.contactKeys)
                    guard self.projection(from: contact) == plan.baseline else {
                        throw ContactReconciliationPlannerError.stalePlan
                    }
                    guard let mutableContact = contact.mutableCopy() as? CNMutableContact else {
                        throw NSError(domain: "YPerson.Contacts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить контакт к обновлению."])
                    }
                    self.apply(card, to: mutableContact)
                    request.update(mutableContact)
                case .noChange:
                    return .noChange
                }
                try sessionFence.performCommit(for: session) {
                    try self.contactStore.execute(request)
                }
                return plan.action
            }
            DispatchQueue.main.async { completion(result) }
        }
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

    private func currentContactScope() throws -> ContactReconciliationScope {
        switch contactsState() {
        case .authorized:
            return .complete
        case .limited:
            return .limited
        default:
            throw ContactReconciliationPlannerError.stalePlan
        }
    }

    private func contactProjections() throws -> [ContactProjection] {
        let request = CNContactFetchRequest(keysToFetch: contactKeys)
        var contacts: [ContactProjection] = []
        try contactStore.enumerateContacts(with: request) { [weak self] contact, _ in
            guard let self else { return }
            contacts.append(self.projection(from: contact))
        }
        return contacts
    }

    private func projection(from card: PersonCard) -> ContactCardProjection {
        ContactCardProjection(name: card.name, company: card.company, role: card.role, phone: card.phone, email: card.email)
    }

    private func projection(from contact: CNContact) -> ContactProjection {
        ContactProjection(
            identifier: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            company: contact.organizationName,
            role: contact.jobTitle,
            phones: contact.phoneNumbers.map { $0.value.stringValue },
            emails: contact.emailAddresses.map { $0.value as String }
        )
    }

    private func apply(_ card: PersonCard, to contact: CNMutableContact) {
        let current = projection(from: contact)
        let projected = ContactReconciliationPlanner.projectedContact(applying: projection(from: card), to: current)
        contact.givenName = projected.givenName
        contact.familyName = projected.familyName
        contact.organizationName = projected.company
        contact.jobTitle = projected.role
        if projected.phones.count > current.phones.count, let phone = projected.phones.last {
            contact.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone)))
        }
        if projected.emails.count > current.emails.count, let email = projected.emails.last {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelWork, value: email as NSString))
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

    func authenticatePrivateFields(
        for purpose: PrivateFieldsAuthenticationPurpose,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let context = LAContext()
        context.localizedCancelTitle = "Оставить закрытым"
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            let evaluationError = error ?? NSError(domain: "YPerson.LocalAuthentication", code: 1)
            DispatchQueue.main.async { completion(.failure(evaluationError)) }
            return
        }
        context.evaluatePolicy(policy, localizedReason: purpose.localizedReason) { success, error in
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
