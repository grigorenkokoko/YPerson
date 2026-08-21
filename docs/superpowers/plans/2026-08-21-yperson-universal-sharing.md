# YPerson Universal Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Сделать основной QR YPerson обычной HTTPS-ссылкой, которая открывает карточку в установленном iPhone-приложении или минимальную мобильную веб-карточку без приложения, позволяет скачать vCard и передать владельцу подтверждаемый встречный контакт.

**Architecture:** iPhone генерирует один отзывный 256-битный публичный токен, хранит его в App Group и активирует через существующий аутентифицированный `/sync`. Backend хранит только SHA-256 токена, отдаёт HTML/JSON/vCard по `/p/{token}` и складывает встречные контакты с TTL 30 дней. Universal Link маршрутизируется в существующую вкладку «Обмен», а входящие контакты приходят в обычном foreground refresh и сохраняются только после явного подтверждения владельца. APNs-доставка входящего контакта, follow-up, новый tab bar и монетизация остаются за пределами пакета.

**Tech Stack:** UIKit + Swift 5 + iOS 15, XcodeGen, `URLSession`, `Security`, App Group `UserDefaults`, FastAPI + Pydantic v2, YDB, Pytest/Ruff, Yandex API Gateway.

**Spec:** [`docs/superpowers/specs/2026-08-21-yperson-user-product-roadmap-design.md`](../specs/2026-08-21-yperson-user-product-roadmap-design.md), пакет 1 «Универсальный обмен».

## Global Constraints

- Сохранять iPhone-приложение основным продуктом. Web не получает аккаунт, навигацию продукта, аналитику, cookies, fingerprinting или обязательную установку.
- Использовать монограмму из инициалов; не добавлять фото, аватары, загрузку медиа или новые permission prompts.
- Публичная версия карточки строится только из `PersonCard.exchangeCopy`; `phone` и `meetingPlace` не должны попасть в HTML, JSON или vCard в этом пакете.
- Не менять wire contract version `2`; новые optional-поля должны декодироваться старыми клиентами и иметь безопасные значения по умолчанию.
- Не логировать raw public token, email, телефон или имя отправителя. Observability хранит только шаблон маршрута и технический результат.
- Не добавлять `python-multipart`: форма использует ограниченный `application/x-www-form-urlencoded` и стандартную библиотеку Python.
- APNs-отправка входящего контакта не входит в этот speed-first пакет. Надёжный путь пилота — хранение на backend и получение через существующий `/sync` при foreground refresh. Remote notification transport переносится в пакет 4.
- Не создавать постоянный XCTest target. Чистые Swift-контракты проверяются временным harness в `/tmp`, UI — компиляцией Debug-сборки и одним ручным smoke на физическом iPhone.
- Не добавлять широкие snapshot-, UI-, performance- или load-тесты. Автоматизировать только токен/маршрут, изоляцию публичных данных, отзыв, TTL/подтверждение ответа и обратную совместимость sync.
- Не изменять и не включать в коммиты посторонние staged/unstaged файлы соседней задачи. Каждый commit ниже выполняется через `git commit --only` с перечисленными путями.
- Production Associated Domain для текущей конфигурации: `d5dl7dc4rc07v7jnvlf2.p8361f8z.apigw.yandexcloud.net`; Apple application identifier: `Q7A52Z2TS2.com.yperson.app`.

## File Map

**Policy and release contract**

- Modify: `AppSpec.md`
- Modify: `AppPrivacy.yml`
- Modify: `Release/review-notes.md`
- Modify: `Release/manual-device-checks.md`

**Backend contract and storage**

- Modify: `backend/app/schemas.py`
- Modify: `backend/app/storage.py`
- Modify: `backend/app/ydb_schema.py`
- Modify: `backend/app/ydb_store.py`
- Modify: `backend/app/sync_service.py`
- Modify: `backend/app/settings.py`
- Modify: `backend/app/main.py`
- Modify: `backend/app/serve.py`
- Modify: `backend/app/observability.py`
- Create: `backend/app/public_cards.py`
- Modify: `backend/tests/test_schemas.py`
- Modify: `backend/tests/test_storage.py`
- Modify: `backend/tests/test_sync_service.py`
- Create: `backend/tests/test_public_cards.py`
- Modify: `backend/tests/test_settings.py`
- Modify: `backend/tests/test_contract.py`
- Modify: `backend/tests/test_review_contract.py`
- Modify: `backend/tests/test_deployment_files.py`

**iOS domain, networking, routing, and UI**

- Create: `YPersonShared/PublicCardRoute.swift`
- Create: `YPerson/Domain/PublicSharing.swift`
- Modify: `YPerson/Domain/Models.swift`
- Modify: `YPerson/Networking/APIClient.swift`
- Modify: `YPerson/Networking/SyncCoordinator.swift`
- Modify: `YPerson/Storage/AppGroupSnapshotStore.swift`
- Modify: `YPerson/Experience/YPersonIntegrationContract.swift`
- Modify: `YPerson/App/AppDelegate.swift`
- Modify: `YPerson/App/AppFactory.swift`
- Modify: `YPerson/UI/MainTabBarController.swift`
- Modify: `YPerson/UI/CardViewController.swift`
- Modify: `YPerson/UI/ExchangeViewController.swift`
- Create: `YPerson/UI/PublicReplyReviewViewController.swift`

**Entitlements and deployment**

