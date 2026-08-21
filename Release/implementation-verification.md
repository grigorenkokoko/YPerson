# YPerson — отчёт проверки реализации

## Статус

Статус остаётся `implementation-verified`, но не `archive-validated` и не `release-ready`.

Локально реализованы iOS-клиент, installation-authenticated sync v2, YDB Serverless adapter и schema, приватный Object Storage для аудиоприветствий, обмен QR/Bluetooth, локальное хранение людей и полный путь удаления профиля. Эта запись не является доказательством внешней выкладки: применение YDB schema, создание private bucket/Lockbox, новая ревизия Serverless Container и маршрутизация API Gateway проверяются отдельно в deployment-задаче.

## Локально проверено

- Backend на Python 3.12/FastAPI принимает только строгий camelCase sync v2; установка аутентифицируется секретом из Keychain, а YDB хранит только SHA-256 секрета и токенов обмена.
- YDB adapter хранит карточки, подтверждённые связи, APNs-токены, краткоживущие exchange claims, moderation state и метаданные аудио. Private Object Storage хранит только `.m4a`; подписанные PUT/GET действуют 300 секунд и не сохраняются на iPhone.
- Публикация аудио проходит prepare → signed PUT → HEAD-проверка размера/MIME → публикация карточки. Получатель загружает аудио только после нажатия; кэш очищается при изменении/отзыве карточки, блокировке и удалении профиля.
- Удаление профиля транзакционно удаляет карточку, APNs-токен, связи, claims, installation credential и media metadata, затем идемпотентно удаляет Object Storage keys. Повтор того же `operationID` возвращает то же подтверждение без создания новой установки.
- На iOS запрос удаления хранится до подтверждения сервера. После подтверждения очищены карточка, люди, legacy widget snapshot keys, sync cursor/pending payloads, analytics consent, аудиофайлы/кэш и Keychain credential; автоматический bootstrap остаётся запрещён до явного создания новой карточки.
- Публичные `/privacy` и `/support` описывают фактически реализованные данные, путь удаления и сроки, но прямо отмечают отсутствие внешней проверки этой версии.
- Финальная интегрированная проверка 2026-08-21T06:06:34Z: `/Users/grigornkokoko/YPerson/backend/.venv/bin/pytest -q backend/tests` завершилась с результатом `146 passed, 1 warning` за 10.97s; единственное предупреждение — существующий `StarletteDeprecationWarning` о связке Starlette TestClient/httpx. `/Users/grigornkokoko/YPerson/backend/.venv/bin/ruff check backend` вывела `All checks passed!`, а `ruff format --check backend` — `27 files already formatted`.
- Временные contract harnesses прошли на production-исходниках: Contacts — `contact-matched-identity-pass`, `contact-live-scope-pass`, `contact-ui-lifecycle-pass`; fixture storage — `fixture-persistence-pass`, `fixture-persistence-ui-contract-pass`; vCard — `vcard-contract-pass`; templates — `template-contract-pass`, `template-ui-contract-pass`, `template-doc-contract-pass`.
- Свежая Release-сборка `xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/yperson-final-fix-derived-20260821d -clonedSourcePackagesDirPath /tmp/yperson-final-fix-derived-20260821b/SourcePackages -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build` завершилась с exit code 0. В products присутствуют `YPerson.app`, `YPersonWidget.appex`, `YPersonNotificationService.appex` и `YPersonNotificationContent.appex`; дополнительный поиск не нашёл Debug fixture identities в Release app.
- Автоматизированная contract-проверка шаблонов покрывает default `standard-clean` для legacy payload, валидный public `templateID`, отклонение невалидного идентификатора, YDB persistence и сохранение `templateID` при exchange; свежая Release simulator build является build evidence для этой реализации.
- Binding rule rendering: UI resolves both missing and unknown `templateID` to `standard-clean`; this readable-card fallback is distinct from server-side rejection of a syntactically invalid supplied identifier during publish or exchange.
- Визуальная и device verification шаблонов пока не выполнялась: live preview, все четыре палитры в light/dark, отмена editor draft, VoiceOver/Dynamic Type, save/relaunch, received-card rendering, exported/shared image и ATT-denied availability остаются pending в `Release/manual-device-checks.md`.

## QR scanner widget

- Виджет является stateless-ярлыком сканера: он открывает только строгий маршрут `yperson://scan`, выбирает экран «Обмен» и запускает существующий QR-сканер приложения.
- На iOS 15 доступен `systemSmall`; на iOS 16 и новее также доступны `accessoryCircular` и `accessoryRectangular` для экрана блокировки.
- Расширение не имеет App Group entitlement, camera purpose string, доступа к камере, сети, аналитике или персональным данным. Все разрешения и сканирование остаются внутри основного приложения.
- Route, launch-gate и camera-permission policy harnesses прошли; чистая Debug-сборка для Generic iOS Simulator завершилась успешно. На iPhone 16 Pro Simulator проверены warm, cold и повторный `yperson://scan`, включая уже разрешённую камеру.
- Реальная камера, signed entitlements, размещение на Lock Screen и полный набор permission states остаются ручными проверками на физических устройствах.

## Не подтверждено внешне

- Новая YDB/Object Storage версия ещё не выкачена и не проверена через внешний API Gateway URL.
- Production APNs credentials, доставка push и notification extensions не проверены на физических iPhone.
- Bluetooth взаимный обмен, отмена и восстановление после background требуют двух физических iPhone.
- Не проверены Apple signing/App Groups, production AppMetrica traffic, privacy report подписанного архива и App Store Connect.
- Политика backup/restore и срок удаления резервных копий до 30 дней требуют подтверждения фактической Yandex Cloud конфигурацией.

Полный список ручных проверок находится в `Release/manual-device-checks.md`; `Release/release-manifest.json` сохраняет `releaseReady: false`.
