"""Create the initial durable YPerson backend tables."""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "20260818_0001"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "profiles",
        sa.Column("installation_id", sa.String(length=128), nullable=False),
        sa.Column("card", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("apns_token", sa.String(length=256), nullable=True),
        sa.Column("update_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("installation_id"),
    )
    op.create_table(
        "exchange_tokens",
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("owner_installation_id", sa.String(length=128), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("claimed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["owner_installation_id"], ["profiles.installation_id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("token_hash"),
    )
    op.create_table(
        "moderation_actions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("reporter_installation_id", sa.String(length=128), nullable=False),
        sa.Column("category", sa.String(length=32), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["reporter_installation_id"], ["profiles.installation_id"], ondelete="CASCADE"
        ),
        sa.CheckConstraint(
            "category IS NULL OR category IN ('spam', 'abusive_content', 'impersonation')",
            name="ck_moderation_actions_category",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "blocked_connections",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("installation_id", sa.String(length=128), nullable=False),
        sa.Column("blocked_reference", sa.String(length=64), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("CURRENT_TIMESTAMP"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["installation_id"], ["profiles.installation_id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    op.drop_table("blocked_connections")
    op.drop_table("moderation_actions")
    op.drop_table("exchange_tokens")
    op.drop_table("profiles")
