#!/usr/bin/env python3
"""Validate rendered manifests against real CRD schemas, offline.

Usage:
    python3 -I validate-manifests.py --crds <file>... --manifests <file>...

CRD files are scanned for CustomResourceDefinition documents; every manifest
document is then validated against the matching CRD's openAPIV3Schema. This
catches field-name and type errors without needing the CRDs installed on a
cluster, which matters here because the hosted control plane takes ~20 minutes
to stand up.

Exit code is non-zero if any document fails or has no matching CRD.
"""
import argparse
import sys

import yaml
from jsonschema import Draft4Validator


# Kubernetes API groups that are served by the API server itself rather than
# by a CustomResourceDefinition. "v1" covers the core group (Secret, Namespace,
# ServiceAccount, ...), which has no group prefix at all.
BUILTIN_GROUPS = {
    "v1",
    "apps",
    "batch",
    "autoscaling",
    "policy",
    "rbac.authorization.k8s.io",
    "networking.k8s.io",
    "storage.k8s.io",
    "apiextensions.k8s.io",
    "admissionregistration.k8s.io",
    "coordination.k8s.io",
    "scheduling.k8s.io",
    "certificates.k8s.io",
}


def load_docs(paths):
    docs = []
    for p in paths:
        with open(p, "r", encoding="utf-8") as fh:
            for doc in yaml.safe_load_all(fh):
                if isinstance(doc, dict) and doc.get("kind"):
                    docs.append((p, doc))
    return docs


def build_schema_index(crd_docs):
    """Map (apiVersion, kind) -> openAPIV3Schema for every CRD version."""
    index = {}
    for _, doc in crd_docs:
        if doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc.get("spec", {})
        group = spec.get("group")
        kind = spec.get("names", {}).get("kind")
        for ver in spec.get("versions", []):
            schema = (ver.get("schema") or {}).get("openAPIV3Schema")
            if schema:
                index[(f"{group}/{ver['name']}", kind)] = schema
    return index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--crds", nargs="+", required=True)
    ap.add_argument("--manifests", nargs="+", required=True)
    args = ap.parse_args()

    index = build_schema_index(load_docs(args.crds))
    print(f"loaded {len(index)} CRD schema versions")

    failures = 0
    checked = 0
    for path, doc in load_docs(args.manifests):
        key = (doc.get("apiVersion"), doc.get("kind"))
        name = doc.get("metadata", {}).get("name", "<unnamed>")
        label = f"{doc.get('kind')}/{name}"

        schema = index.get(key)
        if schema is None:
            # Built-in Kubernetes APIs ship no CRD, so there is nothing to
            # validate against here; only an unknown *custom* group is a fault.
            group = (doc.get("apiVersion") or "").split("/")[0]
            if group in BUILTIN_GROUPS:
                print(f"  skip  {label} (built-in API, no CRD)")
                continue
            print(f"  MISS  {label}: no CRD schema for {key[0]}")
            failures += 1
            continue

        errors = sorted(Draft4Validator(schema).iter_errors(doc), key=lambda e: list(e.path))
        checked += 1
        if errors:
            failures += 1
            print(f"  FAIL  {label} ({path})")
            for e in errors[:8]:
                loc = ".".join(str(x) for x in e.path) or "<root>"
                print(f"          {loc}: {e.message}")
        else:
            print(f"  OK    {label}")

    print(f"\nvalidated {checked} documents, {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
