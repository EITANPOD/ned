"""Telegram button tap -> workflow_dispatch of telegram-action.yml. Stdlib + boto3 (Lambda runtime) only."""
import base64
import hmac
import json
import os
import re
import urllib.request

CALLBACK = re.compile(r"^([adf]):([1-9][0-9]{0,6}):([0-9a-f]{40})$")
ACTIONS = {"a": "approve", "d": "deny", "f": "fix"}
_cfg = None


def handle(event, cfg, dispatch, answer):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    got = headers.get("x-telegram-bot-api-secret-token", "")
    if not hmac.compare_digest(got.encode(), cfg["webhook_secret"].encode()):
        return 401
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        query = json.loads(body).get("callback_query")
        if not query:
            return 200
        cid = query["id"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return 200
    if str(query.get("from", {}).get("id")) != cfg["approver_id"]:
        answer(cid, "not authorised")
        return 200
    m = CALLBACK.match(query.get("data") or "")
    if not m:
        answer(cid, "invalid button")
        return 200
    action, pr, sha = ACTIONS[m[1]], m[2], m[3]
    if dispatch(action, pr, sha):
        answer(cid, f"⏳ {action} requested for PR #{pr}")
    else:
        answer(cid, "failed, try again")
    return 200


def _post(url, payload, headers):
    req = urllib.request.Request(url, json.dumps(payload).encode(), {"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def _config():
    global _cfg
    if _cfg is None:
        import boto3

        names = {k: os.environ[f"{k.upper()}_PARAM"] for k in ("bot_token", "webhook_secret", "dispatch_token", "approver_id")}
        resp = boto3.client("ssm").get_parameters(Names=list(names.values()), WithDecryption=True)
        values = {p["Name"]: p["Value"] for p in resp["Parameters"]}
        _cfg = {k: values[v] for k, v in names.items()}
    return _cfg


def lambda_handler(event, context):
    cfg = _config()

    def dispatch(action, pr, sha):
        url = f"https://api.github.com/repos/{os.environ['REPO']}/actions/workflows/telegram-action.yml/dispatches"
        try:
            return _post(url, {"ref": "main", "inputs": {"action": action, "pr": pr, "sha": sha}}, {
                "Authorization": f"Bearer {cfg['dispatch_token']}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "ned-telegram-approver",
            }) == 204
        except OSError as err:  # urllib.error.URLError/HTTPError subclass OSError
            print(f"dispatch failed: {type(err).__name__}")
            return False

    def answer(cid, text):
        try:
            _post(f"https://api.telegram.org/bot{cfg['bot_token']}/answerCallbackQuery", {"callback_query_id": cid, "text": text}, {})
        except OSError as err:
            print(f"answerCallbackQuery failed: {type(err).__name__}")  # never log the URL: it contains the bot token

    return {"statusCode": handle(event, cfg, dispatch, answer), "body": ""}