- Modify: `Config/Base.xcconfig`
- Modify: `YPerson/YPerson.entitlements`
- Modify: `YPerson/YPersonPersonal.entitlements`
- Modify: `project.yml`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`
- Modify: `deploy/yandex/serverless/api-gateway.yaml`
- Modify: `deploy/yandex/serverless/config.example.env`
- Modify: `deploy/yandex/serverless/README.md`

---

### Task 1: Approve the public-data and review contract before code

**Files:**

- Modify: `AppSpec.md`
- Modify: `AppPrivacy.yml`

**Interfaces:** Document the exact public routes, data fields, consent, retention, revocation, app-review path, and absence of web tracking. This task changes no runtime interface.

- [ ] **Step 1: Run a contract check that currently fails**

Run:

```bash
rg -n "public_link|public card|публичн.*ссыл|встречн.*контакт|30 дней" AppSpec.md AppPrivacy.yml
```

Expected: exit `1`, or output that does not describe all five required subjects.

- [ ] **Step 2: Update `AppSpec.md` with the exact pilot behavior**

Add a section stating all of the following as normative product behavior:

```text
- Public URL: GET /p/{public-token}; token is random, revocable, and never logged.
- Published payload: name, role, company, email, tagline, templateID; phone and meetingPlace are excluded in package 1.
- Guest actions: save vCard and optionally send name plus exactly one email or phone after explicit consent.
- Pending replies are shown to the owner and are not saved as people before confirmation.
- Revoke immediately blocks HTML, JSON, vCard, and new replies.
- Pending replies are deleted after owner dismissal/import or 30 days.
- The web page has no analytics SDK, advertising, cookies, account, indexing, or install wall.
```

Clarify that the existing internal `yperson:v2:` QR remains an offline fallback and that APNs delivery of contact replies is deferred to package 4; foreground `/sync` is the package-1 delivery path.

- [ ] **Step 3: Update `AppPrivacy.yml` before implementation**

Add a `public_sharing` section under the implemented feature contract with:

```yaml
public_sharing:
  status: approved-for-implementation
  public_fields: [name, role, company, email, tagline, template_id]
  excluded_fields: [phone, meeting_place, notes, photos, audio]
  token_storage:
    device: raw_256_bit_token
    backend: sha256_digest_only
  contact_reply:
    required: [name, consent]
    exactly_one_of: [email, phone]
    owner_confirmation_required: true
    pending_retention_days: 30
  web_tracking: none
  search_indexing: prohibited
  new_permissions: none
```

Record approval status as `approved-for-implementation`, not `implementation-verified`.

- [ ] **Step 4: Re-run the contract check**

Run:

```bash
rg -n "public_sharing|raw_256_bit_token|sha256_digest_only|pending_retention_days|foreground /sync" AppSpec.md AppPrivacy.yml
```

Expected: every term is present; no runtime tests are required for this documentation-only commit.

- [ ] **Step 5: Commit only the policy files**

```bash
git add AppSpec.md AppPrivacy.yml
git commit --only AppSpec.md AppPrivacy.yml -m "docs: approve universal sharing privacy contract"
```

---

### Task 2: Add strict sync models and durable public-card storage

**Files:**

- Modify: `backend/app/schemas.py`
- Modify: `backend/app/storage.py`
- Modify: `backend/app/ydb_schema.py`
- Modify: `backend/app/ydb_store.py`
- Modify: `backend/tests/test_schemas.py`
- Modify: `backend/tests/test_storage.py`

**Interfaces:**

```python
class SyncOperation(str, Enum):
    activate_public_link = "activatePublicLink"
    revoke_public_link = "revokePublicLink"
    dismiss_public_reply = "dismissPublicReply"

class PublicContactReply(BaseModel):
    id: str
    name: str
    email: str | None
    phone: str | None
    createdAt: datetime

class SyncResponse(BaseModel):
    publicLinkActive: bool | None = None
    publicReplies: list[PublicContactReply] = Field(default_factory=list)
```

`SyncRequest` receives `publicLinkToken: str | None` and `publicReplyID: str | None`. `activatePublicLink` requires `card` plus a canonical 43-character Base64URL token; `revokePublicLink` accepts no operation field; `dismissPublicReply` requires a UUID `publicReplyID`.

Storage boundary:

```python
@dataclass(frozen=True, slots=True)
class PublicCardRecord:
    owner_installation_id: str
    card: PersonCard

@dataclass(frozen=True, slots=True)
class PublicContactReplyRecord:
    id: str
    name: str
    email: str | None
    phone: str | None
    created_at: datetime

class SyncStore(Protocol):
    def activate_public_link(self, installation_id: str, operation_id: str, raw_token: str, card: PersonCard) -> None:
        raise NotImplementedError
    def revoke_public_link(self, installation_id: str, operation_id: str) -> None:
        raise NotImplementedError
    def resolve_public_card(self, raw_token: str) -> PublicCardRecord | None:
        raise NotImplementedError
    def create_public_reply(self, raw_token: str, reply_id: str, name: str, email: str | None, phone: str | None, expires_at: datetime) -> None:
        raise NotImplementedError
    def dismiss_public_reply(self, installation_id: str, operation_id: str, reply_id: str) -> None:
        raise NotImplementedError
```

In the real implementation, use full protocol method bodies with docstrings; the compact signatures above define the required types.

- [ ] **Step 1: Write failing schema tests**

Add focused cases to `backend/tests/test_schemas.py`:

```python
def test_activate_public_link_requires_card_and_canonical_token() -> None:
    payload = sync_payload(operation="activatePublicLink")
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(payload)

    payload["card"] = person_card_payload()
    payload["publicLinkToken"] = "A" * 43
    request = SyncRequest.model_validate(payload)
    assert request.publicLinkToken == "A" * 43


