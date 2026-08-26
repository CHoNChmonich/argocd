"""Простой генератор трафика: создаёт заказы и читает их (греет кэш).

    python scripts/load.py --orders http://orders.shop.localtest.me -n 50
"""

import argparse
import random
import sys
import time
import urllib.request
import json

SKUS = ["kbd-001", "mouse-002", "mon-003", "nope-999"]


def call(method: str, url: str, body: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--orders", default="http://orders.shop.localtest.me")
    p.add_argument("-n", type=int, default=20)
    p.add_argument("--delay", type=float, default=0.2)
    a = p.parse_args()

    created: list[int] = []
    for i in range(a.n):
        sku = random.choice(SKUS)
        status, body = call("POST", f"{a.orders}/orders", {"sku": sku, "qty": random.randint(1, 3)})
        print(f"POST /orders {sku} -> {status} {body.get('id') or body.get('detail')}")
        if status == 201:
            created.append(body["id"])
        if created:
            oid = random.choice(created)
            status, body = call("GET", f"{a.orders}/orders/{oid}")
            print(f"GET  /orders/{oid} -> {status} source={body.get('source')}")
        time.sleep(a.delay)
    return 0


if __name__ == "__main__":
    sys.exit(main())
