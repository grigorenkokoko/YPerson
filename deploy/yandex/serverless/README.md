# YPerson: автоматическая выкладка Serverless

Workflow [`deploy-serverless.yml`](../../../.github/workflows/deploy-serverless.yml)
тестирует backend, собирает один immutable `linux/amd64` образ с полным SHA,
применяет схему YDB, выкатывает приватный Serverless Container, обновляет
существующий API Gateway и выполняет одноразовую проверку карточки и приватного
аудио. При ошибке health/smoke контейнер откатывается на предыдущую активную
ревизию, а временные профили удаляются.

## Уже настроенная GitHub OIDC-идентичность

Её нельзя пересоздавать или заменять постоянным ключом:

```text
Deployment service account: ajeo8kqgko5ftmdlqq43 (yperson-github)
Federation: aje9djqjtuacd2fk39a0
Federated credential: aje2u4ailt53p0338o7p
Audience: https://github.com/grigorenkokoko
Subject: repo:grigorenkokoko@89942789/YPerson@1337270808:ref:refs/heads/main
```

В GitHub должны оставаться только repository variables; GitHub Secrets и
долгоживущий JSON-ключ сервисного аккаунта не нужны.

## Облачные ресурсы

Создайте в том же каталоге:

1. YDB Serverless и сохраните её endpoint и полный database path.
2. Приватный Object Storage bucket с полностью отключённым публичным доступом.
3. Статический S3 access key для `yperson-runtime`.
4. Один Lockbox secret с ключами `access_key_id` и `secret_access_key`; укажите
   конкретный ID версии, не `latest`.

Минимальные роли:

| Субъект | Роли |
| --- | --- |
| `yperson-runtime` | `container-registry.images.puller`, `ydb.editor`, доступ на запись объектов только в выбранный bucket, `lockbox.payloadViewer` только на выбранный secret |
| `yperson-gateway` | `serverless-containers.containerInvoker` только на `yperson-api` |
| `yperson-github` | `container-registry.images.pusher`, `serverless-containers.editor` только на `yperson-api`, `iam.serviceAccounts.user` на runtime SA, `ydb.editor` на выбранную YDB, `api-gateway.editor` на существующий Gateway |

Контейнер остаётся приватным. Публичным является только API Gateway.

## GitHub repository variables

Скопируйте [`config.example.env`](config.example.env) и заполните все значения:

```text
YC_FOLDER_ID
YC_REGISTRY_ID
YC_DEPLOYER_SA_ID
YC_API_GATEWAY_ID
YC_HTTP_CONTAINER_ID
YC_RUNTIME_SA_ID
YC_GATEWAY_SA_ID
YC_HEALTH_URL
YPERSON_CONFIG_VERSION
YPERSON_PRIVACY_URL
YPERSON_SUPPORT_URL
YDB_ENDPOINT
YDB_DATABASE
YPERSON_OBJECT_BUCKET
YPERSON_S3_LOCKBOX_SECRET_ID
YPERSON_S3_LOCKBOX_VERSION_ID
```

Значения S3 access key и secret key в GitHub не добавляются. Ревизия получает
их напрямую из одной явно версионированной записи Lockbox. Runtime также
получает `YDB_METADATA_CREDENTIALS=1` и использует собственный сервисный
аккаунт для YDB.

## Что делает smoke-проверка

После health-check скрипт без вывода тела запросов и чувствительных значений:

1. создаёт две случайные одноразовые установки;
2. подтверждает обмен между ними;
3. получает подписанный upload URL и загружает маленький `audio/mp4` объект;
4. публикует карточку, обновляет карточку второго участника и получает
   разрешённый подписанный download URL;
5. скачивает и сравнивает объект;
6. удаляет оба профиля и объект.

Bearer, подписанные URL, APNs token и JSON-тела никогда не печатаются. При
неуспехе cleanup повторяется до отката.

## API Gateway

Спецификация [`api-gateway.yaml`](api-gateway.yaml) направляет `/health`,
`/config`, `/privacy`, `/support` и `/sync` в один приватный контейнер через
`yperson-gateway`. Для `/sync` документированы статусы `200`, `400`, `401`,
`409`, `413`, `415` и `503`.

После merge/push в `main` workflow запускается автоматически; вручную:

```bash
gh workflow run deploy-serverless.yml --ref main
```

После успешного run проверьте, что прямой URL контейнера без Authorization
по-прежнему отвечает `401` или `403`, а Gateway `/health` отвечает `200`.