def test_public_reply_requires_exactly_one_contact_method() -> None:
    with pytest.raises(ValidationError):
        PublicContactReply(
            id=str(uuid4()), name="Анна", email=None, phone=None, createdAt=datetime.now(UTC)
        )
```

Also assert that public fields are rejected on `refresh`, `publishCard`, and unrelated operations, and that old response JSON without public fields still validates with empty defaults.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_schemas.py -q
```

Expected: fail because the operations and models do not exist.

- [ ] **Step 2: Implement the strict Pydantic contract**

In `backend/app/schemas.py`:

- validate the raw token by decoding URL-safe Base64 with restored padding, requiring exactly 32 bytes and canonical re-encoding without `=`;
- validate `publicReplyID` by parsing `UUID(value)` and requiring its lowercased canonical string;
- trim `name`, `email`, and `phone`; cap name at 80 UTF-8 characters and contact fields at 256;
- require exactly one non-empty email or phone in `PublicContactReply`;
- extend both `required_by_operation`, `allowed_by_operation`, and `operation_field_names` so fields cannot leak into unrelated operations.

Run the schema test command again. Expected: pass.

- [ ] **Step 3: Write failing storage/schema tests**

Add assertions to `backend/tests/test_storage.py` for these exact tables:

```python
assert EXPECTED_TABLES["public_links"].primary_key == ("owner_installation_id",)
assert EXPECTED_TABLES["public_replies"].primary_key == (
    "owner_installation_id", "reply_id"
)
```

Add scripted-store cases proving:

- activation stores `sha256(raw_token.encode()).digest()` and never raw token;
- a second activation replaces the old token for the owner;
- lookup by old token returns `None`, lookup by new token returns `PublicCardRecord`;
- revoked links resolve to `None` and reject a new reply;
- only 20 pending replies may exist for one owner;
- dismiss deletes only the owner-scoped reply and is idempotent;
- profile deletion removes public link and pending replies.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_storage.py -q
```

Expected: fail because schema version 2 and storage methods do not exist.

- [ ] **Step 4: Add YDB schema version 2**

Set `SCHEMA_VERSION = 2`. Add these exact table shapes to `EXPECTED_TABLES` and `TABLE_DDL`:

```sql
CREATE TABLE IF NOT EXISTS public_links (
    owner_installation_id Utf8 NOT NULL,
    token_hash String NOT NULL,
    card_json JsonDocument NOT NULL,
    created_at Timestamp NOT NULL,
    updated_at Timestamp NOT NULL,
    PRIMARY KEY (owner_installation_id),
    INDEX by_token GLOBAL ON (token_hash)
)
```

```sql
CREATE TABLE IF NOT EXISTS public_replies (
    owner_installation_id Utf8 NOT NULL,
    reply_id Utf8 NOT NULL,
    public_token_hash String NOT NULL,
    name Utf8 NOT NULL,
    email Utf8,
    phone Utf8,
    created_at Timestamp NOT NULL,
    expires_at Timestamp NOT NULL,
    PRIMARY KEY (owner_installation_id, reply_id)
) WITH (
    TTL = Interval("PT0S") ON expires_at
)
```

If the installed YDB SDK exposes secondary indexes in table descriptions, extend `TableSchema` verification to require `by_token`; otherwise keep exact column/primary-key verification and cover indexed lookup with the scripted query test.

- [ ] **Step 5: Implement the storage boundary and YDB methods**

Extend `SyncSnapshot` with:

```python
public_link_active: bool = False
public_replies: Sequence[PublicContactReplyRecord] = field(default_factory=tuple)
```

Import `Sequence` from `collections.abc` in `backend/app/storage.py` so the annotation remains immutable at the storage boundary.

Implement each method in the same serializable read/write + `operations` idempotency style already used by `publish_card` and `delete_profile`. Requirements:

- hash raw tokens immediately and pass only bytes to query parameters;
- store `card.model_dump_json()` using the already privacy-filtered card received from iOS;
- query public links by `VIEW by_token`;
- before reply insert, verify the active row and matching token hash in the same transaction;
- reject a 21st pending reply with `StorageConflict("reply limit reached")`;
- return replies ordered by `created_at`, then `reply_id`;
- include `public_links` and `public_replies` cleanup in `delete_profile`.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_schemas.py backend/tests/test_storage.py -q
backend/.venv/bin/ruff check backend/app/schemas.py backend/app/storage.py backend/app/ydb_schema.py backend/app/ydb_store.py backend/tests/test_schemas.py backend/tests/test_storage.py
```

Expected: all focused tests and Ruff pass.

- [ ] **Step 6: Commit only task files**

```bash
git add backend/app/schemas.py backend/app/storage.py backend/app/ydb_schema.py backend/app/ydb_store.py backend/tests/test_schemas.py backend/tests/test_storage.py
git commit --only backend/app/schemas.py backend/app/storage.py backend/app/ydb_schema.py backend/app/ydb_store.py backend/tests/test_schemas.py backend/tests/test_storage.py -m "feat: add universal sharing storage contract"
```

---

### Task 3: Serve the guest HTML, JSON, vCard, form, and AASA

**Files:**

- Create: `backend/app/public_cards.py`
- Create: `backend/tests/test_public_cards.py`
- Modify: `backend/app/settings.py`
- Modify: `backend/app/main.py`
- Modify: `backend/app/serve.py`
- Modify: `backend/app/observability.py`
- Modify: `backend/tests/test_settings.py`
- Modify: `backend/tests/test_contract.py`

