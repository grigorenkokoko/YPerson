# YPerson — отчёт проверки реализации

## Результат

Статус: `implementation-verified`, но не `release-ready`.

Реализация соответствует утверждённому MVP в пределах проверяемого локально: iPhone-only, portrait-only, minimum iOS 15.0, программный UIKit, S1–S8, десять permission-путей с предварительным объяснением, WidgetKit, две notification extensions, consent-aware AppMetrica 6.5.0 и backend с обязательным публичным `GET /config`.

Отдельный release-stage не начат. Подписание, production credentials/URLs, реальные устройства, APNs, privacy report подписанного архива и App Store Connect остаются в `manual-device-checks.md` и `release-manifest.json`.

## Свежая проверка сборки

Инструменты:

- Xcode 26.5 (17F42), Swift 6.3.2 в Swift 5 language mode.
- XcodeGen 2.46.0.
- Node.js 25.4.0 без backend-зависимостей.
- AppMetrica exact 6.5.0, resolved revision `bac143d2d8a6d427fd901e27bdccb6fc79d02889`; KSCrash 2.5.1 и SwiftProtobuf 1.38.1 разрешены транзитивно.

Проверено:

- Debug и Release собраны общей схемой `YPerson` для generic iOS Simulator с `CODE_SIGNING_ALLOWED=NO`; предупреждения Swift/Clang настроены как ошибки, обе команды завершились с exit code 0.
- Главный продукт и три embedded extensions присутствуют в Release app bundle.
- Обработанные Info.plist всех четырёх продуктов содержат minimum OS `15.0`, `UIDeviceFamily = [1]` и ожидаемые bundle identifiers.
- Release URL: `https://api.example.invalid`; privacy/support URL корректно сохраняют полный `https://...` и остаются явными release blockers.
- Девять системных purpose strings побайтно совпадают с `AppPrivacy.yml`; push pre-prompt также совпадает с утверждённым текстом.
- App icon: PNG 1024×1024, RGB, без alpha.
- Все четыре owned privacy manifests валидны; основной манифест декларирует 12 app-owned collected data types, AppMetrica/KSCrash manifests присутствуют в собранном bundle.

## Интерфейс и доступность

YPerson установлен и запущен на iPhone 16 Pro Simulator с iOS 18.5. Сохранены S1–S8, тёмная тема, увеличенный Dynamic Type, камера-предэкран и полный диалог удаления профиля. Accessibility dump включает заголовки, объяснения и действия alert.

Дополнительно проверено разделение первоначального и reviewer-состояния: после удаления приложения и контейнера Release открывает экран `Создайте цифровую визитку` без профиля, людей, счётчиков и sync claims. Обычный Debug-запуск показывает то же состояние. Только отдельный Debug-запуск с `YP_SCREENSHOT_STATE=S1` показывает fixture-карточку Анны; fixture identities и symbols в Release binary отсутствуют, а reviewer mode не сохраняет их как пользовательские данные.

Основные свидетельства:

- `evidence/S1-card.png` — собственная карточка.
- `evidence/S2.png` — пять способов обмена и закрытые поля.
- `evidence/S3.png`, `evidence/S4.png` — люди, обновления, контекст знакомства и safety menu.
- `evidence/S5.png`, `evidence/S5-accessibility.png` — редактор и крупный текст.
- `evidence/S6.png` — оформление и отдельный ATT-триггер.
- `evidence/S7.png`, `evidence/S7-dark.png` — privacy/permissions/analytics в обеих темах.
- `evidence/S7-delete-confirmation.png`, `evidence/S7-delete-accessibility.txt` — полный scope удаления и retention.
- `evidence/S8-updated.png`, `evidence/S8-accessibility.txt` — контекстный camera pre-prompt и доступные действия.

## Разрешения и privacy

- Системные запросы не выполняются при запуске; каждый начинается после утверждённой кнопки и pre-prompt.
- Bluetooth использует instance-owned central/peripheral managers, короткий rotating token, остановку ресурсов и явное подтверждение до `/sync` claim.
- QR принимает только `yperson:` или vCard; raw camera frames не сохраняются.
- Contacts reconciliation локальный и требует подтверждения; системная форма одного контакта остаётся fallback без чтения всей книги.
- Location переводится в человекочитаемую подпись и не включена в сетевую модель; при ошибке доступен ручной ввод.
- Аудио поддерживает record/stop/preview/play/stop/public-or-private save/replace/delete.
- Photo scan ограничен 60 доступными изображениями, не загружает iCloud originals, подтверждает импорт и предлагает PHPicker одного изображения/limited-access manager.
- ATT отделён от analytics consent. AppMetrica не активируется без согласия и валидного key, location tracking выключен, IDFA зависит от ATT, remote `/config` kill switch останавливает отправку, custom events не содержат чувствительных значений.
- Account deletion сразу очищает local App Group data и аудио, выключает analytics, отправляет серверное удаление и сохраняет pending retry при offline.
- Main privacy manifest описывает app-owned off-device data. System Contacts, raw camera/photos, precise meeting location и Face ID остаются local-only и не декларируются как collected by YPerson.

## Backend

Backend повторно проверен на `127.0.0.1:8080`:

| Проверка | Результат |
|---|---:|
| `GET /health` | 200 |
| `GET /config` | 200 + stable ETag |
| `GET /config` с `If-None-Match` | 304 |
| валидный `POST /sync` | 200 |
| новый installation ID в `POST /sync` | `updateCount: 0` |
| поле `preciseLocation` в `/sync` | 400 |
| неизвестный путь | 404 |
| moderation category `spam` | 200 |
| подтверждённый 8-символьный exchange claim | 200 |

`/config` не принимает PII и содержит только version/minimum contract, maintenance, три feature flags, display-only sponsored templates, privacy/support URLs, moderation categories и analytics kill switch. Клиент отклоняет неизвестные top-level, feature и template keys, использует ETag и last-known-good cache.

## Статический аудит

- Storyboard/XIB и test targets/files отсутствуют по выбранному build-контракту.
- `URLSession.shared`, app-owned singleton, mutable global/static state, NotificationCenter/KVO/Combine observers не обнаружены.
- AppMetrica импортируется только основным приложением; widget и notification extensions его не активируют.
- Виджет читает только компактный App Group snapshot и не отображает QR, контакты или закрытые поля.
- Notification service проверяет card ID и Curve25519 signature, принимает только HTTPS public avatar с лимитом 1 MB/коротким timeout, удаляет technical exchange token и всегда имеет fallback. Пустой placeholder public key означает fail-safe original notification до release configuration.

## Невыполненные внешние проверки

Физическое оборудование, реальный iOS 15 runtime/device, signing/App Groups, production AppMetrica traffic, APNs и signed notification enrichment нельзя честно подтвердить симуляторной неподписанной сборкой. Полный список находится в `manual-device-checks.md`; эти пункты и production placeholders удерживают `releaseReady = false`.
