#!/usr/bin/env python3
  
import argparse
import base64
import json
import os
import subprocess
import time
import urllib.request
  
NAMESPACE = os.environ.get(
    "CB_NAMESPACE",
    "couchbase"
)
  
CLUSTER = os.environ.get(
    "CB_CLUSTER",
    "cb-cs400"
)
  
USER = os.environ["CB_USER"]
PASSWORD = os.environ["CB_PASS"]
API = "http://localhost:8091"
  
def run(*args):
    result = subprocess.run(
        args,
        text=True,
        capture_output=True,
        check=True
    )
    return result.stdout
  
def get_cluster_cr():
    return json.loads(
        run(
            "kubectl",
            "get",
            "couchbasecluster",
            CLUSTER,
            "-n",
            NAMESPACE,
            "-o",
            "json"
        )
    )
  
def data_index(cr):
    for i, server in enumerate(
        cr["spec"]["servers"]
    ):
        if server["name"] == "data":
            return i
  
    raise RuntimeError(
        "No existe server class data"
    )
  
def patch_size(size):
    cr = get_cluster_cr()
    index = data_index(cr)
  
    current = (
        cr["spec"]["servers"]
        [index]["size"]
    )
  
    patch = json.dumps(
        [{
            "op": "replace",
            "path":
                f"/spec/servers/{index}/size",
            "value": size
        }]
    )
  
    print(
        f"Declarando Data "
        f"{current} -> {size}"
    )
  
    print(
        run(
            "kubectl",
            "patch",
            "couchbasecluster",
            CLUSTER,
            "-n",
            NAMESPACE,
            "--type=json",
            f"-p={patch}"
        ).strip()
    )
  
def api_get(path):
    req = urllib.request.Request(
        API + path
    )
  
    token = base64.b64encode(
        f"{USER}:{PASSWORD}".encode()
    ).decode()
  
    req.add_header(
        "Authorization",
        f"Basic {token}"
    )
  
    with urllib.request.urlopen(
        req,
        timeout=15
    ) as response:
        return json.load(response)
  
def wait_stable(
    expected_data,
    timeout=1200
):
    started = time.time()
    stable = 0
  
    while time.time() - started < timeout:
        cluster = api_get(
            "/pools/default"
        )
  
        progress = api_get(
            "/pools/default/rebalanceProgress"
        )
  
        data_nodes = [
            node
            for node in cluster["nodes"]
            if "kv" in node.get(
                "services",
                []
            )
        ]
  
        unhealthy = [
            node
            for node in cluster["nodes"]
            if (
                node.get("status")
                != "healthy"
                or node.get(
                    "clusterMembership"
                ) != "active"
            )
        ]
  
        rebalance = progress.get(
            "status",
            "unknown"
        )
  
        ok = (
            len(data_nodes)
            == expected_data
            and not unhealthy
            and rebalance == "none"
        )
  
        stable = (
            stable + 1
            if ok
            else 0
        )
  
        print(
            f"Data={len(data_nodes)}/"
            f"{expected_data} "
            f"unhealthy={len(unhealthy)} "
            f"rebalance={rebalance} "
            f"stable={stable}/3"
        )
  
        if stable >= 3:
            return cluster
  
        time.sleep(5)
  
    raise TimeoutError(
        "El clúster no convergió "
        "dentro del timeout"
    )
  
def verify(
    cluster,
    expected_data
):
    data_nodes = [
        node
        for node in cluster["nodes"]
        if "kv" in node.get(
            "services",
            []
        )
    ]
  
    unhealthy = [
        node
        for node in cluster["nodes"]
        if (
            node.get("status")
            != "healthy"
            or node.get(
                "clusterMembership"
            ) != "active"
        )
    ]
  
    summary = {
        "desired_data_size":
            expected_data,
        "actual_data_nodes":
            len(data_nodes),
        "unhealthy":
            unhealthy,
        "rebalanceStatus":
            cluster.get(
                "rebalanceStatus"
            )
    }
  
    print(
        json.dumps(
            summary,
            indent=2
        )
    )
  
    if (
        len(data_nodes)
        != expected_data
        or unhealthy
    ):
        raise RuntimeError(
            "La validación final falló"
        )
  
parser = argparse.ArgumentParser()
  
parser.add_argument(
    "--size",
    required=True,
    type=int
)
  
args = parser.parse_args()
  
patch_size(args.size)
  
cluster = wait_stable(
    args.size
)
  
verify(
    cluster,
    args.size
)