**Interfaces:**

```python
class PublicCardService:
    def card(self, raw_token: str) -> PublicCardRecord | None:
        raise NotImplementedError
    def submit_reply(self, raw_token: str, reply_id: str, name: str, email: str | None, phone: str | None) -> None:
        raise NotImplementedError

GET  /.well-known/apple-app-site-association
GET  /p/{token}
GET  /p/{token}/card.json
GET  /p/{token}/contact.vcf
POST /p/{token}/replies
```

`Settings` receives `app_store_id: str` from `YPERSON_APP_STORE_ID` and `apple_application_identifier: str` from `YPERSON_APPLE_APPLICATION_IDENTIFIER`, defaulting to `Q7A52Z2TS2.com.yperson.app`.

- [ ] **Step 1: Write failing public-route tests**

Create `backend/tests/test_public_cards.py` using `TestClient(create_app(settings, sync_service=None, public_card_service=fake, lifespan=noop_lifespan))`. Cover only critical behavior:

```python
def test_revoked_and_unknown_tokens_share_the_same_safe_404(client) -> None:
    unknown = client.get("/p/" + "A" * 43)
    revoked = client.get("/p/" + "B" * 43)
    assert unknown.status_code == revoked.status_code == 404
    assert unknown.text == revoked.text


def test_private_fields_never_appear_in_public_outputs(client) -> None:
    html = client.get(valid_path).text
    json_body = client.get(f"{valid_path}/card.json").text
    vcard = client.get(f"{valid_path}/contact.vcf").text
    for secret in ("+79005550102", "Закрытая заметка", "meetingPlace"):
        assert secret not in html + json_body + vcard
```

Also test:

- HTML escapes `<script>` in every card field;
- vCard escapes CR/LF, backslash, semicolon, and comma;
- JSON has `Cache-Control: no-store` and the strict `PersonCard` keys only;
- form body above 4 KiB is rejected;
- missing consent, invalid UUID, blank name, or zero/two contact methods is rejected without persistence;
- a valid reply uses a server-side 30-day expiry;
- the page has `X-Robots-Tag: noindex, nofollow`, CSP, `Referrer-Policy: no-referrer`, and no external script;
- AASA contains only `appID = Q7A52Z2TS2.com.yperson.app` and `/p/*` components;
- Smart App Banner appears only when `app_store_id` is non-empty and its `app-argument` is the current HTTPS URL;
- observability maps requests to route templates and does not emit the token.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_public_cards.py backend/tests/test_settings.py backend/tests/test_contract.py -q
```

Expected: fail because the service and routes do not exist.

- [ ] **Step 2: Implement validation and rendering in one focused module**

In `backend/app/public_cards.py`, define:

```python
PUBLIC_REPLY_LIFETIME = timedelta(days=30)
MAX_FORM_BODY_BYTES = 4_096
MAX_PENDING_REPLIES = 20

def validate_public_token(value: str) -> str:
    data = urlsafe_b64decode(value + "=")
    if len(value) != 43 or len(data) != 32 or urlsafe_b64encode(data).decode().rstrip("=") != value:
        raise ValueError("invalid public token")
    return value
```

Use `html.escape(value, quote=True)` for HTML and a dedicated vCard helper:

```python
def escape_vcard(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("\r", "")
        .replace("\n", "\\n")
        .replace(";", "\\;")
        .replace(",", "\\,")
    )
```

Render initials from at most the first two non-empty name words, falling back to `YP`. Use inline CSS only. Do not put the raw token in logs, page text, local storage, JavaScript, or analytics. The token is necessarily present in action/download URLs and Smart App Banner `app-argument`.

Parse the POST only when content type is `application/x-www-form-urlencoded`:

```python
raw = await request.body()
if len(raw) > MAX_FORM_BODY_BYTES:
    raise HTTPException(status_code=413)
form = parse_qs(raw.decode("utf-8"), keep_blank_values=True, strict_parsing=True)
```

Require one scalar per key, `consent=on`, canonical UUID `replyID`, non-blank `name`, and exactly one of `email`/`phone`. Return a simple success page that does not echo submitted contact data.

- [ ] **Step 3: Wire routes without exposing tokens to observability**

Extend `create_app` with `public_card_service: PublicCardService | None = None`. Mount exact route names from the interface. For all `/p/{token}` responses set:

```text
Cache-Control: no-store
Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
X-Robots-Tag: noindex, nofollow
```

AASA uses `Content-Type: application/json`, no redirects, and `Cache-Control: public, max-age=3600`. In `_safe_route`, map route objects to `/.well-known/apple-app-site-association`, `/p/{token}`, `/p/{token}/card.json`, `/p/{token}/contact.vcf`, and `/p/{token}/replies`; never fall back to the raw URL path for these prefixes.

In `serve.py`, construct `PublicCardService` with the same `YDBSyncStore` and clock as sync. If the service is unavailable, public card routes return a generic `503` without distinguishing tokens.

- [ ] **Step 4: Run focused tests and lint**

```bash
backend/.venv/bin/pytest backend/tests/test_public_cards.py backend/tests/test_settings.py backend/tests/test_contract.py -q
backend/.venv/bin/ruff check backend/app/public_cards.py backend/app/settings.py backend/app/main.py backend/app/serve.py backend/app/observability.py backend/tests/test_public_cards.py backend/tests/test_settings.py backend/tests/test_contract.py
```

Expected: all pass.

- [ ] **Step 5: Commit only task files**

```bash
git add backend/app/public_cards.py backend/app/settings.py backend/app/main.py backend/app/serve.py backend/app/observability.py backend/tests/test_public_cards.py backend/tests/test_settings.py backend/tests/test_contract.py
git commit --only backend/app/public_cards.py backend/app/settings.py backend/app/main.py backend/app/serve.py backend/app/observability.py backend/tests/test_public_cards.py backend/tests/test_settings.py backend/tests/test_contract.py -m "feat: serve universal public cards"
```

---

### Task 4: Activate, revoke, fetch, and dismiss through sync

**Files:**

- Modify: `backend/app/sync_service.py`
- Modify: `backend/tests/test_sync_service.py`
- Modify: `backend/tests/test_review_contract.py`

**Interfaces:** Existing `/sync` dispatch adds `activatePublicLink`, `revokePublicLink`, and `dismissPublicReply`; every refresh returns `publicLinkActive` and pending `publicReplies`.

- [ ] **Step 1: Write failing service tests**

Extend the in-memory `SyncStore` in `backend/tests/test_sync_service.py` and add cases proving:

```python
def test_activate_public_link_stores_only_exchange_copy(service, request_factory) -> None:
    response = service.handle(
        request_factory(
            operation="activatePublicLink",
            card=card_with_phone_and_meeting_place(),
            publicLinkToken="A" * 43,
        ),
        bearer="secret",
    )
    assert response.publicLinkActive is True
    assert service._store.public_card.phone == ""
    assert service._store.public_card.meetingPlace is None
