import contextlib
import io
import json
import os
import unittest
from unittest.mock import patch

import discord_notify as d


def create_discord_user_ids():
    return {"alice": "123456789012345678",
            "moogoochung": "111111111111111111",
            "tobae-time": "222222222222222222",
            "hana5111": "333333333333333333",
            "decl5th": "444444444444444444"}


def create_test_environment(discord_user_ids):
    return {"DISCORD_USER_MAP": json.dumps(discord_user_ids), "REVIEWER_LOGINS": "",
            "DISCORD_ISSUE_WEBHOOK_URL": "https://discord.com/api/webhooks/111/issue_test",
            "DISCORD_PR_WEBHOOK_URL": "https://discord.com/api/webhooks/222/pr_test"}


def create_pull_request():
    return {"number": 12, "title": "Feature", "html_url": "https://github.com/example/project/pull/12",
            "draft": False, "state": "open", "head": {"ref": "feature"},
            "base": {"ref": "main"}, "user": {"login": "alice"}, "merged": False}


def create_review_event(pull_request, state="approved"):
    return {"action": "submitted", "pull_request": pull_request,
            "review": {"state": state, "user": {"login": "reviewer"}}}


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.discord_user_ids = create_discord_user_ids()
        environment = create_test_environment(self.discord_user_ids)
        self.environment = patch.dict(os.environ, environment)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.notifier = d.Notifier()
        self.pull_request = create_pull_request()

    def capture_review_request(self, author="alice", branch="main", action="opened"):
        pull_request = dict(self.pull_request, user={"login": author}, base={"ref": branch})
        event = {"action": action, "pull_request": pull_request}
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event(event, "pull_request_target")
            return send.call_args.args[1]

    def test_issue_creation_uses_issue_webhook(self):
        issue = dict(self.pull_request, html_url="https://github.com/example/project/issues/12")
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "issue": issue}, "issues")
            self.assertEqual(send.call_args.args[0], "issue")
            self.assertIn("작성자: alice", send.call_args.args[1]["content"])

    def test_review_request_mentions_other_team_members(self):
        message = self.capture_review_request()
        expected = [self.discord_user_ids[login] for login in d.DEFAULT_REVIEWERS]
        self.assertEqual(message["allowed_mentions"]["users"], expected)

    def test_team_author_is_not_mentioned_as_reviewer(self):
        message = self.capture_review_request(author="tobae-time")
        author_id = self.discord_user_ids["tobae-time"]
        self.assertNotIn(author_id, message["allowed_mentions"]["users"])
        self.assertEqual(len(message["allowed_mentions"]["users"]), 3)

    def test_ready_for_review_sends_review_request(self):
        opened = self.capture_review_request(author="tobae-time")
        ready = self.capture_review_request(author="tobae-time", action="ready_for_review")
        self.assertEqual(opened, ready)

    def test_draft_pull_request_is_silent(self):
        pull_request = dict(self.pull_request, draft=True)
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "pull_request": pull_request},
                                       "pull_request_target")
            send.assert_not_called()

    def test_unsupported_target_branch_is_silent(self):
        pull_request = dict(self.pull_request, base={"ref": "feature"})
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "pull_request": pull_request},
                                       "pull_request_target")
            send.assert_not_called()

    def test_approval_mentions_pull_request_author(self):
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event(create_review_event(self.pull_request), "pull_request_review")
            message = send.call_args.args[1]
            self.assertEqual(send.call_args.args[0], "pr")
            self.assertEqual(message["allowed_mentions"]["users"], [self.discord_user_ids["alice"]])
            self.assertIn("승인자: reviewer", message["content"])

    def test_non_approval_review_is_silent(self):
        event = create_review_event(self.pull_request, "commented")
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event(event, "pull_request_review")
            send.assert_not_called()

    def test_approval_to_unsupported_branch_is_silent(self):
        pull_request = dict(self.pull_request, base={"ref": "feature"})
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event(create_review_event(pull_request), "pull_request_review")
            send.assert_not_called()

    def test_missing_author_mapping_defers_approval(self):
        with patch.dict(os.environ, {"DISCORD_USER_MAP": "{}"}), \
             patch.object(self.notifier, "send_discord_message") as send, \
             contextlib.redirect_stdout(io.StringIO()):
            self.notifier.handle_event(create_review_event(self.pull_request), "pull_request_review")
            send.assert_not_called()

    def test_merge_completion_uses_pr_webhook_without_mentions(self):
        pull_request = dict(self.pull_request, merged=True)
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": pull_request},
                                       "pull_request_target")
            self.assertEqual(send.call_args.args[0], "pr")
            self.assertEqual(send.call_args.args[1]["allowed_mentions"]["users"], [])

    def test_close_without_merge_is_silent(self):
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": self.pull_request},
                                       "pull_request_target")
            send.assert_not_called()

    def test_routes_use_distinct_webhooks(self):
        for route, expected in (("issue", "/111/issue_test"), ("pr", "/222/pr_test")):
            with patch.object(d, "request_json", return_value={"id": "message"}) as request:
                self.notifier.send_discord_message(route, {})
                self.assertIn(expected, request.call_args.args[0])
                self.assertIn("wait=true", request.call_args.args[0])

    def test_failed_delivery_raises_safe_error(self):
        with patch.object(d, "request_json", side_effect=d.SafeError("Discord HTTP 500")):
            with self.assertRaises(d.SafeError):
                self.notifier.send_discord_message("pr", {})

    def test_user_map_validation_hides_values(self):
        for raw in ('{"alice":123456789012345678}', '[]', '{"alice":"private-value"}'):
            with self.assertRaises(d.SafeError) as error:
                d.parse_discord_user_ids(raw)
            self.assertNotIn("private-value", str(error.exception))

    def test_untrusted_title_cannot_create_mentions(self):
        title = d.escape_discord_text("@everyone <@123456789012345678>\n[click](url)")
        self.assertNotIn("@", title)
        self.assertNotIn("\n", title)

    def test_invalid_webhook_hides_url(self):
        with self.assertRaises(d.SafeError) as error:
            d.build_confirmed_webhook_url("https://example.com/secret-token")
        self.assertNotIn("secret-token", str(error.exception))

    def test_title_mentions_are_not_allowed(self):
        message = d.build_discord_message(
            "New PR", "@everyone <@123456789012345678>", self.pull_request["html_url"], "description")
        self.assertEqual(message["allowed_mentions"], {"parse": [], "users": []})
        self.assertNotIn("@", message["content"])

    def test_reviewer_override_is_deduplicated(self):
        with patch.dict(os.environ, {"REVIEWER_LOGINS": " hana5111, HANa5111, tobae-time "}):
            message = self.capture_review_request(author="tobae-time")
            self.assertEqual(message["allowed_mentions"]["users"], [self.discord_user_ids["hana5111"]])

    def test_missing_reviewer_mapping_defers_review_request(self):
        user_ids = dict(self.discord_user_ids)
        del user_ids["decl5th"]
        with patch.dict(os.environ, {"DISCORD_USER_MAP": json.dumps(user_ids)}), \
             patch.object(self.notifier, "send_discord_message") as send:
            with self.assertRaises(d.SafeError):
                self.notifier.handle_event({"action": "opened", "pull_request": self.pull_request},
                                           "pull_request_target")
            send.assert_not_called()


if __name__ == "__main__":
    unittest.main()
