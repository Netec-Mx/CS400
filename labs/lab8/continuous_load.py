import argparse
import json
import math
import os
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
  
from couchbase.auth import PasswordAuthenticator
from couchbase.cluster import Cluster
from couchbase.options import ClusterOptions
  
parser = argparse.ArgumentParser()
parser.add_argument("--target-ops", type=int, default=5000)
parser.add_argument("--workers", type=int, default=16)
parser.add_argument("--interval", type=int, default=10)
args = parser.parse_args()
  
cluster = Cluster(
    os.environ["CB_CONNSTR"],
    ClusterOptions(
        PasswordAuthenticator(
            os.environ["CB_USERNAME"],
            os.environ["CB_PASSWORD"]
        )
    )
)
  
cluster.wait_until_ready(timedelta(seconds=30))
  
collection = (
    cluster.bucket("lab8-rebalance")
    .scope("workload")
    .collection("items")
)
  
lock = threading.Lock()
  
metrics = {
    "ops": 0,
    "gets": 0,
    "upserts": 0,
    "errors": 0,
    "latencies_ms": []
}
  
stop = False
  
per_worker_target = max(
    args.target_ops / args.workers,
    1
)
  
sleep_per_op = 1.0 / per_worker_target
  
def percentile(values, pct):
    if not values:
        return 0.0
  
    ordered = sorted(values)
  
    pos = min(
        math.ceil(
            (pct / 100) * len(ordered)
        ) - 1,
        len(ordered) - 1
    )
  
    return ordered[max(pos, 0)]
  
def worker(worker_id):
    global stop
  
    while not stop:
        started = time.perf_counter()
        key_number = random.randrange(0, 120_000)
        key = f"item_{key_number:09d}"
  
        try:
            if random.random() < 0.70:
                collection.get(key)
                op_type = "get"
            else:
                collection.upsert(
                    key,
                    {
                        "type": "load_item",
                        "counter": key_number,
                        "updated_by": worker_id,
                        "updated_at": time.time(),
                        "payload": "x" * 900
                    }
                )
                op_type = "upsert"
  
            latency = (
                time.perf_counter() - started
            ) * 1000
  
            with lock:
                metrics["ops"] += 1
                metrics["latencies_ms"].append(latency)
  
                if op_type == "get":
                    metrics["gets"] += 1
                else:
                    metrics["upserts"] += 1
  
        except Exception:
            with lock:
                metrics["errors"] += 1
  
        elapsed = time.perf_counter() - started
  
        if elapsed < sleep_per_op:
            time.sleep(sleep_per_op - elapsed)
  
threads = ThreadPoolExecutor(
    max_workers=args.workers
)
  
for i in range(args.workers):
    threads.submit(worker, i)
  
print("Continuous load started", flush=True)
  
try:
    while True:
        time.sleep(args.interval)
  
        with lock:
            snapshot = {
                key: (
                    list(value)
                    if isinstance(value, list)
                    else value
                )
                for key, value in metrics.items()
            }
  
            metrics["ops"] = 0
            metrics["gets"] = 0
            metrics["upserts"] = 0
            metrics["errors"] = 0
            metrics["latencies_ms"] = []
  
        lat = snapshot["latencies_ms"]
        successful = snapshot["ops"]
  
        result = {
            "timestamp": time.time(),
            "interval_seconds": args.interval,
            "ops_per_sec": round(
                successful / args.interval,
                1
            ),
            "get_ratio": round(
                snapshot["gets"] /
                max(successful, 1),
                3
            ),
            "upsert_ratio": round(
                snapshot["upserts"] /
                max(successful, 1),
                3
            ),
            "errors": snapshot["errors"],
            "p50_ms": round(
                percentile(lat, 50),
                2
            ),
            "p95_ms": round(
                percentile(lat, 95),
                2
            ),
            "p99_ms": round(
                percentile(lat, 99),
                2
            )
        }
  
        print(
            json.dumps(result),
            flush=True
        )
  
except KeyboardInterrupt:
    stop = True
    threads.shutdown(wait=False)
    cluster.close()
