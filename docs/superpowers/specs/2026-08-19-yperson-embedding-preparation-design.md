# Подготовка YPerson к последующему встраиванию

Дата: 2026-08-19  
Статус: согласованный дизайн, ожидает финального просмотра перед планированием реализации

## 1. Цель и ограничения

YPerson остаётся самостоятельно запускаемым портретным iPhone-приложением. Текущая итерация должна отделить создание пользовательского опыта от владения процессом так, чтобы позднее UI YPerson можно было перенести в reusable target и подключить к приложению Bank без переработки экранов и бизнес-логики.

По решению владельца продукта текущая итерация:

- не добавляет reusable target;
- не добавляет host fixture;
- не добавляет Bank-код, backend root flag или Bank router;
- не добавляет автоматические test target'ы;
- не регистрирует и не обрабатывает `bank://`;
- не добавляет и не сохраняет `yperson://` deep links;
- не меняет самостоятельный характер приложения и его поставляемые расширения.

Это подготовительный рефакторинг, а не доказанная интеграция в реальный host.

## 2. Подтверждённые продуктовые правила будущей Bank-интеграции

Эти правила документируются сейчас, но не реализуются в standalone YPerson:

- backend-контракт root flag — `Bool`;
- `true` выбирает Bank root;
- `false` выбирает YPerson root;
- на холодном запуске host ждёт ответ не более 1,5 секунды;
- кешируется только значение `true`;
- TTL кешированного `true` — 24 часа;
- свежий `false` удаляет кешированный `true`;
- при ошибке или таймауте действующий кеш `true` выбирает Bank;
- при ошибке или таймауте без действующего кеша выбирается YPerson;
- выбранный root фиксируется до следующей безопасной границы и не заменяется посреди активного flow;
- поздний ответ может изменить состояние для следующего запуска, но не текущий root;
- `bank://` принадлежит исключительно Bank executable и Bank router и никогда не передаётся YPerson;
- host-owned widget сохраняет производный snapshot итогового выбора в свой App Group и вызывает `WidgetCenter.reloadTimelines(ofKind:)`;
- уже установленный widget сохраняет стабильный `kind`, меняя содержимое и маршрут, а не заменяясь другим widget kind.

## 3. Аудит текущего состояния

| Область | Текущий владелец | Риск | Действие в этой итерации | Позднее |
|---|---|---|---|---|
| `@main`, `AppDelegate`, `UIWindow` | `YPerson` application target | Низкий: shell уже отделён от UI-классов, но создаёт конкретный `AppFactory` | Оставить в executable shell и запускать UI только через `YPersonExperienceBuilder` | Bank создаёт собственный composition root |
| Создание root UI | `AppFactory` | Имя и API привязаны к standalone-приложению | Превратить в внутренний `YPersonExperienceBuilder` с одним методом создания `UIViewController` | Перенести builder и UI в reusable target |
| Сеть и API | `AppFactory` / `APIClient` | При переносе можно случайно передать владение Bank | Оставить собственными реализациями YPerson внутри builder | Проверить coexistence с сетевой политикой Bank |
| Аналитика | `AppMetricaAnalyticsClient` | Текущая глобальная активация может конфликтовать с аналитикой host-процесса | Сохранить YPerson-owned wrapper без смены поведения standalone | Перед реальным встраиванием перейти на отдельный AppMetrica reporter и проверить настройки процесса |
| Разрешения | `PermissionCenter` и feature-классы | Системные вызовы смешаны с UI | Оставить YPerson-owned; lifecycle-входы сделать семантическими | Host пересылает только process-owned события |
| Конфигурация | `AppConfiguration(bundle: .main)` | Скрытая зависимость от main bundle затрудняет перенос | Убрать default `.main`; standalone shell передаёт bundle явно | Перенести конфигурационные ресурсы в bundle reusable target |
| App Group storage | `AppGroupSnapshotStore` | Ключи не namespaced; возможны коллизии и несовместимость | Перейти на `yperson.v1.*` с идемпотентным чтением/переносом legacy-ключей | Host предоставляет только entitlement-backed identifier |
| Widget snapshot | Две отдельные модели в app и widget | Кодеки могут разойтись | Совместно компилировать Foundation-only модель, envelope и ключи в обоих существующих target'ах | Host widget использует свой wrapper и свой App Group |
| URL routes | В Info.plist есть `yperson`, widget содержит `yperson://card`, обработчика в AppDelegate нет | Неработающий и не требуемый контракт | Удалить custom URL scheme и widget URL; tap открывает корень standalone-приложения | `bank://` реализуется только в Bank executable |
| Notification extensions | Собственные executable target'ы | Нельзя перенести вместе с UI-кодом автоматически | Не менять | Bank создаёт свои wrappers; shared logic извлекается отдельно |
| Автоматические тесты | iOS test target отсутствует | Границы не будут автоматически защищены | Не добавлять по прямому решению владельца продукта | Перед фактическим встраиванием потребуются contract и host checks |