```

Since the iOS client is the primary privacy boundary, also make the server fail closed: `_activate_public_link` must create a `model_copy(update={"phone": "", "meetingPlace": None, "hasAudioGreeting": False})` before storage.

Add tests for:

- activation authenticates but does not bootstrap an unknown installation;
- revoke is idempotent and returns `publicLinkActive=False`;
- refresh returns sorted, unprocessed replies without contacts in `message`;
- dismiss removes one reply and the next snapshot no longer contains it;
- repeated dismiss with the same operation ID replays successfully;
- delete profile still deletes public state;
- legacy refresh response remains accepted by the review contract.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_sync_service.py backend/tests/test_review_contract.py -q
```

Expected: fail because dispatch does not handle the new operations.

- [ ] **Step 2: Implement dispatch and snapshot mapping**

Add match cases and handlers:

```python
case SyncOperation.activate_public_link:
    return self._activate_public_link(request)
case SyncOperation.revoke_public_link:
    return self._revoke_public_link(request)
case SyncOperation.dismiss_public_reply:
    return self._dismiss_public_reply(request)
```

Map storage records to strict response models:

```python
replies = [
    PublicContactReply(
        id=item.id,
        name=item.name,
        email=item.email,
        phone=item.phone,
        createdAt=item.created_at,
    )
    for item in snapshot.public_replies
]
```

Return `publicLinkActive=snapshot.public_link_active` from `_snapshot_response`. Activation and revoke may call `refresh(installationID, None)` after the durable mutation so their response reflects committed state. Dismiss must delete the reply before returning the new snapshot.

- [ ] **Step 3: Run focused contract verification**

```bash
backend/.venv/bin/pytest backend/tests/test_sync_service.py backend/tests/test_review_contract.py backend/tests/test_schemas.py -q
backend/.venv/bin/ruff check backend/app/sync_service.py backend/tests/test_sync_service.py backend/tests/test_review_contract.py
```

Expected: all pass.

- [ ] **Step 4: Commit only task files**

```bash
git add backend/app/sync_service.py backend/tests/test_sync_service.py backend/tests/test_review_contract.py
git commit --only backend/app/sync_service.py backend/tests/test_sync_service.py backend/tests/test_review_contract.py -m "feat: sync universal sharing state"
```

---

### Task 5: Add the iOS token, route, wire, and local state contracts

**Files:**

- Create: `YPersonShared/PublicCardRoute.swift`
- Create: `YPerson/Domain/PublicSharing.swift`
- Modify: `YPerson/Domain/Models.swift`
- Modify: `YPerson/Networking/APIClient.swift`
- Modify: `YPerson/Networking/SyncCoordinator.swift`
- Modify: `YPerson/Storage/AppGroupSnapshotStore.swift`
- Modify: `Config/Base.xcconfig`
- Modify: `YPerson/YPerson.entitlements`
- Modify: `YPerson/YPersonPersonal.entitlements`
- Modify: `project.yml`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**

```swift
enum PublicCardRoute {
    static func url(baseURL: URL, token: String) throws -> URL
    static func token(from url: URL, allowedHost: String) -> String?
}

enum PublicLinkToken {
    static func generate() throws -> String
    static func isValid(_ value: String) -> Bool
}

struct PublicContactReply: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let email: String?
    let phone: String?
    let createdAt: Date
}
```

`SyncCoordinator` adds:

```swift
func activatePublicLink(card: PersonCard) async throws -> URL
func revokePublicLink() async -> Bool
func fetchPublicCard(token: String) async throws -> PersonCard
func dismissPublicReply(id: String) async throws
var onPublicRepliesChanged: (([PublicContactReply]) -> Void)?
```

- [ ] **Step 1: Create a failing temporary Swift contract harness**

Create `/tmp/yperson-public-route-tests.swift` with `@main` and assertions for:

