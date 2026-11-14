#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyjwt[crypto]"]
# ///
"""Attach the newest processed build to the TestFlight beta groups, and get it to external testers
(their group, "What to Test", Beta App Review).

Uploading a build and distributing it are different acts, and only the first is automated by
fastlane here: the upload lane sets `skip_waiting_for_build_processing` because waiting costs
ten to thirty minutes on a runner billed at ten times, which also means Apple has not finished
processing when that job ends and fastlane cannot attach anything. A build left unattached is
`VALID` in App Store Connect, listed by every query, and installable by nobody — a state that
looks exactly like a successful release from the outside.

Needs no Apple hardware: it is authenticated HTTPS and nothing else.

Credentials come from the environment, the same three every other App Store Connect call uses:
ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64. Nothing is ever printed.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com/v1"
APP_ID = "6806630985"
GROUP_NAME = "Internal"
EXTERNAL_GROUP_NAME = "Friends"
LOCALE = "en-US"
# Shown to testers with each build. Per-build release notes are not available where this runs.
WHATS_NEW = "Fixes and improvements."
# Apple's own processing is the slow part and is not ours to hurry. Generous, because the cost of
# waiting here is a runner at 1x, and the cost of giving up early is a release nobody can install.
POLL_SECONDS = 20
POLL_ATTEMPTS = 45


def token() -> str:
    key = base64.b64decode(os.environ["ASC_KEY_P8_BASE64"]).decode()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    request = urllib.request.Request(
        f"{BASE}/{path}",
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode()[:400]
        raise SystemExit(f"{method} {path} -> HTTP {error.code}: {detail}") from error


def group_id() -> str:
    for group in call("GET", f"apps/{APP_ID}/betaGroups").get("data", []):
        if group["attributes"]["name"] == GROUP_NAME:
            return group["id"]
    raise SystemExit(f"no beta group named {GROUP_NAME!r}")


def external_group_id(app: str) -> str:
    for group in call("GET", f"apps/{app}/betaGroups").get("data", []):
        attributes = group["attributes"]
        if attributes["name"] == EXTERNAL_GROUP_NAME:
            if attributes.get("isInternalGroup"):
                raise SystemExit(f"beta group {EXTERNAL_GROUP_NAME!r} is an internal group")
            return group["id"]
    raise SystemExit(f"no external beta group named {EXTERNAL_GROUP_NAME!r}")


def distribute_external(app: str, build: dict) -> None:
    """Gets the build to the external testers: attach it to their group, give it its "What to
    Test" text, and submit it to Beta App Review when it has not been reviewed yet.

    External testers install only reviewed builds. Apple reviews the first build of each
    marketing version and passes later builds of that version without another review, so a
    build already in a reviewed state needs no submission. The invite emails and the public link
    work on their own once the build is approved; nothing here invites anyone.
    """
    group = external_group_id(app)
    build_id = build["id"]
    version = build["attributes"].get("version")

    attached = {b["id"] for b in call("GET", f"betaGroups/{group}/builds").get("data", [])}
    if build_id not in attached:
        call(
            "POST",
            f"betaGroups/{group}/relationships/builds",
            {"data": [{"type": "builds", "id": build_id}]},
        )
        print(f"build {version} attached to {EXTERNAL_GROUP_NAME}")

    localizations = call("GET", f"builds/{build_id}/betaBuildLocalizations").get("data", [])
    if not any(loc["attributes"].get("locale") == LOCALE for loc in localizations):
        call(
            "POST",
            "betaBuildLocalizations",
            {
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": LOCALE, "whatsNew": WHATS_NEW},
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
        print(f"build {version} given its What to Test text")

    detail = call("GET", f"builds/{build_id}/buildBetaDetail")["data"]
    # Testers are told when an approved build arrives, instead of having to look.
    if not detail["attributes"].get("autoNotifyEnabled"):
        call(
            "PATCH",
            f"buildBetaDetails/{detail['id']}",
            {"data": {"type": "buildBetaDetails", "id": detail["id"], "attributes": {"autoNotifyEnabled": True}}},
        )

    state = detail["attributes"].get("externalBuildState")
    if state == "READY_FOR_BETA_SUBMISSION":
        review = call("GET", f"apps/{app}/betaAppReviewDetail")["data"]["attributes"]
        if not (review.get("contactPhone") and review.get("contactEmail")):
            # Apple refuses a submission without review contact details, and one that went out
            # incomplete would be rejected rather than reviewed: wait for the test information.
            print(f"::warning::build {version} not submitted to Beta App Review: the review contact is not set")
            return
        call(
            "POST",
            "betaAppReviewSubmissions",
            {
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
                }
            },
        )
        print(f"build {version} submitted to Beta App Review")
    elif state in {"WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}:
        print(f"build {version} for external testers: {state}")
    else:
        # Rejected, expired, missing compliance: the build reached nobody outside, which a green
        # job must not hide.
        raise SystemExit(f"build {version} cannot reach external testers: {state}")


def main() -> None:
    wanted = sys.argv[1] if len(sys.argv) > 1 else None
    group = group_id()

    # Read membership from the GROUP's side. The obvious direction — a build's own `betaGroups` —
    # answers 403 `GET_RELATED not allowed`, which reads like a permissions problem and is not.
    attached = {b["id"] for b in call("GET", f"betaGroups/{group}/builds").get("data", [])}

    for attempt in range(POLL_ATTEMPTS):
        builds = call("GET", f"builds?filter[app]={APP_ID}&sort=-uploadedDate&limit=10").get("data", [])
        if wanted:
            candidates = [b for b in builds if b["attributes"].get("version") == wanted]
        else:
            candidates = builds[:1]

        if candidates:
            build = candidates[0]
            state = build["attributes"].get("processingState")
            version = build["attributes"].get("version")
            if state == "VALID":
                if build["id"] in attached:
                    print(f"build {version} is already distributed to {GROUP_NAME}")
                else:
                    call(
                        "POST",
                        f"betaGroups/{group}/relationships/builds",
                        {"data": [{"type": "builds", "id": build["id"]}]},
                    )
                    print(f"build {version} attached to {GROUP_NAME}")
                distribute_external(APP_ID, build)
                return
            if state in {"FAILED", "INVALID"}:
                raise SystemExit(f"build {version} finished processing as {state}; nothing to distribute")
            print(f"build {version} is {state}; waiting ({attempt + 1}/{POLL_ATTEMPTS})")
        else:
            print(f"no build{' ' + wanted if wanted else ''} visible yet ({attempt + 1}/{POLL_ATTEMPTS})")
        time.sleep(POLL_SECONDS)

    raise SystemExit("gave up waiting for the build to finish processing")


if __name__ == "__main__":
    main()
