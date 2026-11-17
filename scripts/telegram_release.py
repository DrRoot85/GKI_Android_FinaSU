#!/usr/bin/env python3
"""Announce a GitHub release on Telegram and upload assets that fit the Bot API limit."""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

TELEGRAM_API = "https://api.telegram.org"
MAX_UPLOAD_BYTES = 49_000_000


def api_request(url, *, data=None, headers=None, method=None):
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method=method,
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def telegram_request(token, method, *, data, content_type):
    response = api_request(
        f"{TELEGRAM_API}/bot{token}/{method}",
        data=data,
        headers={"Content-Type": content_type},
        method="POST",
    )
    result = json.loads(response.decode("utf-8"))
    if not result.get("ok"):
        raise RuntimeError(f"Telegram rejected {method}")
    return result


def send_message(token, chat_id, text):
    payload = json.dumps(
        {"chat_id": chat_id, "text": text, "disable_web_page_preview": False}
    ).encode("utf-8")
    telegram_request(
        token,
        "sendMessage",
        data=payload,
        content_type="application/json",
    )


def send_document(token, chat_id, name, content):
    boundary = f"----GKIRelease{uuid.uuid4().hex}"
    safe_name = os.path.basename(name).replace('"', "'").replace("\r", "_").replace("\n", "_")
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{chat_id}\r\n".encode(),
        (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
            f"filename=\"{safe_name}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        ).encode(),
        content,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    telegram_request(
        token,
        "sendDocument",
        data=b"".join(parts),
        content_type=f"multipart/form-data; boundary={boundary}",
    )


def get_release_assets(repository, tag, token):
    encoded_tag = urllib.parse.quote(tag, safe="")
    url = f"https://api.github.com/repos/{repository}/releases/tags/{encoded_tag}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "GKI-Android-FinaSU-release-notifier",
    }
    result = json.loads(api_request(url, headers=headers).decode("utf-8"))
    return result.get("assets", [])


def download_asset(url, token):
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "User-Agent": "GKI-Android-FinaSU-release-notifier"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        content = response.read(MAX_UPLOAD_BYTES + 1)
    if len(content) > MAX_UPLOAD_BYTES:
        raise RuntimeError("asset exceeded the Telegram upload limit while downloading")
    return content


def main():
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if not token:
        print("::warning::Telegram delivery skipped; set the TELEGRAM_BOT_TOKEN repository secret.")
        return 0

    chat_id = os.environ["TELEGRAM_CHAT_ID"]
    title = os.environ["RELEASE_TITLE"]
    tag = os.environ["RELEASE_TAG"]
    release_url = os.environ["RELEASE_URL"]
    repository = os.environ["GITHUB_REPOSITORY"]
    github_token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    if not github_token:
        raise RuntimeError("GitHub token is unavailable; cannot list release assets")

    assets = get_release_assets(repository, tag, github_token)
    oversized = [asset for asset in assets if int(asset.get("size", 0)) > MAX_UPLOAD_BYTES]
    message = f"{title}\nTag: {tag}\n{release_url}"
    if assets:
        message += f"\n\nUploading {len(assets) - len(oversized)} of {len(assets)} release assets here."
    send_message(token, chat_id, message)
    print("Release announcement sent to Telegram.")

    failures = []
    for asset in assets:
        name = asset.get("name", "release asset")
        size = int(asset.get("size", 0))
        if size > MAX_UPLOAD_BYTES:
            print(f"Telegram upload skipped for oversized asset: {name} ({size} bytes)")
            continue
        try:
            content = download_asset(asset["browser_download_url"], github_token)
            send_document(token, chat_id, name, content)
            print(f"Uploaded release asset to Telegram: {name}")
            time.sleep(3)
        except (KeyError, OSError, RuntimeError, urllib.error.URLError) as error:
            print(f"::warning::Could not upload release asset {name}: {type(error).__name__}")
            failures.append(name)

    linked_assets = oversized + [asset for asset in assets if asset.get("name") in failures]
    if linked_assets:
        lines = ["Some assets are available from the GitHub release instead:"]
        for asset in linked_assets:
            lines.append(f"{asset.get('name', 'Release asset')}: {asset.get('browser_download_url', release_url)}")
        send_message(token, chat_id, "\n".join(lines))

    if failures:
        print(f"::warning::Telegram asset upload failed for {len(failures)} asset(s).")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.HTTPError as error:
        print(f"::error::Telegram or GitHub API returned HTTP {error.code}.")
        raise SystemExit(1)
    except Exception as error:
        print(f"::error::Telegram release delivery failed: {type(error).__name__}.")
        raise SystemExit(1)