```swift
let token = String(repeating: "A", count: 43)
precondition(PublicLinkToken.isValid(token))
let base = URL(string: "https://cards.example.com")!
let url = try PublicCardRoute.url(baseURL: base, token: token)
precondition(url.absoluteString == "https://cards.example.com/p/\(token)")
precondition(PublicCardRoute.token(from: url, allowedHost: "cards.example.com") == token)
precondition(PublicCardRoute.token(from: URL(string: "http://cards.example.com/p/\(token)")!, allowedHost: "cards.example.com") == nil)
precondition(PublicCardRoute.token(from: URL(string: "https://evil.example/p/\(token)")!, allowedHost: "cards.example.com") == nil)
precondition(PublicCardRoute.token(from: URL(string: "https://cards.example.com/p/\(token)/extra")!, allowedHost: "cards.example.com") == nil)
```

Run:

```bash
xcrun swiftc YPersonShared/PublicCardRoute.swift YPerson/Domain/PublicSharing.swift /tmp/yperson-public-route-tests.swift -o /tmp/yperson-public-route-tests
```

Expected: fail because the two Swift files do not exist.

- [ ] **Step 2: Implement canonical URL and cryptographic token helpers**

`PublicLinkToken.generate()` must call `SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)`, Base64URL-encode without padding, and verify 43 canonical characters. `isValid` must decode/re-encode and require exactly 32 bytes. No UUID-based public tokens.

`PublicCardRoute` must require:

- `https` scheme;
- exact case-insensitive host match;
- no user/password/port/query/fragment;
- exactly two path components after `/`, where the first is `p`;
- canonical `PublicLinkToken`.

Run the compile command and then `/tmp/yperson-public-route-tests`. Expected: exit `0`.

- [ ] **Step 3: Write a failing wire encode/decode harness**

Create `/tmp/yperson-public-wire-tests.swift` that constructs:

```swift
let request = SyncRequest(
    operation: .activatePublicLink,
    card: sample.exchangeCopy,
    publicLinkToken: String(repeating: "A", count: 43)
)
precondition(request.isMutation)

let legacy = Data("""
{"accepted":true,"serverVersion":"2","updateCount":0,"message":"ok","people":[],"revokedCardIDs":[]}
""".utf8)
let response = try JSONDecoder().decode(SyncResponse.self, from: legacy)
precondition(response.publicReplies.isEmpty)
```

Compile it with `YPerson/Domain/Models.swift` and `YPerson/Domain/PublicSharing.swift` using the same SDK flags already used by the repository's prior Swift harnesses.

Expected: fail because the new operation and backward-compatible decoding are absent.

- [ ] **Step 4: Extend Swift domain and wire models**

Add exact cases `.activatePublicLink`, `.revokePublicLink`, `.dismissPublicReply`. Add `publicLinkToken` and `publicReplyID` to `SyncRequest`, its initializer, `SyncWireRequest`, and `APIClient.makeWireRequest`.

Because synthesized `Decodable` does not supply defaults for absent keys, implement a custom `SyncResponse.init(from:)` that uses:

```swift
publicLinkActive = try container.decodeIfPresent(Bool.self, forKey: .publicLinkActive)
publicReplies = try container.decodeIfPresent([PublicContactReply].self, forKey: .publicReplies) ?? []
```

Preserve the current required decoding behavior of all pre-existing response fields. Set ISO-8601 date decoding on `APIClient` for `createdAt` consistently with existing audio timestamps.

- [ ] **Step 5: Persist the raw token only in the App Group**

Add keys:

```swift
static let publicLinkToken = "yperson.v2.public_link_token"
static let publicLinkActive = "yperson.v2.public_link_active"
```

Add typed properties for both and remove both in `clearUserData()`. `activatePublicLink(card:)` behavior:

1. reuse a locally stored valid token or generate a new one;
2. enqueue/send `activatePublicLink` using `card.exchangeCopy`;
3. mark active only after accepted response;
4. return `PublicCardRoute.url(baseURL: baseURL, token: token)`.

If the raw token is missing after reinstall but backend reports active, generate and activate a replacement; do not try to recover raw token from backend. Revoke clears active state but retains the local token for idempotent reactivation. Profile deletion removes both.

`fetchPublicCard(token:)` performs unauthenticated `GET /p/{token}/card.json` through `APIClient`, with no-store semantics and the existing ephemeral URL session. `dismissPublicReply(id:)` uses the retry queue so a locally accepted contact cannot remain pending indefinitely after a transient network failure.

- [ ] **Step 6: Add Associated Domains configuration**

Add to `Config/Base.xcconfig`:

```xcconfig
YP_ASSOCIATED_DOMAIN = d5dl7dc4rc07v7jnvlf2.p8361f8z.apigw.yandexcloud.net
```

Add to both app entitlements:

```xml
<key>com.apple.developer.associated-domains</key>
<array>
    <string>applinks:$(YP_ASSOCIATED_DOMAIN)</string>
</array>
```

Keep extensions unchanged. Ensure `project.yml` continues pointing both main configurations to their current entitlement files, then run:

```bash
xcodegen generate
```

- [ ] **Step 7: Run focused Swift and compile verification**

