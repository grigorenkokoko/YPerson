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
- После объединения полный backend-набор завершился с результатом 140 passed; Ruff passed. Чистая Debug-сборка общего iOS-проекта для Generic iOS Simulator без signing завершилась успешно.
- Автоматизированная contract-проверка шаблонов покрывает default `standard-clean` для legacy payload, валидный public `templateID`, отклонение невалидного идентификатора, YDB persistence и сохранение `templateID` при exchange; Release simulator build является build evidence для этой реализации.
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