Исходная Debug simulator-сборка схемы `YPerson`, включая три вложенных extension target'а, успешно завершена 2026-08-19.

## 4. Граница модулей

### Текущая итерация

```text
YPerson.app (@main)
    └── Standalone composition root
            └── YPersonExperienceBuilder
                    ├── YPerson UI
                    ├── YPerson API
                    ├── YPerson storage
                    ├── YPerson analytics
                    └── YPerson permissions

YPersonWidget.appex (@main) ── shared Foundation snapshot/codec
YPersonNotificationService.appex (@main) ── без изменений
YPersonNotificationContent.appex (@main) ── без изменений
```

### Будущая интеграция

```text
YPerson.app (@main) ── standalone adapter ──┐
                                           ├── YPersonExperience target
Bank.app (@main) ── Bank adapter ──────────┘
     ├── Bool root selector
     ├── Bank router (`bank://`)
     └── Bank-owned extension wrappers
```

## 5. Интеграционный контракт

Контракт остаётся `internal` в текущем application target. При будущем переносе в reusable target минимально необходимые символы станут `public` без изменения формы API.

```swift
enum YPersonEntryPoint: Sendable {
    case root
    case card
    case privacy
}

struct YPersonExperienceContext: Sendable {
    let entryPoint: YPersonEntryPoint
}

enum YPersonLifecycleEvent: Sendable {
    case didEnterForeground
    case pushTokenChanged(String?)
}

@MainActor
protocol YPersonExperienceOutput: AnyObject {
    func yPersonExperienceDidRequestDismiss()
}

@MainActor
final class YPersonExperienceBuilder {
    init(configuration: AppConfiguration)

    func makeRootViewController(
        context: YPersonExperienceContext,
        output: any YPersonExperienceOutput
    ) -> UIViewController

