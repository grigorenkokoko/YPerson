"""Apply the complete YPerson YDB schema using environment/metadata credentials."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import ydb

BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from app.ydb_schema import TABLE_DDL, apply_schema


def main() -> int:
    endpoint = os.environ["YDB_ENDPOINT"]
    database = os.environ["YDB_DATABASE"]
    config = ydb.DriverConfig(
        endpoint=endpoint,
        database=database,
        credentials=ydb.credentials_from_env_variables(),
        root_certificates=ydb.load_ydb_root_certificate(),
    )
    with ydb.Driver(config) as driver:
        driver.wait(timeout=10, fail_fast=True)
        with ydb.QuerySessionPool(driver) as pool:
            completed = apply_schema(
                pool,
                lambda table_name: driver.table_client.describe_table(
                    f"{database.rstrip('/')}/{table_name}"
                ),
            )
    if completed != len(TABLE_DDL):
        raise RuntimeError("YDB schema application was incomplete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
