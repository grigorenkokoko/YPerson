# YPerson — отчёт проверки реализации

## Статус

Статус остаётся `implementation-verified`, но не `archive-validated` и не `release-ready`.

Финальный локальный integration gate записан `2026-08-21T16:26:13Z` на точном baseline `eae256521846bcb1f543d1b16bc21e578d854565`. `Release/release-manifest.json` сохраняет `releaseReady: false`; внешние и физические проверки ниже остаются `PENDING`.

Локально реализованы iOS-клиент, installation-authenticated sync v2, YDB Serverless adapter и schema, приватный Object Storage для аудиоприветствий, публичный обмен QR/Bluetooth, recipient-specific телефон через ручной код, локальное хранение людей и полный путь удаления профиля. Эта запись не является доказательством внешней выкладки: применение YDB schema, создание private bucket/Lockbox, новая ревизия Serverless Container и маршрутизация API Gateway проверяются отдельно в deployment-задаче.

## Финальный локальный integration gate

- Backend: Python `3.12.14`; полный `pytest -q backend/tests` завершился exit `0` с результатом `274 passed, 1 warning in 11.27s`. Единственное предупреждение — существующий `StarletteDeprecationWarning` о связке Starlette TestClient/httpx.
- Ruff `0.16.3`: `ruff check backend/app backend/tests` завершился exit `0` с `All checks passed!`; `ruff format --check backend/app backend/tests` завершился exit `0` с `25 files already formatted`.
- Репозиторный `Verification/HonestExchangeContract/run.sh` завершился exit `0` с маркерами `honest-exchange-contract-v9-pass`, `honest-exchange-source-contracts-pass` и `honest-exchange-lifecycle-order-pass`.
- Отдельный запуск lifecycle verifier с `PYTHONOPTIMIZE=1` завершился exit `0` с `honest-exchange-lifecycle-order-pass`, поэтому gate не зависит от Python `assert`.
- Свежая Debug-сборка для `generic/platform=iOS Simulator`, `arm64`, без signing, с `clean build` в `/tmp/yperson-honest-exchange-eae25652-1621-debug` завершилась exit `0`.
- Свежая Release-сборка для того же generic arm64 Simulator, без signing, с `clean build` и выключенным автоматическим package resolution в `/tmp/yperson-honest-exchange-eae25652-1623-release-final` завершилась явным exit `0`.
- В обеих конфигурациях присутствуют `YPerson.app`, `YPersonWidget.appex`, `YPersonNotificationService.appex` и `YPersonNotificationContent.appex`; каждый из четырёх executable отдельно определён как `Mach-O 64-bit executable arm64`.
- Xcode toolchain: Xcode `26.5` (`17F42`).
- Положительный privacy/source scan подтвердил все пять контрактных терминов: `exchangeCode=75`, `exchangeExpiresAt=37`, `privateFields=58`, `connection_private_fields=20`, `exchange_private_fields=35`.
- Fail-closed source/manual-code scan перечислил `44` shipping-source файла и вернул raw status `1` для отсутствия obsolete `YP-1234` и клиентского десятиминутного expiry expression. Status `0` или больше `1` считается ошибкой gate.
- Reviewer QR verifier через production Swift models и локальный compatible ZXing Core jar подтвердил точный `578`-byte offline public payload в PNG `808x808`; SHA-256 PNG: `7a5114756228a495ed58d50c28da5ca7150fe86c3ec2d3a4aa7d1c8743690bb7`.
- Fail-closed binary sentinel scan проверил полный Release app bundle и все три extension executables; raw no-match status был ровно `1` для screenshot/fixture markers, fixture identities, sentinel credentials и obsolete manual codes.
- Source privacy manifest и все `25` privacy manifests внутри собранного Release app bundle прошли `plutil -lint`.
- Все tracked конфигурации разобраны: `9` JSON и `5` YAML. Дополнительно подтверждены `implementationStatus: implementation-verified` и неизменённые `releaseReady/release_ready: false`.
- До evidence-изменений `git diff --check`, `git diff --check origin/main...HEAD` и чистый `git status --short` прошли. Полный evidence-only diff и post-commit status проверяются повторно перед завершением gate.

Подробные команды, точные build paths и fail-closed контракты записаны в `Release/honest-exchange-verification.md`.

## Локально подтверждённые контракты

- Backend принимает строгий camelCase sync v2; installation аутентифицируется секретом из Keychain, а YDB хранит SHA-256 секрета и токенов обмена.
- Публичный `card`, сохранённый `cards.card_json` и QR-проекция исключают телефон и локальный `meetingPlace`. `privateFields` принимается только для manual prepare; QR, photo и Bluetooth используют public-only путь.
- Manual prepare выдаёт runtime `YP-XXXX-XXXX-XXXX` из 12 символов Crockford Base32. Claim аутентифицирован, одноразовый, запрещает self-claim и привязывает private phone только к directional grant получателя.
- Публикация аудио проходит prepare → signed PUT → HEAD-проверка → card publication. Draft не становится public до успешного durable card save; recovery сохраняет инвариант карточки и asset.
- Удаление профиля использует стабильный Codable deletion record и сохраняет его до локальной очистки. Bootstrap повторяет только неподтверждённое сервером удаление; backend replay/recovery остаются credential-bound и fail-closed.
- Репозиторный v9 runner покрывает public/private projection, manual-code normalization, credential routing, QR/Bluetooth policy, crash-safe persistence и deletion recovery, Contacts/media commit barriers, audio publication recovery, APNs ownership, scanner launch, lifecycle transitions и ordered async source contracts.
- QR scanner widget остаётся stateless-ярлыком `yperson://scan`; камера, сеть и персональные данные остаются в основном приложении.

## Device, live-service и external PENDING

- Физические Face ID/device-passcode success/cancel/lockout сценарии не проверены.
- Runtime manual-code display, normalized entry, one-time claim, cancellation и реальный server expiry требуют двух установок на физических устройствах.
- Двусторонний публичный Bluetooth-обмен с независимым локальным claim на каждом iPhone, отмена и восстановление после background требуют двух физических iPhone. Private Bluetooth не заявляется до recipient-bound mutual pairing.
- Реальная камера, Contacts UI, location, microphone, PhotoKit, ATT, APNs, notification extensions, виджеты, clipboard, VoiceOver, Dynamic Type и iOS 15 остаются в `Release/manual-device-checks.md`.
- Live preview шаблонов, все четыре палитры в light/dark, отмена editor draft, save/relaunch, received-card rendering, exported/shared image и ATT-denied availability остаются ручными проверками.
- Signed entitlements, размещение widget на Lock Screen, физическое crash termination, Contacts system UI timing и реальный APNs ordering не подтверждены локальным simulator gate.
- Новая YDB/Object Storage версия ещё не выкачена и не проверена через внешний API Gateway URL; live schema, bucket/Lockbox/IAM, monitoring и backup/restore остаются `PENDING`.
- Политика backup/restore и срок удаления резервных копий до 30 дней требуют подтверждения фактической Yandex Cloud конфигурацией.
- Production APNs, AppMetrica traffic, public privacy/support endpoints, Apple signing/App Groups/provisioning, signed archive, archive privacy report и App Store Connect не проверены.
- Сохраняются release blockers по conformance сторонних vCard, recipient-specific private-audio persistence, connection-level private-grant revoke/update/propagation последующих изменений телефона, production operations и owner-supplied review metadata.

Полный список ручных проверок находится в `Release/manual-device-checks.md`; `Release/release-manifest.json` сохраняет `releaseReady: false`.
