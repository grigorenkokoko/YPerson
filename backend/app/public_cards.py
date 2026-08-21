"""Privacy-minimized rendering and persistence for universal public cards."""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from html import escape
from typing import Protocol
from urllib.parse import parse_qs
from uuid import UUID, uuid4

from .schemas import PersonCard, validate_public_link_token
from .storage import PublicCardRecord

PUBLIC_REPLY_LIFETIME = timedelta(days=30)
MAX_FORM_BODY_BYTES = 4_096

PUBLIC_CARD_HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": (
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    ),
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Robots-Tag": "noindex, nofollow",
}


class PublicCardStore(Protocol):
    """Storage operations required by unauthenticated public-card requests."""

    def resolve_public_card(self, raw_token: str) -> PublicCardRecord | None:
        """Resolve an active public card without returning its raw token."""

    def create_public_reply(
        self,
        raw_token: str,
        reply_id: str,
        name: str,
        email: str | None,
        phone: str | None,
        expires_at: datetime,
    ) -> None:
        """Persist one explicitly consented reply for an active public link."""


class PublicCardService:
    """Apply public-token validation and server-owned reply retention."""

    def __init__(
        self,
        store: PublicCardStore,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._store = store
        self._clock = clock or (lambda: datetime.now(UTC))

    def card(self, raw_token: str) -> PublicCardRecord | None:
        """Return an active card for one canonical token."""

        validate_public_link_token(raw_token)
        return self._store.resolve_public_card(raw_token)

    def submit_reply(
        self,
        raw_token: str,
        reply_id: str,
        name: str,
        email: str | None,
        phone: str | None,
    ) -> None:
        """Persist a reply with a server-side 30-day expiry."""

        validate_public_link_token(raw_token)
        self._store.create_public_reply(
            raw_token,
            reply_id,
            name,
            email,
            phone,
            self._clock() + PUBLIC_REPLY_LIFETIME,
        )


def public_card_json(card: PersonCard) -> dict[str, str]:
    """Return only the package-one fields approved for public sharing."""

    return {
        "name": card.name,
        "role": card.role,
        "company": card.company,
        "email": card.email,
        "tagline": card.tagline,
        "templateID": card.templateID,
    }


def render_public_card_html(
    card: PersonCard,
    *,
    replies_path: str,
    vcard_path: str,
    app_store_id: str,
    current_https_url: str,
) -> str:
    """Render a script-free public card and explicit-consent reply form."""

    fields = public_card_json(card)
    escaped = {key: escape(value, quote=True) for key, value in fields.items()}
    initials = escape(_initials(card.name), quote=True)
    banner = ""
    if app_store_id:
        banner = (
            '<meta name="apple-itunes-app" '
            f'content="app-id={escape(app_store_id, quote=True)}, '
            f'app-argument={escape(current_https_url, quote=True)}">'
        )
    reply_id = str(uuid4())
    return f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{banner}
<title>{escaped["name"]}</title>
<style>
:root {{ color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }}
body {{ margin: 0; background: #f3f0e8; color: #17211c; }}
main {{ width: min(38rem, calc(100% - 2rem)); margin: 3rem auto; }}
.card, form {{ background: #fff; border-radius: 1.5rem; padding: 1.5rem; margin-bottom: 1rem; }}
.initials {{ width: 4rem; height: 4rem; border-radius: 50%; display: grid; place-items: center;
background: #173d33; color: white; font-size: 1.4rem; }}
h1 {{ margin-bottom: .25rem; }} p {{ line-height: 1.5; }}
label {{ display: block; margin-top: 1rem; }}
input {{ box-sizing: border-box; width: 100%; padding: .75rem; margin-top: .35rem; }}
.consent {{ display: flex; gap: .6rem; align-items: start; }} .consent input {{ width: auto; }}
button, .download {{ display: inline-block; border: 0; border-radius: 999px; padding: .8rem 1rem;
background: #173d33; color: white; text-decoration: none; margin-top: 1rem; }}
</style>
</head>
<body>
<main>
<article class="card" data-template="{escaped["templateID"]}">
<div class="initials" aria-hidden="true">{initials}</div>
<h1>{escaped["name"]}</h1>
<p>{escaped["role"]} · {escaped["company"]}</p>
<p>{escaped["tagline"]}</p>
<p>{escaped["email"]}</p>
<a class="download" href="{escape(vcard_path, quote=True)}" download>Сохранить vCard</a>
</article>
<form method="post" action="{escape(replies_path, quote=True)}">
<h2>Оставить свой контакт</h2>
<input type="hidden" name="replyID" value="{reply_id}">
<label>Имя<input name="name" maxlength="80" required></label>
<label>Email<input name="email" type="email" maxlength="256"></label>
<label>Телефон<input name="phone" type="tel" maxlength="256"></label>
<label class="consent"><input name="consent" type="checkbox" value="on" required>
Я согласен отправить имя и один способ связи владельцу карточки.</label>
<button type="submit">Отправить</button>
</form>
</main>
</body>
</html>"""


def render_vcard(card: PersonCard) -> str:
    """Render a vCard containing only approved public fields."""

    return "\r\n".join(
        (
            "BEGIN:VCARD",
            "VERSION:3.0",
            f"FN:{escape_vcard(card.name)}",
            f"TITLE:{escape_vcard(card.role)}",
            f"ORG:{escape_vcard(card.company)}",
            f"EMAIL:{escape_vcard(card.email)}",
            f"NOTE:{escape_vcard(card.tagline)}",
            "END:VCARD",
            "",
        )
    )


def escape_vcard(value: str) -> str:
    """Escape text according to the vCard text-value rules used by package one."""

    return (
        value.replace("\\", "\\\\")
        .replace("\r", "")
        .replace("\n", "\\n")
        .replace(";", "\\;")
        .replace(",", "\\,")
    )


def parse_reply_form(raw: bytes) -> tuple[str, str, str | None, str | None]:
    """Parse one strict URL-encoded reply without accepting repeated scalars."""

    try:
        form = parse_qs(raw.decode("utf-8"), keep_blank_values=True, strict_parsing=True)
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("invalid reply form") from error

    allowed = {"replyID", "name", "email", "phone", "consent"}
    if not set(form).issubset(allowed) or any(len(values) != 1 for values in form.values()):
        raise ValueError("invalid reply form")

    reply_id = _scalar(form, "replyID")
    name = _scalar(form, "name").strip()
    consent = _scalar(form, "consent")
    email = _optional_scalar(form, "email")
    phone = _optional_scalar(form, "phone")
    try:
        parsed_reply_id = UUID(reply_id)
    except ValueError as error:
        raise ValueError("invalid reply form") from error
    if str(parsed_reply_id) != reply_id:
        raise ValueError("invalid reply form")
    if not name or len(name) > 80 or consent != "on":
        raise ValueError("invalid reply form")
    if (email is None) == (phone is None):
        raise ValueError("invalid reply form")
    if (email is not None and len(email) > 256) or (phone is not None and len(phone) > 256):
        raise ValueError("invalid reply form")
    return reply_id, name, email, phone


def _scalar(form: dict[str, list[str]], key: str) -> str:
    try:
        return form[key][0]
    except KeyError as error:
        raise ValueError("invalid reply form") from error


def _optional_scalar(form: dict[str, list[str]], key: str) -> str | None:
    values = form.get(key)
    if values is None:
        return None
    return values[0].strip() or None


def _initials(name: str) -> str:
    words = name.split()
    initials = "".join(word[0] for word in words[:2] if word)
    return initials.upper() or "YP"
