import UIKit

final class CardEditorViewController: YPBaseViewController {
    private let existingCard: PersonCard?
    private let permissions: PermissionCenter
    private let audio: AudioGreetingController
    private let makeAppearance: (
        PersonCard,
        String,
        @escaping (String) -> Void
    ) -> UIViewController
    private let onSave: (PersonCard) -> Void
    private var selectedTemplateID: String
    private let nameField = CardEditorViewController.makeField(placeholder: "Имя и фамилия")
    private let roleField = CardEditorViewController.makeField(placeholder: "Роль")
    private let companyField = CardEditorViewController.makeField(placeholder: "Компания")
    private let emailField = CardEditorViewController.makeField(placeholder: "Email", keyboardType: .emailAddress)
    private let phoneField = CardEditorViewController.makeField(placeholder: "Телефон", keyboardType: .phonePad)
    private let privateFieldsStack = YPStyle.stack(spacing: 8)
    private let privateAccessStatus = YPStyle.label("Доступ открыт до закрытия этого экрана", style: .footnote, weight: .semibold)
    private let unlockButton = YPStyle.button("Открыть с Face ID", symbol: "faceid")
    private let audioStatus = YPStyle.label("Не записано", style: .footnote)
    private let audioAction = YPStyle.button("Записать до 10 секунд", symbol: "mic.fill", primary: true)
    private let audioSecondary = YPStyle.button("Воспроизвести / остановить", symbol: "play.fill")
    private let audioSave = YPStyle.button("Сохранить запись", symbol: "checkmark")

