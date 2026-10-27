"""Sync the reviewed README to Docker Hub; no image or tag operations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.request

BASE = "https://hub.docker.com"
REPOSITORY = "/v2/repositories/oeschme/papermc/"
DESCRIPTION = "PaperMC server image with pinned builds, verified downloads and optional offline startup."


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request(method, path, payload=None, token=None):
    headers = {"Content-Type": "application/json", "User-Agent": "papermc-overview-sync",
               "Cache-Control": "no-cache"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None if payload is None else json.dumps(payload).encode()
    operation = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect()).open(operation, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        message = f"Docker Hub returned HTTP {error.code} for {method} {path}."
        if error.code == 403:
            message += " The token needs repository-management permission to edit the overview."
        raise SystemExit(message) from None
    except urllib.error.URLError:
        raise SystemExit("Docker Hub connection failed; credential details omitted.") from None


def normalized(value):
    return value.replace("\r\n", "\n").rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true")
    action.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    overview = Path("README.md").read_text(encoding="utf-8")
    encoded = overview.encode("utf-8")
    if not overview.strip() or len(encoded) > 25000 or len(DESCRIPTION.encode()) > 100:
        raise SystemExit("Overview must be nonempty and within Docker Hub content limits.")
    print(f"Reviewed overview: {len(encoded)} bytes, SHA-256 {hashlib.sha256(encoded).hexdigest()}")
    if not args.apply:
        return
    secret = os.environ.get("DOCKERHUB_TOKEN")
    if not secret:
        raise SystemExit("DOCKERHUB_TOKEN must be supplied securely through the environment.")
    auth = request("POST", "/v2/auth/token", {"identifier": "oeschme", "secret": secret})
    token = auth["access_token"]
    current = request("GET", REPOSITORY, token=token)
    if (normalized(current.get("full_description", "")) == normalized(overview)
            and current.get("description") == DESCRIPTION):
        print("Overview already matches; no update needed.")
        return
    request("PATCH", REPOSITORY, {"description": DESCRIPTION, "full_description": overview}, token)
    # Confirm using a separate public read, without the credentials.
    confirmed = request("GET", REPOSITORY)
    if (normalized(confirmed.get("full_description", "")) != normalized(overview)
            or confirmed.get("description") != DESCRIPTION):
        raise SystemExit("Overview update was not confirmed by the public API.")
    print("Public Docker Hub overview and short description verified.")


if __name__ == "__main__":
    main()
