import UIKit

final class CardEditorViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let audio: AudioGreetingController
    private let makeAppearance: () -> UIViewController
    private let audioStatus = YPStyle.label("Не записано", style: .footnote)
    private let audioAction = YPStyle.button("Записать до 10 секунд", symbol: "mic.fill", primary: true)
    private let audioSecondary = YPStyle.button("Воспроизвести / остановить", symbol: "play.fill")
    private let audioSave = YPStyle.button("Сохранить запись", symbol: "checkmark")

    init(permissions: PermissionCenter, audio: AudioGreetingController, makeAppearance: @escaping () -> UIViewController) {
        self.permissions = permissions; self.audio = audio; self.makeAppearance = makeAppearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Изменить"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Готово", style: .done, target: self, action: #selector(done))
        sectionTitle("Публичные поля")
        ["Анна Смирнова", "Product Designer", "YPerson Studio", "hello@example.com"].forEach { value in
            let field = UITextField(); field.text = value; field.borderStyle = .roundedRect; field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true; field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true; contentStack.addArrangedSubview(field)
        }
        sectionTitle("Закрытые поля")
        let unlockButton = YPStyle.button("Открыть с Face ID", symbol: "faceid"); unlockButton.addTarget(self, action: #selector(unlock), for: .touchUpInside); contentStack.addArrangedSubview(unlockButton)
        sectionTitle("Аудиоприветствие")
        contentStack.addArrangedSubview(audioStatus)
        audioAction.addTarget(self, action: #selector(recordOrStop), for: .touchUpInside); contentStack.addArrangedSubview(audioAction)
        audioSecondary.addTarget(self, action: #selector(playOrDelete), for: .touchUpInside); contentStack.addArrangedSubview(audioSecondary)
        audioSave.addTarget(self, action: #selector(saveAudio), for: .touchUpInside); contentStack.addArrangedSubview(audioSave)
        let appearance = YPStyle.button("Оформление и шаблоны", symbol: "paintpalette"); appearance.addTarget(self, action: #selector(openAppearance), for: .touchUpInside); contentStack.addArrangedSubview(appearance)
        audio.onStateChange = { [weak self] state in self?.renderAudio(state) }
        renderAudio(audio.state)
    }

    @objc private func done() { navigationController?.popViewController(animated: true) }
    @objc private func openAppearance() { navigationController?.pushViewController(makeAppearance(), animated: true) }
    @objc private func unlock() { explainPermission(title: "Закрытые поля", message: "Face ID защищает закрытые поля вашей визитки и подтверждает их передачу выбранному человеку.") { [weak self] in self?.permissions.authenticatePrivateFields { result in self?.showMessage((try? result.get()) == nil ? "Остались закрыты" : "Поля открыты", (try? result.get()) == nil ? "Используйте публичные поля или повторите позже." : "Телефон доступен до закрытия этого экрана.") } } }

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
}