    init(card: PersonCard?, permissions: PermissionCenter, audio: AudioGreetingController, makeAppearance: @escaping (PersonCard, String, @escaping (String) -> Void) -> UIViewController, onSave: @escaping (PersonCard) -> Void) {
        self.existingCard = card
        self.permissions = permissions
        self.audio = audio
        self.makeAppearance = makeAppearance
        self.onSave = onSave
        self.selectedTemplateID = CardTemplateCatalog.resolve(card?.templateID).id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Изменить"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Готово", style: .done, target: self, action: #selector(done))
        sectionTitle("Публичные поля")
        nameField.text = existingCard?.name
        roleField.text = existingCard?.role
        companyField.text = existingCard?.company
        emailField.text = existingCard?.email
        [nameField, roleField, companyField, emailField].forEach(contentStack.addArrangedSubview)
        sectionTitle("Закрытые поля")
        unlockButton.addTarget(self, action: #selector(unlock), for: .touchUpInside)
        contentStack.addArrangedSubview(unlockButton)
        phoneField.textContentType = .telephoneNumber
        phoneField.accessibilityLabel = "Закрытый телефон"
        privateFieldsStack.addArrangedSubview(privateAccessStatus)
        privateFieldsStack.addArrangedSubview(phoneField)
        privateFieldsStack.isHidden = true
        contentStack.addArrangedSubview(privateFieldsStack)
        sectionTitle("Аудиоприветствие")
        contentStack.addArrangedSubview(audioStatus)
        audioAction.addTarget(self, action: #selector(recordOrStop), for: .touchUpInside); contentStack.addArrangedSubview(audioAction)
        audioSecondary.addTarget(self, action: #selector(playOrDelete), for: .touchUpInside); contentStack.addArrangedSubview(audioSecondary)
        audioSave.addTarget(self, action: #selector(saveAudio), for: .touchUpInside); contentStack.addArrangedSubview(audioSave)
        let appearance = YPStyle.button("Оформление и шаблоны", symbol: "paintpalette"); appearance.addTarget(self, action: #selector(openAppearance), for: .touchUpInside); contentStack.addArrangedSubview(appearance)
        audio.onStateChange = { [weak self] state in self?.renderAudio(state) }
        renderAudio(audio.state)
    }

    @objc private func done() {
        let name = trimmed(nameField)
        guard !name.isEmpty else {
            showMessage("Добавьте имя", "Имя нужно, чтобы создать цифровую визитку.")
            return
        }
        let card = makeCard(name: name)
        onSave(card)
        navigationController?.popViewController(animated: true)
    }

    private func makeCard(name: String) -> PersonCard {
        PersonCard(
            id: existingCard?.id ?? UUID().uuidString.lowercased(),
            name: name,
            role: trimmed(roleField),
            company: trimmed(companyField),
            phone: privateFieldsStack.isHidden ? (existingCard?.phone ?? "") : trimmed(phoneField),
            email: trimmed(emailField),
            tagline: existingCard?.tagline ?? "",
            hasAudioGreeting: audio.state != .empty,
            meetingPlace: existingCard?.meetingPlace,
            isBlocked: existingCard?.isBlocked ?? false,
            templateID: selectedTemplateID
        )
    }
    @objc private func openAppearance() {
        let name = trimmed(nameField)
        let previewCard = makeCard(name: name.isEmpty ? "Ваша визитка" : name)
        navigationController?.pushViewController(
            makeAppearance(previewCard, selectedTemplateID) { [weak self] templateID in
                self?.selectedTemplateID = templateID
            },
            animated: true
        )
    }
    @objc private func unlock() {
        explainPermission(title: "Закрытые поля", message: "Face ID защищает закрытые поля вашей визитки и подтверждает их передачу выбранному человеку.") { [weak self] in
            self?.permissions.authenticatePrivateFields { result in
                guard let self else { return }
                if case .success = result {
                    self.phoneField.text = self.existingCard?.phone
                    self.unlockButton.isHidden = true
                    self.privateFieldsStack.isHidden = false
                    UIAccessibility.post(notification: .screenChanged, argument: self.phoneField)
                } else {
                    self.showMessage("Поля остались закрыты", "Используйте публичные поля или повторите позже.")
                }
            }
        }
    }

    @objc private func recordOrStop() {
        if audio.state == .recording { audio.stopRecording() }
        else { explainPermission(title: "Аудиоприветствие", message: "Микрофон нужен, чтобы записать короткое аудиоприветствие для вашей визитки YPerson.") { [weak self] in self?.audio.requestAndRecord() } }
    }

    @objc private func playOrDelete() {
        switch audio.state {
        case .preview: audio.play()
        case .playing: audio.stopPlayback()
        case .saved: confirmDelete()
        default: break
        }
    }

    @objc private func saveAudio() {
        let alert = UIAlertController(title: "Где использовать аудиоприветствие?", message: "Публичную запись получат подтверждённые получатели обычной карточки. Закрытая запись передаётся только после Face ID.", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "В публичной карточке", style: .default) { [weak self] _ in self?.audio.save(isPublic: true) })
        alert.addAction(UIAlertAction(title: "Только в закрытой карточке", style: .default) { [weak self] _ in self?.audio.save(isPublic: false) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }

    private func renderAudio(_ state: AudioGreetingController.State) {
        switch state {
        case .empty: audioStatus.text = "Не записано · используйте текстовое описание"; audioAction.configuration?.title = "Записать до 10 секунд"; audioSecondary.isHidden = true; audioSave.isHidden = true
        case .recording: audioStatus.text = "● Идёт запись · максимум 10 секунд"; audioAction.configuration?.title = "Остановить"; audioSecondary.isHidden = true; audioSave.isHidden = true; UIAccessibility.post(notification: .announcement, argument: "Запись началась")
        case .preview(let duration): audioStatus.text = String(format: "Предпросмотр · %.0f секунд", duration); audioAction.configuration?.title = "Перезаписать"; audioSecondary.configuration?.title = "Воспроизвести"; audioSecondary.isHidden = false; audioSave.isHidden = false
        case .playing(let duration): audioStatus.text = String(format: "Воспроизведение · %.0f секунд", duration); audioSecondary.configuration?.title = "Остановить"; audioSecondary.isHidden = false; audioSave.isHidden = true
        case .saved(let isPublic, let duration): audioStatus.text = String(format: "%@ · %.0f секунд", isPublic ? "Опубликовано" : "Только закрытая карточка", duration); audioAction.configuration?.title = "Перезаписать"; audioSecondary.configuration?.title = "Удалить"; audioSecondary.isHidden = false; audioSave.isHidden = true
        }
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: "Удалить аудиоприветствие?", message: "Запись исчезнет из карточки и будет удалена локально.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.audio.delete() }); alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func trimmed(_ field: UITextField) -> String {
        field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func makeField(placeholder: String, keyboardType: UIKeyboardType = .default) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.keyboardType = keyboardType
        field.autocapitalizationType = keyboardType == .emailAddress ? .none : .sentences
        field.autocorrectionType = keyboardType == .emailAddress ? .no : .default
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        return field
    }
}
