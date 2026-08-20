# YPerson — отчёт проверки реализации

## Результат

Статус: `implementation-verified`, но не `release-ready`.

Реализация соответствует утверждённому MVP в пределах проверяемого локально: iPhone-only, portrait-only, minimum iOS 15.0, программный UIKit, S1–S8, десять permission-путей с предварительным объяснением, WidgetKit, две notification extensions, consent-aware AppMetrica 6.5.0 и backend с обязательным публичным `GET /config`.

Отдельный release-stage не начат. Подписание, production credentials/URLs, реальные устройства, APNs, privacy report подписанного архива и App Store Connect остаются в `manual-device-checks.md` и `release-manifest.json`.

## Свежая проверка сборки

Инструменты:

- Xcode 26.5 (17F42), Swift 6.3.2 в Swift 5 language mode.
- XcodeGen 2.46.0.
- Python 3.12.14; FastAPI 0.141.1, SQLAlchemy 2.0.52, Alembic 1.19.1, psycopg 3.3.4 и Uvicorn 0.52.3 — версии из `backend/pyproject.toml`/locked environment.
- AppMetrica exact 6.5.0, resolved revision `bac143d2d8a6d427fd901e27bdccb6fc79d02889`; KSCrash 2.5.1 и SwiftProtobuf 1.38.1 разрешены транзитивно.

Проверено:

- `xcodegen generate` повторно сгенерировал общий проект без diff. Debug и Release собраны общей схемой `YPerson` для generic iOS Simulator с `CODE_SIGNING_ALLOWED=NO`; предупреждения Swift/Clang настроены как ошибки. Полная Debug-сборка завершилась `BUILD SUCCEEDED` за 39.978 s, после исправления только shell-wrapper подтверждающий повтор завершился с exit 0 за 5.18 s (2026-08-18T12:07:30Z). Release завершился с exit 0 за 42.91 s (2026-08-18T12:08:26Z). Для sandbox использованы worktree-local DerivedData/module/SwiftPM cache paths и существующий resolved SourcePackages checkout с `-disableAutomaticPackageResolution`; product settings, общий scheme, iOS 15 target и endpoint models не менялись.
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

Backend реализован в `backend/app/main.py` и `backend/app/storage.py`; миграция `backend/migrations/versions/20260818_0001_initial.py` создаёт PostgreSQL persistence. Реализованный iOS wire format остаётся camelCase subset (`installationID`, `bearer`, `apnsToken`, `operation`, `card`, `exchangeToken`, `moderationCategory`); это не означает, что более широкий product-level snake_case inventory уже принят как API. Его расширение требует versioning, iOS changes, privacy reconciliation, tests и renewed approval.

Локальный Uvicorn smoke повторно проверен на `127.0.0.1:58080` с изолированным PostgreSQL:

| Проверка | Результат |
|---|---:|
| `GET /health` | 200 |
| `GET /config` | 200 + stable ETag |
| `GET /config` с `If-None-Match` | 304 |
| валидный `POST /sync` | 200 |
| новый installation ID в `POST /sync` | `updateCount: 0` |
| поле `preciseLocation` в `/sync` | 400 |
| неизвестный путь | 404 |
| неверный метод `POST /config` | 405 + `Allow: GET` |
| тело 65,537 bytes | 413 |
| `text/plain` для `/sync` | 415 |
| безопасно индуцированная внутренняя ошибка | 500, generic body |
| недоступная БД в изолированном app instance | 503 |

`/config` не принимает PII и содержит только version/minimum contract, maintenance, три feature flags, display-only sponsored templates, privacy/support URLs, moderation categories и analytics kill switch. Клиент отклоняет неизвестные top-level, feature и template keys, использует ETag и last-known-good cache.