    func route(to entryPoint: YPersonEntryPoint)
    func handle(_ event: YPersonLifecycleEvent)
}
```

Правила контракта:

- builder создаёт UI, но не владеет `UIApplicationDelegate`, `UIWindow`, product metadata или executable extensions;
- builder самостоятельно создаёт YPerson-owned API, storage, analytics и permission services;
- `output` удерживается слабо;
- standalone shell сохраняет builder на время жизни процесса и пересылает semantic lifecycle events;
- Bank-типы, Bank router и root flag отсутствуют;
- создание root UI происходит на `MainActor`.

## 6. Required now и later

| Required now: подготовка standalone YPerson | Later: первая безопасная интеграция |
|---|---|
| Внутренний root builder | Отдельный reusable target |
| Тонкий standalone composition root | Bank adapter и реальный host fixture |
| Explicit bundle configuration | Module-owned resource bundle |
| Namespaced storage и legacy migration | Host App Group wiring |
| Общий app/widget snapshot codec | Bank widget wrapper и root selection snapshot |
| Semantic lifecycle forwarding | Bool selector, timeout и conditional cache |
| Независимые extension entry points | Extension-safe kits и Bank wrappers |
| Clean build и ручная проверка | Contract, integration и extension tests |

## 7. План файлов текущей итерации

| Файл | Изменение |
|---|---|
| `YPerson/App/AppDelegate.swift` | Хранить `YPersonExperienceBuilder`, создавать root через контракт, пересылать push token и foreground event, реализовать standalone output |
| `YPerson/App/AppFactory.swift` | Переименовать/преобразовать в `YPersonExperienceBuilder`, принять context/output, сохранить текущую сборку экранов без архитектурной переписи |
| `YPerson/Experience/YPersonIntegrationContract.swift` | Добавить entry points, context, lifecycle event и output |
| `YPerson/UI/MainTabBarController.swift` | Добавить внутренний typed переход к `root`, `card` и `privacy`, не связывая его с URL parser |
| `YPerson/Support/AppConfiguration.swift` | Требовать явный `Bundle`, исключив скрытый default `.main` |
| `YPerson/Storage/AppGroupSnapshotStore.swift` | Namespaced keys, legacy migration, новый общий widget envelope |
| `YPerson/Domain/Models.swift` | Удалить дублируемую widget snapshot model после переноса в shared Foundation-файл |
| `YPersonShared/WidgetSnapshot.swift` | Общая Foundation-only модель, schema version, keys и decoder fallback для app/widget |
| `YPersonWidget/YPersonWidget.swift` | Использовать общий codec/key; удалить private duplicate и `.widgetURL` |
| `project.yml` | Подключить `YPersonShared` к app и widget target'ам; удалить `yperson` URL scheme |
| `YPerson/Resources/Info.plist` и сгенерированный project | Синхронизировать удаление URL scheme через штатную генерацию проекта |

`NotificationService.swift` и `NotificationViewController.swift` в этой итерации не меняются.

## 8. Storage migration

Новые ключи используют prefix `yperson.v1.`. Для каждого существующего ключа:

1. прочитать новый ключ;
2. если нового значения нет, прочитать legacy-ключ;
3. если legacy payload декодируется, записать его под новым ключом;
4. удалить только успешно перенесённый legacy-ключ;
5. повторный запуск миграции не меняет уже перенесённые данные.

Widget сначала читает новый versioned envelope, затем legacy `widget_snapshot`. Это сохраняет отображение, если extension запустится до первого запуска обновлённого приложения.

Переносятся ключи:

- `own_card`;
- `widget_snapshot`;
- `remote_configuration`;
- `remote_configuration_etag`;
- `analytics_consent`;
- `profile_deletion_pending`.

Очистка пользовательских данных удаляет только keys YPerson и не сканирует чужие host defaults.

## 9. Extension mapping

| Extension | Остаётся в wrapper | Совместно используется сейчас | Будущее извлечение |
|---|---|---|---|
| WidgetKit | `@main`, kind, families, App Group lookup, presentation | Snapshot model, envelope, keys, decoder | Provider/view kit; Bank сохраняет свой kind и route |
| Notification Service | Principal class, signing key lookup, timeout callback, bundle ID | Ничего | Payload sanitizer, verifier и attachment processor |
| Notification Content | Principal class, category, bundle ID, action dispatch | Ничего | Payload-to-view-model и reusable view |

Все extension targets сохраняют `APPLICATION_EXTENSION_API_ONLY` и собственные privacy manifests.

## 10. Проверочная матрица

По решению владельца продукта автоматические тесты не создаются. Проверка выполняется сборками и ручными сценариями.

| Проверка | Ожидаемый результат |
|---|---|
| Clean Debug simulator build схемы `YPerson` | Application и три embedded extensions собираются без warnings/errors |
| Отдельная сборка `YPersonWidget` | Widget extension собирается самостоятельно |
| Отдельная сборка notification service | Service extension собирается самостоятельно |
| Отдельная сборка notification content | Content extension собирается самостоятельно |
| Cold standalone launch | Root создаётся через `YPersonExperienceBuilder`; видны прежние четыре вкладки |
| Card/privacy entry point через внутренний builder API | Выбирается соответствующая вкладка без URL scheme |
| Legacy own card | Данные читаются, переносятся под namespaced key и сохраняются |
| Legacy widget snapshot до запуска app | Widget показывает legacy snapshot |
| Новый widget snapshot после запуска app | Widget читает versioned envelope |
| Tap по standalone widget | Открывается корень приложения; custom URL не требуется |
| Notification extensions | Существующая обработка payload и content UI не изменена |

## 11. Порядок миграции

1. Добавить shared Foundation widget model/codec.
2. Добавить integration contract.
3. Преобразовать `AppFactory` в `YPersonExperienceBuilder` без изменения экранов.
4. Перевести standalone `AppDelegate` на builder и semantic lifecycle forwarding.
5. Добавить typed routing внутри существующего tab root без URL layer.
6. Ввести namespaced storage и legacy migration.
7. Перевести standalone widget на общий codec и удалить custom widget URL.
8. Удалить `yperson` URL scheme из product configuration.
9. Перегенерировать Xcode project штатным генератором.
10. Выполнить всю проверочную матрицу и проверить diff на отсутствие Bank-кода и несвязанных изменений.

## 12. Критерии приёмки

- `YPerson` остаётся independently runnable application target.
- Пользовательский root создаётся только через `YPersonExperienceBuilder`.
- Builder не владеет app delegate, window, signing, capabilities или extension entry points.
- Существующий UI и основные пользовательские сценарии визуально не изменены.
- YPerson-owned API, analytics, storage и permissions остаются внутри YPerson.
- Core configuration не использует скрытый default `Bundle.main`.
- Storage keys namespaced; legacy migration идемпотентна и не удаляет данные при ошибке декодирования.
- App и widget используют один формат widget snapshot.
- Standalone widget открывает root приложения без custom URL scheme.
- `bank://`, Bank router, root flag и conditional cache отсутствуют в поставляемом YPerson-коде.
- Все четыре существующих target'а собираются без warnings/errors.
- Существующие несвязанные изменения backend/release-файлов не затронуты.

## 13. Явные ограничения и blockers

- Без reusable target и host fixture фактическая собираемость YPerson внутри Bank не доказана.
- Исходники Bank, его router, App Group, bundle ID, widget kind и `bank://` route inventory отсутствуют в этом репозитории.
- Поведение host при получении `bank://` во время зафиксированной YPerson-сессии должно быть определено владельцем Bank; YPerson никогда не получает эту ссылку.
- Сосуществование текущей глобальной AppMetrica activation с аналитикой Bank требует отдельной проверки и, вероятно, перехода на YPerson-specific reporter до встраивания.
- Отказ от автоматических тестов означает, что storage migration и integration boundary защищаются только ручной проверкой; это осознанное отклонение от полной test matrix навыка подготовки встраиваемого experience.
- Подписанные device/archive проверки и изменения App Store configuration не входят в текущую итерацию.

