#!/usr/bin/env python3
"""Fail closed unless exact-SHA/branch iOS CI and all required jobs succeeded.

Uses authenticated `gh api` (GH_TOKEN in Actions; gh login also works locally).
Only reads GitHub. No waiting, dispatching, status filtering, or bypass option.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlencode

EXPECTED_JOBS = ("Native iOS simulator build", "Native iOS unit tests", "Relay tests", "Connector tests")


class GateError(RuntimeError):
    pass


def gh_api(path):
    try:
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com", "-H", "Accept: application/vnd.github+json",
             "-H", "X-GitHub-Api-Version: 2022-11-28", path],
            check=True, capture_output=True, text=True, timeout=60,
        )
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        # Do not echo response bodies or credentials on API/auth/network errors.
        raise GateError("GitHub API request failed; check authentication, permissions and availability") from exc


def complete_list(payload, key):
    items = payload.get(key)
    if (not isinstance(items, list) or type(payload.get("total_count")) is not int
            or len(items) != payload["total_count"] or not all(isinstance(item, dict) for item in items)):
        # Conservative cap: never approve from partial API results (>100 items).
        raise GateError(f"Incomplete or malformed {key} response; refusing partial evidence")
    return items


def verify(repository, sha, branch, fetch=gh_api):
    if (not re.fullmatch(r"[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+", repository)
            or not re.fullmatch(r"[0-9a-f]{40}", sha) or not branch):
        raise GateError("An owner/repository, full lowercase commit SHA and branch are required")
    base = f"repos/{repository}/actions"
    query = urlencode(dict(head_sha=sha, branch=branch, per_page=100))
    try:
        runs = complete_list(fetch(f"{base}/workflows/ios-ci.yml/runs?{query}"), "workflow_runs")
        if not runs:
            raise GateError("No iOS CI run exists for this exact SHA and branch")
        run = max(runs, key=lambda item: (item["run_number"], item["id"]))
        # PR workflows may test a synthetic merge, not the standalone release SHA.
        if run.get("event") not in ("push", "workflow_dispatch"):
            raise GateError("Latest iOS CI run must be a push or workflow_dispatch run")
        if (run.get("head_sha") != sha or run.get("head_branch") != branch
                or run.get("status") != "completed" or run.get("conclusion") != "success"):
            raise GateError("Latest iOS CI run is not successful for the exact SHA and branch")
        if any(type(run[key]) is not int or run[key] < 1 for key in ("id", "run_number", "run_attempt")):
            raise GateError("Invalid run identity")
        jobs = complete_list(fetch(
            f"{base}/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100"), "jobs")
        for name in EXPECTED_JOBS:
            matches = [job for job in jobs if job.get("name") == name]
            if (len(matches) != 1 or matches[0].get("status") != "completed"
                    or matches[0].get("conclusion") != "success"):
                raise GateError(f"Required job did not complete successfully: {name}")
        # A rerun starting while jobs were read invalidates their evidence.
        current = fetch(f"{base}/runs/{run['id']}")
        keys = ("id", "run_attempt", "head_sha", "head_branch", "status", "conclusion", "event")
        if any(current.get(key) != run[key] for key in keys):
            raise GateError("CI run changed during verification; retry after CI completes")
        # A newer run can appear even when the selected run itself is unchanged.
        latest_runs = complete_list(fetch(f"{base}/workflows/ios-ci.yml/runs?{query}"), "workflow_runs")
        newest = max(latest_runs, key=lambda item: (item["run_number"], item["id"]), default={})
        if any(newest.get(key) != run[key] for key in (*keys, "run_number")):
            raise GateError("Latest CI run changed during verification; retry after CI completes")
        return run["id"]
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise GateError("Malformed GitHub API evidence; release blocked") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--branch", default=os.environ.get("GITHUB_REF_NAME", ""))
    args = parser.parse_args()
    try:
        run_id = verify(args.repository, args.sha, args.branch)
    except GateError as exc:
        print(f"Release blocked: {exc}", file=sys.stderr)
        return 1
    print(f"Release gate passed: iOS CI run {run_id}, SHA {args.sha}, branch {args.branch}; all four required jobs succeeded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
