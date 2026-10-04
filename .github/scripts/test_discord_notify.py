import contextlib
import io
import json
import os
import unittest
from unittest.mock import patch

import discord_notify as d


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "GITHUB_REPOSITORY": "example/project", "GITHUB_TOKEN": "test-token",
            "TARGET_BRANCHES": "main", "DISCORD_USER_MAP": '{"Alice":"123456789012345678"}',
            "DISCORD_ISSUE_WEBHOOK_URL": "https://discord.com/api/webhooks/111/issue_test",
            "DISCORD_PR_WEBHOOK_URL": "https://discord.com/api/webhooks/222/pr_test"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.n = d.Notifier()
        self.pr = {"number": 12, "title": "Feature", "url": "https://github.com/example/project/pull/12",
                   "state": "OPEN", "isDraft": False, "headRefOid": "a" * 40, "baseRefName": "main",
                   "author": {"login": "alice"}, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
                   "reviewDecision": "APPROVED", "mergeQueueEntry": None}
        self.item = {"number": 12, "title": "Feature", "html_url": self.pr["url"], "draft": False,
                     "state": "open", "head": {"ref": "feature"}, "base": {"ref": "main"},
                     "user": {"login": "alice"}, "merged": False}

    def run_ready(self, snapshots=None, queued=False):
        with patch.object(self.n, "pages", return_value=iter([self.item])), \
             patch.object(self.n, "snapshot", side_effect=snapshots or [self.pr, self.pr]), \
             patch.object(self.n, "queue_enabled", return_value=queued), \
             patch.object(self.n, "send_once") as send, patch.object(d.time, "sleep"):
            self.n.ready()
            return send

    def test_only_clean_open_non_draft_is_ready(self):
        self.assertTrue(d.is_ready(self.pr))
        for key, value in [("state", "MERGED"), ("isDraft", True), ("mergeable", "CONFLICTING"),
                           ("mergeStateStatus", "BLOCKED"), ("mergeStateStatus", "UNSTABLE"),
                           ("mergeStateStatus", "BEHIND"), ("mergeStateStatus", "UNKNOWN"),
                           ("reviewDecision", "REVIEW_REQUIRED"), ("reviewDecision", "CHANGES_REQUESTED"),
                           ("mergeQueueEntry", {"id": "queue"})]:
            with self.subTest(key=key, value=value):
                self.assertFalse(d.is_ready(dict(self.pr, **{key: value})))

    def test_no_review_requirement_allowed(self):
        self.assertTrue(d.is_ready(dict(self.pr, reviewDecision=None)))

    def test_ready_mentions_only_author(self):
        send = self.run_ready()
        message = send.call_args.args[3]
        self.assertEqual(send.call_args.args[2], "pr")
        self.assertEqual(message["allowed_mentions"], {"parse": [], "users": ["123456789012345678"]})
        self.assertIn("<@123456789012345678>", message["content"])

    def test_new_commit_cancels_stale_notification(self):
        send = self.run_ready([self.pr, dict(self.pr, headRefOid="b" * 40)])
        send.assert_not_called()

    def test_new_draft_cancels_notification(self):
        self.run_ready([self.pr, dict(self.pr, isDraft=True)]).assert_not_called()

    def test_queue_does_not_claim_direct_merge(self):
        self.run_ready(queued=True).assert_not_called()

    def test_unknown_is_requeried(self):
        unknown = dict(self.pr, mergeable="UNKNOWN", mergeStateStatus="UNKNOWN")
        self.run_ready([unknown, self.pr, self.pr]).assert_called_once()

    def test_missing_user_mapping_defers_without_marker(self):
        with patch.dict(os.environ, {"DISCORD_USER_MAP": "{}"}), contextlib.redirect_stdout(io.StringIO()):
            self.run_ready().assert_not_called()

    def test_draft_opening_silent(self):
        with patch.object(self.n, "send_once") as send, patch.object(self.n, "github") as github:
            self.n.event({"action": "opened", "pull_request": dict(self.item, draft=True)}, "pull_request_target")
            send.assert_not_called()
            github.assert_not_called()

    def test_ready_for_review_uses_pr_room(self):
        with patch.object(self.n, "send_once") as send, patch.object(self.n, "github", return_value=self.item):
            self.n.event({"action": "ready_for_review", "pull_request": self.item}, "pull_request_target")
            self.assertEqual(send.call_args.args[1:3], ("pr-announced", "pr"))

    def test_issue_goes_to_issue_room(self):
        with patch.object(self.n, "send_once") as send:
            self.n.event({"action": "opened", "issue": self.item}, "issues")
            self.assertEqual(send.call_args.args[2], "issue")

    def test_close_without_merge_silent(self):
        with patch.object(self.n, "send_once") as send:
            self.n.event({"action": "closed", "pull_request": self.item}, "pull_request_target")
            send.assert_not_called()

    def test_merge_goes_to_pr_room_without_ping(self):
        item = dict(self.item, merged=True, merged_by={"login": "alice"})
        with patch.object(self.n, "send_once") as send:
            self.n.event({"action": "closed", "pull_request": item}, "pull_request_target")
            self.assertEqual(send.call_args.args[1:3], ("pr-merged", "pr"))
            self.assertEqual(send.call_args.args[3]["allowed_mentions"]["users"], [])

    def test_target_branch_filter(self):
        item = dict(self.item, base={"ref": "other"})
        with patch.object(self.n, "send_once") as send:
            self.n.event({"action": "opened", "pull_request": item}, "pull_request_target")
            send.assert_not_called()

    def test_routing_uses_distinct_webhook_secrets(self):
        for route, expected in [("issue", "/111/issue_test"), ("pr", "/222/pr_test")]:
            with patch.object(self.n, "pages", return_value=iter([])), \
                 patch.object(self.n, "github") as github, \
                 patch.object(d, "request_json", return_value={"id": "message"}) as request, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.n.send_once(12, "test", route, {})
                self.assertIn(expected, request.call_args.args[0])
                self.assertIn("wait=true", request.call_args.args[0])
                self.assertNotIn("123456789012345678", json.dumps(github.call_args.args))
                self.assertNotIn("webhooks", json.dumps(github.call_args.args))

    def test_bot_marker_prevents_duplicate_but_user_marker_does_not(self):
        for login, kind, expected in [("github-actions[bot]", "Bot", False), ("alice", "User", True)]:
            comments = [{"user": {"login": login, "type": kind}, "body": "<!-- discord-notify:v1:test -->"}]
            with patch.object(self.n, "pages", return_value=iter(comments)), patch.object(self.n, "github"), \
                 patch.object(d, "request_json", return_value={"id": "message"}) as request, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.n.send_once(12, "test", "pr", {})
                self.assertEqual(request.called, expected)

    def test_failed_delivery_does_not_save_marker(self):
        with patch.object(self.n, "pages", return_value=iter([])), patch.object(self.n, "github") as github, \
             patch.object(d, "request_json", side_effect=d.SafeError("Discord HTTP 500")):
            with self.assertRaises(d.SafeError):
                self.n.send_once(12, "test", "pr", {})
            github.assert_not_called()

    def test_user_map_validation_never_echoes_values(self):
        for raw in ['{"alice":123456789012345678}', '[]', '{"alice":"private-value"}']:
            with self.assertRaises(d.SafeError) as error:
                d.member_map(raw)
            self.assertNotIn("private-value", str(error.exception))

    def test_untrusted_titles_cannot_mention_anyone(self):
        title = d.clean("@everyone <@123456789012345678>\n[click](url)")
        self.assertNotIn("@", title)
        self.assertNotIn("\n", title)

    def test_invalid_webhook_never_echoes_url(self):
        with self.assertRaises(d.SafeError) as error:
            d.webhook_url("https://example.com/secret-token")
        self.assertNotIn("secret-token", str(error.exception))

    def test_github_pagination_includes_later_results(self):
        first_page = [{"number": number} for number in range(100)]
        with patch.object(self.n, "github", side_effect=[first_page, [{"number": 101}]]) as github:
            results = list(self.n.pages("/pulls?state=open"))
            self.assertEqual(len(results), 101)
            self.assertEqual(github.call_args.args[0], "/pulls?state=open&per_page=100&page=2")

    def test_marker_lookup_includes_later_pages(self):
        first_page = [{"user": {"login": "alice", "type": "User"}, "body": "comment"}] * 100
        marker = {"user": {"login": "github-actions[bot]", "type": "Bot"},
                  "body": "<!-- discord-notify:v1:pr-merged -->"}
        with patch.object(self.n, "github", side_effect=[first_page, [marker]]), \
             patch.object(d, "request_json") as request:
            self.assertFalse(self.n.send_once(12, "pr-merged", "pr", {}))
            request.assert_not_called()

    def test_still_unknown_never_notifies(self):
        unknown = dict(self.pr, mergeable="UNKNOWN", mergeStateStatus="UNKNOWN")
        self.run_ready([unknown, unknown, unknown]).assert_not_called()

    def test_changed_base_branch_cancels_notification(self):
        self.run_ready([self.pr, dict(self.pr, baseRefName="other")]).assert_not_called()

    def test_api_failure_does_not_announce_ready(self):
        with patch.object(self.n, "pages", return_value=iter([self.item])), \
             patch.object(self.n, "snapshot", side_effect=d.SafeError("GitHub HTTP 403")), \
             patch.object(self.n, "send_once") as send, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(d.SafeError):
                self.n.ready()
            send.assert_not_called()

    def test_no_available_mapping_does_not_disable_issue_notifications(self):
        with patch.dict(os.environ, {"DISCORD_USER_MAP": "invalid"}), patch.object(self.n, "send_once") as send:
            self.n.event({"action": "opened", "issue": self.item}, "issues")
            send.assert_called_once()

    def test_issue_webhook_does_not_fall_back_to_pr_room(self):
        with patch.dict(os.environ, {"DISCORD_ISSUE_WEBHOOK_URL": ""}), \
             patch.object(self.n, "pages", return_value=iter([])), \
             patch.object(d, "request_json") as request:
            with self.assertRaises(d.SafeError):
                self.n.send_once(12, "issue-opened", "issue", {})
            request.assert_not_called()

    def test_title_mentions_are_not_in_allowed_mentions(self):
        message = d.payload("New PR", "@everyone <@123456789012345678>", self.pr["url"], "description", 0)
        self.assertEqual(message["allowed_mentions"], {"parse": [], "users": []})
        self.assertNotIn("@", message["embeds"][0]["title"])


if __name__ == "__main__":
    unittest.main()
