# YPerson — отчёт проверки реализации

## Статус

Статус остаётся `implementation-verified`, но не `archive-validated` и не `release-ready`.

Локально реализованы iOS-клиент, installation-authenticated sync v2, YDB Serverless adapter и schema, приватный Object Storage для аудиоприветствий, обмен QR/Bluetooth, локальное хранение людей и полный путь удаления профиля. Эта запись не является доказательством внешней выкладки: применение YDB schema, создание private bucket/Lockbox, новая ревизия Serverless Container и маршрутизация API Gateway проверяются отдельно в deployment-задаче.

## Локально проверено

- Backend на Python 3.12/FastAPI принимает только строгий camelCase sync v2; установка аутентифицируется секретом из Keychain, а YDB хранит только SHA-256 секрета и токенов обмена.
- YDB adapter хранит карточки, подтверждённые связи, APNs-токены, краткоживущие exchange claims, moderation state и метаданные аудио. Private Object Storage хранит только `.m4a`; подписанные PUT/GET действуют 300 секунд и не сохраняются на iPhone.
- Публикация аудио проходит prepare → signed PUT → HEAD-проверка размера/MIME → публикация карточки. Получатель загружает аудио только после нажатия; кэш очищается при изменении/отзыве карточки, блокировке и удалении профиля.
- Удаление профиля транзакционно удаляет карточку, APNs-токен, связи, claims, installation credential и media metadata, затем идемпотентно удаляет Object Storage keys. Повтор того же `operationID` возвращает то же подтверждение без создания новой установки.
- На iOS запрос удаления хранится до подтверждения сервера. После подтверждения очищены карточка, люди, widget snapshot, sync cursor/pending payloads, analytics consent, аудиофайлы/кэш и Keychain credential; автоматический bootstrap остаётся запрещён до явного создания новой карточки.
- Публичные `/privacy` и `/support` описывают фактически реализованные данные, путь удаления и сроки, но прямо отмечают отсутствие внешней проверки этой версии.
- Focused deletion/media/public-pages: 7 passed. Итоговый минимальный backend-набор: 75 passed; Ruff passed. Task 6 Release simulator build без signing завершился `BUILD SUCCEEDED` за 75.426 s.

## Не подтверждено внешне

- Новая YDB/Object Storage версия ещё не выкачена и не проверена через внешний API Gateway URL.
- Production APNs credentials, доставка push и notification extensions не проверены на физических iPhone.
- Bluetooth взаимный обмен, отмена и восстановление после background требуют двух физических iPhone.
- Не проверены Apple signing/App Groups, production AppMetrica traffic, privacy report подписанного архива и App Store Connect.
- Политика backup/restore и срок удаления резервных копий до 30 дней требуют подтверждения фактической Yandex Cloud конфигурацией.

Полный список ручных проверок находится в `Release/manual-device-checks.md`; `Release/release-manifest.json` сохраняет `releaseReady: false`.