2026-08-18T12:10:27Z полная проверка против нового disposable UTF-8 PostgreSQL 17.11 cluster на порту 55433: `alembic upgrade head` и `alembic current` вернули `20260818_0001 (head)`; `pytest -q` — 67 passed, 1 существующее FastAPI TestClient deprecation warning за 2.29 s; Ruff check прошёл, format check — 19 files already formatted; `alembic downgrade base` и повторный upgrade завершились успешно. Live Uvicorn matrix покрыл 200/304/400/404/405/413/415; отдельные безопасные TestClient probes подтвердили sanitized 500, controlled 503, уникальные UUID `X-Request-ID` и `public, max-age=60` только для `/config`, `no-store` для остальных ответов. Карточка и APNs token сохранились в PostgreSQL после остановки и запуска только API process; direct row readback подтвердил оба значения. Два SIGTERM завершили Uvicorn за 0.236 s и 0.176 s, существенно ниже 15-second budget. Contract/storage suites подтвердили transactional persistence и profile deletion. Raw exchange token не сохраняется: в PostgreSQL хранится только SHA-256 hash, срок — ровно десять минут. Docker Compose configuration parsed; Docker client 29.7.2 найден, но daemon socket отсутствует, поэтому image build/run, container UID, live container health и container restart persistence не заявляются.

Installed skill mutation suite прошёл 11/11; custom `validate_skill.py` вернул `Skill validation passed`, system `quick_validate.py` — `Skill is valid!`. Все JSON в `Release/`, а также `AppPrivacy.yml`, `project.yml` и `backend/compose.yaml` повторно разобраны; manifest сохранил `implementation-verified` и `releaseReady = false`.

## Статический аудит

- Storyboard/XIB и test targets/files отсутствуют по выбранному build-контракту.
- `URLSession.shared`, app-owned singleton, mutable global/static state, NotificationCenter/KVO/Combine observers не обнаружены.
- AppMetrica импортируется только основным приложением; widget и notification extensions его не активируют.
- Виджет — stateless launcher для `yperson://scan`: он не читает карточку или snapshot, не имеет App Group entitlement, camera purpose string, доступа к камере, аналитики или сетевого клиента. Основное приложение сохраняет собственный App Group entitlement и `NSCameraUsageDescription`, потому что app-owned storage и сканирование выполняются только после открытия приложения и явного действия пользователя.
- Notification service проверяет card ID и Curve25519 signature, принимает только HTTPS public avatar с лимитом 1 MB/коротким timeout, удаляет technical exchange token и всегда имеет fallback. Пустой placeholder public key означает fail-safe original notification до release configuration.

2026-08-20 финальная scanner-widget проверка: route и launch-gate harnesses прошли; неподписанная Debug-сборка полного приложения для Generic iOS Simulator завершилась `BUILD SUCCEEDED`. В собранном `YPersonWidget.appex` нет camera/App Group keys, build settings не задают `CODE_SIGN_ENTITLEMENTS` или `APP_GROUP_IDENTIFIER`, privacy manifest не объявляет collected data, tracking или accessed APIs, а source scan не нашёл `AVFoundation`, `URLSession`, `UserDefaults`, `WidgetSnapshot` или `APP_GROUP_IDENTIFIER`. На iPhone 16 Pro Simulator с iOS 18.5 warm и cold `yperson://scan` после системного подтверждения custom scheme визуально выбрали «Обмен» и показали существующее объяснение камеры; повторный warm link оставил тот же единственный alert. Это подтверждает симуляторный route/presentation path, но не работу реальной камеры, signed entitlements, Lock Screen placement или полный набор camera permission states.

## Невыполненные внешние проверки

Физическое оборудование, реальный iOS 15 runtime/device, подписанный App Group entitlement основного приложения и его отсутствие у widget extension, реальная камера, размещение Lock Screen widget, все camera permission states, production AppMetrica traffic, APNs и signed notification enrichment нельзя честно подтвердить симуляторной неподписанной сборкой. Кроме того, production authentication, managed backups/restore, TLS/domain, hosting jurisdiction, processor terms, monitoring и moderation operations не подтверждены. Полный список находится в `manual-device-checks.md`; эти пункты и production placeholders удерживают `releaseReady = false`.