```bash
xcrun swiftc YPersonShared/PublicCardRoute.swift YPerson/Domain/PublicSharing.swift /tmp/yperson-public-route-tests.swift -o /tmp/yperson-public-route-tests
/tmp/yperson-public-route-tests
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: harness exits `0`; Debug app compiles. The full UI behavior is not tested in this task.

- [ ] **Step 8: Commit only task files**

```bash
git add YPersonShared/PublicCardRoute.swift YPerson/Domain/PublicSharing.swift YPerson/Domain/Models.swift YPerson/Networking/APIClient.swift YPerson/Networking/SyncCoordinator.swift YPerson/Storage/AppGroupSnapshotStore.swift Config/Base.xcconfig YPerson/YPerson.entitlements YPerson/YPersonPersonal.entitlements project.yml YPerson.xcodeproj/project.pbxproj
git commit --only YPersonShared/PublicCardRoute.swift YPerson/Domain/PublicSharing.swift YPerson/Domain/Models.swift YPerson/Networking/APIClient.swift YPerson/Networking/SyncCoordinator.swift YPerson/Storage/AppGroupSnapshotStore.swift Config/Base.xcconfig YPerson/YPerson.entitlements YPerson/YPersonPersonal.entitlements project.yml YPerson.xcodeproj/project.pbxproj -m "feat: add iOS universal sharing contract"
```

---

### Task 6: Route Universal Links and complete the owner/recipient UI

**Files:**

- Modify: `YPerson/Experience/YPersonIntegrationContract.swift`
- Modify: `YPerson/App/AppDelegate.swift`
- Modify: `YPerson/App/AppFactory.swift`
- Modify: `YPerson/UI/MainTabBarController.swift`
- Modify: `YPerson/UI/CardViewController.swift`
- Modify: `YPerson/UI/ExchangeViewController.swift`
- Create: `YPerson/UI/PublicReplyReviewViewController.swift`

**Interfaces:**

```swift
enum YPersonEntryPoint: Sendable {
    case root
    case card
    case scanQR
    case privacy
    case publicCard(token: String)
}

@MainActor
func ExchangeViewController.openPublicCard(token: String)
```

`PublicReplyReviewViewController` receives one `PublicContactReply` and closures `onAccept(PersonCard)` and `onLater()`.

- [ ] **Step 1: Add a compile-breaking route case first**

Add `.publicCard(token:)` only to `YPersonEntryPoint`, then run:

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: fail at exhaustive switches in routing until the new case is handled.

- [ ] **Step 2: Handle cold and warm Universal Links once**

In `AppDelegate`, add a private parser that calls `PublicCardRoute.token(from:allowedHost:)` using `configuration.apiBaseURL.host`. Use it from:

```swift
application(_:continue:restorationHandler:)
```

and from launch options `UIApplication.LaunchOptionsKey.userActivityDictionaryKey`. Route both to `.publicCard(token:)`. Keep existing `yperson://scan` handling unchanged. Invalid hosts, HTTP URLs, malformed paths, and invalid tokens return `false` and never enter the app flow.

- [ ] **Step 3: Route to the existing Exchange tab**

In `MainTabBarController.route(to:)`, select the Exchange tab for `.publicCard`. Call `exchangeController.openPublicCard(token:)` asynchronously after its view is loaded. Do not create a fifth tab or a new navigation architecture in package 1.

`openPublicCard(token:)` must:

1. show a small loading state and call `syncCoordinator.fetchPublicCard`;
2. transform the card into an `ExchangePayload` without exchange token or expiry;
3. call the existing confirmation flow;
4. preserve the existing rule that no person is saved before tapping «Добавить человека»;
5. show the same safe error for missing, revoked, and malformed public links.

- [ ] **Step 4: Replace the primary QR with the universal URL**

In `CardViewController.showQR()`:

- require an existing own card;
- call `activatePublicLink(card:)`;
- encode the returned HTTPS URL with the existing Core Image QR generator;
- title it `Универсальный QR`;
- show `Откроется обычной камерой. YPerson собеседнику не нужен.`;
- add `Поделиться ссылкой` via `UIActivityViewController`;
- add `Отозвать ссылку` with destructive confirmation;
- on activation/network failure offer `Показать офлайн-код YPerson`.

Extract the current internal payload flow unchanged into `showOfflineYPersonQR()`. Label it `Офлайн-обмен YPerson`; never present it as the primary ordinary-camera QR.

- [ ] **Step 5: Add minimal incoming-contact confirmation UI**

`PublicReplyReviewViewController` is a compact, no-photo sheet/alert-style screen showing initials, name, and the one submitted contact method. Buttons:

- `Добавить человека` creates a local-only `PersonCard` with ID `public-reply-{reply.id}`, submitted name/email or phone, blank role/company/tagline, no audio, no meeting place, standard template;
- `Позже` closes without dismissing the backend reply;
- no automatic Contacts write, no free-form content, and no remote images.

In `AppFactory`, assign `syncCoordinator.onPublicRepliesChanged`. Present one reply at a time only when no other controller is already presented. On accept:

1. `snapshotStore.upsertPerson(card)`;
2. refresh the People screen;
3. call `dismissPublicReply(id:)`;
4. if dismiss temporarily fails, rely on the retry queue while suppressing the same reply in the current in-memory presentation session.

On next foreground refresh, present the next pending reply. Avoid a new inbox screen in this package.

- [ ] **Step 6: Compile the complete iOS package**

