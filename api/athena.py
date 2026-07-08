"""
Athena query helper — runs SQL against the Gold Glue catalog database
and caches results in-process for CACHE_TTL seconds (default 5 min).

The module-level cache survives across Lambda invocations within the same
container, so repeated dashboard loads don't each pay Athena startup cost.
"""

import os
import time
import boto3

DB          = os.environ["ATHENA_DB"]
WORKGROUP   = os.environ["ATHENA_WORKGROUP"]
OUTPUT      = os.environ["ATHENA_OUTPUT"]
REGION      = os.environ.get("AWS_REGION", "us-west-2")
CACHE_TTL   = int(os.environ.get("CACHE_TTL", "300"))

_cache: dict[str, tuple[float, list[dict]]] = {}


def query(sql: str) -> list[dict]:
    now = time.time()
    if sql in _cache and now - _cache[sql][0] < CACHE_TTL:
        return _cache[sql][1]

    client = boto3.client("athena", region_name=REGION)

    resp = client.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": DB},
        WorkGroup=WORKGROUP,
    )
    qid = resp["QueryExecutionId"]

    while True:
        status = client.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status["QueryExecution"]["Status"].get("StateChangeReason", "")
            raise RuntimeError(f"Athena {state}: {reason}")
        time.sleep(0.5)

    result = client.get_query_results(QueryExecutionId=qid)
    rows = result["ResultSet"]["Rows"]
    if len(rows) < 2:
        _cache[sql] = (now, [])
        return []

    headers = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data = [
        {
            headers[i]: _coerce(cell.get("VarCharValue"))
            for i, cell in enumerate(row["Data"])
            if i < len(headers)
        }
        for row in rows[1:]
    ]

    _cache[sql] = (now, data)
    return data


def _coerce(val: str | None):
    if val is None or val == "":
        return None
    if val.lower() == "true":
        return True
    if val.lower() == "false":
        return False
    try:
        i = int(val)
        return i
    except ValueError:
        pass
    try:
        return float(val)
    except ValueError:
        pass
    return val
