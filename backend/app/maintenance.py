"""Database maintenance commands that do not expose profile or token contents."""

import sys
from datetime import UTC, datetime

from sqlalchemy.exc import SQLAlchemyError

from app.settings import Settings
from app.storage import create_session_factory, prune_expired_exchange_tokens


def main() -> int:
    """Prune expired exchange-token hashes and print only the count removed."""

    if sys.argv[1:] != ["prune-exchange-tokens"]:
        return 2

    engine = None
    try:
        engine, session_factory = create_session_factory(Settings())
        with session_factory.begin() as session:
            pruned = prune_expired_exchange_tokens(session, datetime.now(UTC))
    except (SQLAlchemyError, ValueError):
        return 1
    finally:
        if engine is not None:
            engine.dispose()

    print(pruned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
