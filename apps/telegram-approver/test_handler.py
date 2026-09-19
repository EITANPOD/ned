import base64
import json
import unittest

import handler

CFG = {"bot_token": "t", "webhook_secret": "s3cret", "dispatch_token": "d", "approver_id": "42"}
SHA = "a" * 40


def event(data="a:12:" + SHA, user=42, secret="s3cret", b64=False):
    body = json.dumps({"callback_query": {"id": "cb1", "from": {"id": user}, "data": data}})
    if b64:
        body = base64.b64encode(body.encode()).decode()
    return {"headers": {"x-telegram-bot-api-secret-token": secret}, "body": body, "isBase64Encoded": b64}


class Calls:
    def __init__(self, ok=True):
        self.ok, self.dispatched, self.answers = ok, [], []

    def dispatch(self, action, pr, sha):
        self.dispatched.append((action, pr, sha))
        return self.ok

    def answer(self, cid, text):
        self.answers.append(text)


def run(ev, ok=True):
    c = Calls(ok)
    return handler.handle(ev, CFG, c.dispatch, c.answer), c


class HandleTest(unittest.TestCase):
    def test_wrong_secret_is_401_and_silent(self):
        status, c = run(event(secret="nope"))
        self.assertEqual(status, 401)
        self.assertEqual((c.dispatched, c.answers), ([], []))

    def test_missing_secret_is_401(self):
        status, c = run({"headers": {}, "body": "{}"})
        self.assertEqual(status, 401)

    def test_other_user_is_refused(self):
        status, c = run(event(user=7))
        self.assertEqual(status, 200)
        self.assertEqual(c.dispatched, [])
        self.assertIn("not authorised", c.answers[0])

    def test_bad_callback_data_is_refused(self):
        for bad in ["a:12:" + "a" * 39, "x:12:" + SHA, "a:0:" + SHA, "a:12:" + SHA + ";rm", "a:12:" + SHA.upper()]:
            status, c = run(event(data=bad))
            self.assertEqual(status, 200, bad)
            self.assertEqual(c.dispatched, [], bad)

    def test_approve_dispatches(self):
        status, c = run(event())
        self.assertEqual(status, 200)
        self.assertEqual(c.dispatched, [("approve", "12", SHA)])
        self.assertIn("approve", c.answers[0])

    def test_deny_and_fix_map(self):
        self.assertEqual(run(event(data="d:3:" + SHA))[1].dispatched, [("deny", "3", SHA)])
        self.assertEqual(run(event(data="f:3:" + SHA))[1].dispatched, [("fix", "3", SHA)])

    def test_base64_body(self):
        self.assertEqual(run(event(b64=True))[1].dispatched, [("approve", "12", SHA)])

    def test_dispatch_failure_is_reported(self):
        status, c = run(event(), ok=False)
        self.assertEqual(status, 200)
        self.assertIn("failed", c.answers[0])

    def test_non_callback_update_is_ignored(self):
        ev = event()
        ev["body"] = json.dumps({"message": {"text": "hi", "from": {"id": 42}}})
        status, c = run(ev)
        self.assertEqual(status, 200)
        self.assertEqual((c.dispatched, c.answers), ([], []))

    def test_invalid_json_body_is_silently_dropped(self):
        status, c = run({"headers": {"x-telegram-bot-api-secret-token": "s3cret"}, "body": "not json"})
        self.assertEqual(status, 200)
        self.assertEqual((c.dispatched, c.answers), ([], []))

    def test_callback_query_missing_id_is_silently_dropped(self):
        ev = event()
        ev["body"] = json.dumps({"callback_query": {"from": {"id": 42}, "data": "a:12:" + SHA}})
        status, c = run(ev)
        self.assertEqual(status, 200)
        self.assertEqual((c.dispatched, c.answers), ([], []))


if __name__ == "__main__":
    unittest.main()