```bash
xcodegen generate
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: build succeeds. Fix only compiler errors or package-1 behavior exposed by this build; do not widen scope into tab-bar redesign or follow-up.

- [ ] **Step 7: Commit only task files**

```bash
git add YPerson/Experience/YPersonIntegrationContract.swift YPerson/App/AppDelegate.swift YPerson/App/AppFactory.swift YPerson/UI/MainTabBarController.swift YPerson/UI/CardViewController.swift YPerson/UI/ExchangeViewController.swift YPerson/UI/PublicReplyReviewViewController.swift YPerson.xcodeproj/project.pbxproj
git commit --only YPerson/Experience/YPersonIntegrationContract.swift YPerson/App/AppDelegate.swift YPerson/App/AppFactory.swift YPerson/UI/MainTabBarController.swift YPerson/UI/CardViewController.swift YPerson/UI/ExchangeViewController.swift YPerson/UI/PublicReplyReviewViewController.swift YPerson.xcodeproj/project.pbxproj -m "feat: complete universal sharing flow"
```

---

### Task 7: Deploy the routes and perform only the release-critical checks

**Files:**

- Modify: `deploy/yandex/serverless/api-gateway.yaml`
- Modify: `deploy/yandex/serverless/config.example.env`
- Modify: `deploy/yandex/serverless/README.md`
- Modify: `backend/tests/test_deployment_files.py`
- Modify: `Release/review-notes.md`
- Modify: `Release/manual-device-checks.md`

**Interfaces:** API Gateway must forward the AASA path and all `/p/{token}` methods to the existing FastAPI handler without redirects. Deployment env documents `YPERSON_APP_STORE_ID` and `YPERSON_APPLE_APPLICATION_IDENTIFIER`.

- [ ] **Step 1: Write a failing deployment contract test**

In `backend/tests/test_deployment_files.py`, assert the gateway/config files contain:

```python
assert "/.well-known/apple-app-site-association" in gateway
assert "/p/{token}" in gateway
assert "YPERSON_APP_STORE_ID" in example_env
assert "YPERSON_APPLE_APPLICATION_IDENTIFIER" in example_env
```

Also assert the documented Apple identifier equals `Q7A52Z2TS2.com.yperson.app`.

Run:

```bash
backend/.venv/bin/pytest backend/tests/test_deployment_files.py -q
```

Expected: fail before deployment files are updated.

- [ ] **Step 2: Update gateway and environment documentation**

Forward exact GET/POST routes from task 3 to the same serverless integration. Do not configure redirects or path rewriting for AASA. Document:

```env
YPERSON_APP_STORE_ID=
YPERSON_APPLE_APPLICATION_IDENTIFIER=Q7A52Z2TS2.com.yperson.app
```

An empty App Store ID intentionally suppresses Smart App Banner before the listing exists; populate it once App Store Connect assigns the numeric ID.

- [ ] **Step 3: Update reviewer and device-check documents**

In `Release/review-notes.md`, describe:

- Universal QR is primary and ordinary-camera compatible;
- web guest can save vCard without installing;
- contact reply requires consent and owner confirmation;
- phone/meeting place/audio/photos are not public in package 1;
- foreground refresh is the current incoming-reply delivery path.

In `Release/manual-device-checks.md`, add exactly one short physical-device matrix:

```text
[ ] Safari fetches AASA directly with HTTP 200, application/json, and no redirect.
[ ] Camera on iPhone without YPerson opens the mobile HTML card.
[ ] Camera on iPhone with YPerson opens the native confirmation screen.
[ ] Downloaded vCard imports only the approved public fields.
[ ] Valid reply appears after owner foreground refresh and is saved only after confirmation.
[ ] Revoke makes HTML, JSON, vCard, and new reply submission unavailable.
```

- [ ] **Step 4: Run the focused automated gate**

```bash
backend/.venv/bin/pytest backend/tests/test_schemas.py backend/tests/test_storage.py backend/tests/test_sync_service.py backend/tests/test_public_cards.py backend/tests/test_contract.py backend/tests/test_review_contract.py backend/tests/test_deployment_files.py -q
backend/.venv/bin/ruff check backend/app backend/tests
xcodegen generate
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: all selected backend tests pass, Ruff passes, and the iOS Debug build succeeds. Do not run full visual matrices or load tests.

- [ ] **Step 5: Run the one required production-domain smoke**

After deploying backend/schema and signing a device build:

```bash
curl -i https://d5dl7dc4rc07v7jnvlf2.p8361f8z.apigw.yandexcloud.net/.well-known/apple-app-site-association
```

Expected: direct `200`, `Content-Type: application/json`, no `Location` header, correct app ID and `/p/*` component.

Then execute every checkbox added to `Release/manual-device-checks.md` on physical iPhones. Record date, iOS versions, build number, and pass/fail only; screenshots are optional unless a defect is found.

- [ ] **Step 6: Commit only deployment and release files**

```bash
git add deploy/yandex/serverless/api-gateway.yaml deploy/yandex/serverless/config.example.env deploy/yandex/serverless/README.md backend/tests/test_deployment_files.py Release/review-notes.md Release/manual-device-checks.md
git commit --only deploy/yandex/serverless/api-gateway.yaml deploy/yandex/serverless/config.example.env deploy/yandex/serverless/README.md backend/tests/test_deployment_files.py Release/review-notes.md Release/manual-device-checks.md -m "docs: prepare universal sharing pilot"
```

## Completion Gate

Package 1 is complete only when all of these statements are true:

- the backend stores no raw public token and exposes no private/local card fields;
- unknown and revoked links are indistinguishable to a guest;
- a reply cannot be submitted without explicit consent and exactly one contact method;
- an incoming reply does not become a local person until the owner confirms;
- revoke blocks HTML, JSON, vCard, and new replies;
- the installed-app and browser paths both work from one production HTTPS QR;
- the focused backend gate, Ruff, and Debug iOS build pass;
- the six physical-device smoke checks are recorded;
- no package-2 follow-up UI, package-3 Today screen, package-4 APNs delivery, subscription, photos, App Clip, or web account was added.
