# YPerson — проверки на физических устройствах

Эти проверки намеренно не помечены выполненными: симулятор и неподписанная сборка не подтверждают реальное поведение оборудования, APNs, App Groups и production AppMetrica. Они обязательны до отправки в App Store Connect.

## Базовая матрица

- [ ] Проверить iPhone с iOS 15.x: установка, портретная ориентация, S1–S7, `systemSmall`-виджет и все iOS 15 fallback без вызова API новее deployment target.
- [ ] Проверить актуальную iOS на iPhone с Face ID и отдельном iPhone без доступной биометрии/с код-паролем.
- [ ] Проверить светлую и тёмную темы, VoiceOver, Reduce Motion и размеры текста от стандартного до Accessibility Extra Extra Extra Large.
- [ ] Подтвердить 44-точечные цели, порядок фокуса, отсутствие обрезки и понятные нецветовые статусы.

## Десять разрешений

- [ ] Bluetooth: на двух iPhone открыть экран обмена и запустить поиск сначала на A, затем на B; убедиться, что окно поиска закрывается и подтверждение появляется на обоих. Повторить в порядке B → A, подтвердить обмен на обоих и проверить сохранение обеих карточек. Затем отменить один обмен; убедиться, что сервер получает токен только после подтверждения и удаляет его не позднее 10 минут.
- [ ] Камера: отсканировать тестовый YPerson QR, vCard и посторонний QR; подтвердить, что посторонний код не импортируется, а после отказа доступны Фото и короткий код.
- [ ] Контакты: проверить полный доступ, отказ, restricted и limited на iOS 18+; сравнить план дубликатов перед записью и проверить системную форму одного контакта без чтения всей адресной книги.
- [ ] Face ID: успешная проверка, отмена, lockout и fallback на код-пароль; подтвердить, что публичная карточка остаётся доступной.
- [ ] Геопозиция When In Use: точная, approximate, denied и restricted; проверить человекочитаемую подпись либо ручной ввод и отсутствие координат в `/sync` и AppMetrica.
- [ ] Микрофон: record → auto-stop на 10 сек → preview → play/stop → выбор публичной или закрытой карточки → replace → delete; проверить отказ без блокировки редактора. После записи, но до «Сохранить запись», нажать «Готово»: редактор должен остаться открытым и попросить сохранить или удалить аудио. После каждого из этих действий карточка должна сохраниться, пережить перезапуск и сразу создавать онлайн QR/Bluetooth-токен без офлайн-подмены.
- [ ] Фото read: full, limited, denied; проверить управление выбранными фото, выбор одного изображения через PHPicker, подтверждение каждого найденного QR/vCard и отсутствие загрузки сырой медиатеки.
- [ ] Фото add-only: сохранить выбранное изображение карточки, затем проверить отказ и доступность Share Sheet.
- [ ] ATT: authorized, denied, restricted и notDetermined; IDFA/атрибуция разрешены только после authorized, а спонсорские шаблоны одинаково доступны при отказе.
- [ ] Push: разрешение и отказ, регистрация/удаление APNs-токена, in-app fallback и отсутствие циклических запросов.

## Backend, аналитика и расширения

- [ ] Применить versioned schema в YDB Serverless, создать private Object Storage bucket, выдать runtime service account минимальные права и передать credentials через Lockbox; не помещать ключи в GitHub или образ.
- [ ] Выкатить новую ревизию Serverless Container и API Gateway route `/sync`, затем проверить внешний HTTPS URL: `/health`, `/config` с ETag/304 и installation-authenticated `/sync` (refresh/publish/exchange/audio/delete).
- [ ] Проверить, что production runtime не запускается без YDB/Object Storage/Lockbox настроек, private bucket не допускает публичного чтения, а подписанные URL живут не более 300 секунд.
- [ ] Настроить monitoring и alerting для availability, YDB errors/throttling, Object Storage failures, latency и moderation queue; сохранить evidence тестового alert/response.
- [ ] Проверить, что `/config` может только отключать функции/аналитику и не может добавлять разрешения, категории данных, tracking или retention.
- [ ] С production AppMetrica key подтвердить: до согласия нет активации/трафика; после согласия есть единственный `launch`; выключение аналитики и remote kill switch останавливают будущую отправку; события не содержат карточки, Контакты, медиа, координаты, токены или свободный текст.
- [ ] Проверить AppMetrica 6.5.0, его package identity/revision, privacy manifests, подпись/происхождение и фактические сетевые домены в release archive.
- [ ] На iOS 15 проверить `systemSmall`: нажатие открывает «Обмен» и запускает существующий сценарий «Сканировать QR».
- [ ] На iOS 16+ проверить `accessoryCircular` и `accessoryRectangular` на Lock Screen с тем же переходом.
- [ ] Проверить cold launch, warm launch, повторное нажатие без дублирования, а также authorized/notDetermined/denied/restricted состояния камеры.
- [ ] Подтвердить, что у widget extension нет App Group entitlement, camera purpose string, сетевого клиента и персонального snapshot.
- [ ] Настроить Curve25519 public key и отправить валидное и невалидное signed push. Проверить тайм-аут public-avatar, безопасный fallback, удаление технического токена и действия «Просмотреть и обновить»/«Заблокировать» без прямой записи в Контакты.
- [ ] На подписанной сборке подтвердить App Group entitlement основного приложения, его отсутствие у widget extension и push entitlement основного приложения.

## Удаление и модерация

- [ ] Для YDB/Object Storage подтвердить фактическую backup/restore policy и удаление резервных копий в заявленный срок до 30 дней; удалить профиль онлайн и проверить отсутствие карточки, связей, claims, APNs/auth token, media metadata и object key.
- [ ] Удалить профиль офлайн: локальные данные очищены сразу, pending-флаг переживает перезапуск, а серверный запрос успешно повторяется при появлении сети.
- [ ] Отправить каждую категорию жалобы, заблокировать и удалить связь; подтвердить немедленный локальный эффект, backend SLA и неизменность системных Контактов.

## Перед App Store Connect

- [ ] Назначить окончательные Bundle IDs, Apple Team, App Group, signing/provisioning и APNs environment.
- [ ] Опубликовать privacy policy, support и moderation contacts; проверить ссылки из приложения и metadata App Store Connect.
- [ ] Заполнить App Privacy, ATT, возрастной рейтинг, export compliance и review notes строго по `AppPrivacy.yml` и фактическому privacy report архива.
- [ ] Сверить семь подготовленных 1320×2868 JPEG в `Release/app-store-metadata/screenshots/` с финальной подписанной конфигурацией и повторно снять любой экран, где изменился UI/брендинг/production-статус.
- [ ] Отсканировать `Release/reviewer-assets/test-qr.png` финальной физической сборкой и подтвердить payload `yperson:card:person-anna:review-token`, preview и отдельное подтверждение сохранения.
- [ ] Создать подписанный архив, просмотреть Organizer privacy report, embedded extensions, entitlements, symbols и validation warnings; загрузку и изменение App Store Connect выполнять только после нового явного утверждения непосредственно перед внешним действием.
