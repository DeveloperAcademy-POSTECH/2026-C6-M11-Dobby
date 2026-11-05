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
    return {"GITHUB_REPOSITORY": "example/project", "GITHUB_TOKEN": "test-token",
            "DISCORD_USER_MAP": json.dumps(discord_user_ids), "REVIEWER_LOGINS": "",
            "DISCORD_ISSUE_WEBHOOK_URL": "https://discord.com/api/webhooks/111/issue_test",
            "DISCORD_PR_WEBHOOK_URL": "https://discord.com/api/webhooks/222/pr_test"}


def create_graphql_pull_request():
    return {"number": 12, "title": "Feature", "url": "https://github.com/example/project/pull/12",
            "state": "OPEN", "isDraft": False, "headRefOid": "a" * 40, "baseRefName": "main",
            "author": {"login": "alice"}, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
            "reviewDecision": "APPROVED", "mergeQueueEntry": None}


def create_rest_pull_request(url):
    return {"number": 12, "title": "Feature", "html_url": url, "draft": False,
            "state": "open", "head": {"ref": "feature"}, "base": {"ref": "main"},
            "user": {"login": "alice"}, "merged": False}


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.discord_user_ids = create_discord_user_ids()
        self.environment = patch.dict(os.environ, create_test_environment(self.discord_user_ids))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.notifier = d.Notifier()
        self.graphql_pull_request = create_graphql_pull_request()
        self.rest_pull_request = create_rest_pull_request(self.graphql_pull_request["url"])

    def notify_merge_ready(self, snapshots=None, queued=False):
        with patch.object(self.notifier, "iterate_repository_items", return_value=iter([self.rest_pull_request])), \
             patch.object(self.notifier, "request_pull_request", side_effect=snapshots or [self.graphql_pull_request, self.graphql_pull_request]), \
             patch.object(self.notifier, "branch_uses_merge_queue", return_value=queued), \
             patch.object(self.notifier, "send_notification_once") as send, patch.object(d.time, "sleep"):
            self.notifier.notify_merge_ready_pull_requests()
            return send

    def test_only_clean_open_non_draft_is_ready(self):
        self.assertTrue(d.pull_request_is_ready(self.graphql_pull_request))
        for key, value in [("state", "MERGED"), ("isDraft", True), ("mergeable", "CONFLICTING"),
                           ("mergeStateStatus", "BLOCKED"), ("mergeStateStatus", "UNSTABLE"),
                           ("mergeStateStatus", "BEHIND"), ("mergeStateStatus", "UNKNOWN"),
                           ("reviewDecision", "REVIEW_REQUIRED"), ("reviewDecision", "CHANGES_REQUESTED"),
                           ("mergeQueueEntry", {"id": "queue"})]:
            with self.subTest(key=key, value=value):
                self.assertFalse(d.pull_request_is_ready(dict(self.graphql_pull_request, **{key: value})))

    def test_develop_target_is_ready(self):
        self.assertTrue(d.pull_request_is_ready(dict(self.graphql_pull_request, baseRefName="develop")))

    def test_no_review_requirement_allowed(self):
        self.assertTrue(d.pull_request_is_ready(dict(self.graphql_pull_request, reviewDecision=None)))

    def test_ready_mentions_only_author(self):
        send = self.notify_merge_ready()
        message = send.call_args.args[3]
        self.assertEqual(send.call_args.args[2], "pr")
        self.assertEqual(message["allowed_mentions"], {"parse": [], "users": ["123456789012345678"]})
        self.assertIn("<@123456789012345678>", message["content"])

    def test_new_commit_cancels_stale_notification(self):
        send = self.notify_merge_ready([self.graphql_pull_request, dict(self.graphql_pull_request, headRefOid="b" * 40)])
        send.assert_not_called()

    def test_new_draft_cancels_notification(self):
        self.notify_merge_ready([self.graphql_pull_request, dict(self.graphql_pull_request, isDraft=True)]).assert_not_called()

    def test_queue_does_not_claim_direct_merge(self):
        self.notify_merge_ready(queued=True).assert_not_called()

    def test_unknown_is_requeried(self):
        unknown = dict(self.graphql_pull_request, mergeable="UNKNOWN", mergeStateStatus="UNKNOWN")
        self.notify_merge_ready([unknown, self.graphql_pull_request, self.graphql_pull_request]).assert_called_once()

    def test_missing_user_mapping_defers_without_marker(self):
        with patch.dict(os.environ, {"DISCORD_USER_MAP": "{}"}), contextlib.redirect_stdout(io.StringIO()):
            self.notify_merge_ready().assert_not_called()

    def test_draft_opening_silent(self):
        with patch.object(self.notifier, "send_notification_once") as send, \
             patch.object(self.notifier, "request_repository_json") as request:
            self.notifier.handle_event({"action": "opened", "pull_request": dict(self.rest_pull_request, draft=True)},
                                "pull_request_target")
            send.assert_not_called()
            request.assert_not_called()

    def test_ready_for_review_uses_pr_room(self):
        with patch.object(self.notifier, "send_notification_once") as send, \
             patch.object(self.notifier, "request_repository_json", return_value=self.rest_pull_request):
            self.notifier.handle_event({"action": "ready_for_review", "pull_request": self.rest_pull_request},
                                "pull_request_target")
            self.assertEqual(send.call_args.args[1:3], ("pr-announced", "pr"))

    def test_issue_goes_to_issue_room(self):
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "issue": self.rest_pull_request}, "issues")
            self.assertEqual(send.call_args.args[0], "issue")

    def test_close_without_merge_silent(self):
        with patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": self.rest_pull_request},
                                "pull_request_target")
            send.assert_not_called()

    def test_merge_goes_to_pr_room_without_ping(self):
        item = dict(self.rest_pull_request, merged=True, merged_by={"login": "alice"})
        with patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": item}, "pull_request_target")
            self.assertEqual(send.call_args.args[1:3], ("pr-merged", "pr"))
            self.assertEqual(send.call_args.args[3]["allowed_mentions"]["users"], [])

    def test_target_branch_filter(self):
        item = dict(self.rest_pull_request, base={"ref": "other"})
        with patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.handle_event({"action": "opened", "pull_request": item}, "pull_request_target")
            send.assert_not_called()

    def test_routing_uses_distinct_webhook_secrets(self):
        for route, expected in [("issue", "/111/issue_test"), ("pr", "/222/pr_test")]:
            with patch.object(d, "request_json", return_value={"id": "message"}) as request, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.notifier.send_discord_message(route, {})
                self.assertIn(expected, request.call_args.args[0])
                self.assertIn("wait=true", request.call_args.args[0])

    def test_bot_marker_prevents_duplicate_but_user_marker_does_not(self):
        for login, kind, expected in [("github-actions[bot]", "Bot", False), ("alice", "User", True)]:
            comments = [{"user": {"login": login, "type": kind}, "body": "<!-- discord-notify:v1:test -->"}]
            with patch.object(self.notifier, "iterate_repository_items", return_value=iter(comments)), \
                 patch.object(self.notifier, "request_repository_json"), \
                 patch.object(d, "request_json", return_value={"id": "message"}) as request, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.notifier.send_notification_once(12, "test", "pr", {})
                self.assertEqual(request.called, expected)

    def test_failed_delivery_does_not_save_marker(self):
        with patch.object(self.notifier, "iterate_repository_items", return_value=iter([])), \
             patch.object(self.notifier, "request_repository_json") as request, \
             patch.object(d, "request_json", side_effect=d.SafeError("Discord HTTP 500")):
            with self.assertRaises(d.SafeError):
                self.notifier.send_notification_once(12, "test", "pr", {})
            request.assert_not_called()

    def test_user_map_validation_never_echoes_values(self):
        for raw in ['{"alice":123456789012345678}', '[]', '{"alice":"private-value"}']:
            with self.assertRaises(d.SafeError) as error:
                d.parse_discord_user_ids(raw)
            self.assertNotIn("private-value", str(error.exception))

    def test_untrusted_titles_cannot_mention_anyone(self):
        title = d.escape_discord_text("@everyone <@123456789012345678>\n[click](url)")
        self.assertNotIn("@", title)
        self.assertNotIn("\n", title)

    def test_invalid_webhook_never_echoes_url(self):
        with self.assertRaises(d.SafeError) as error:
            d.build_confirmed_webhook_url("https://example.com/secret-token")
        self.assertNotIn("secret-token", str(error.exception))

    def test_github_pagination_includes_later_results(self):
        first_page = [{"number": number} for number in range(100)]
        with patch.object(self.notifier, "request_repository_json",
                          side_effect=[first_page, [{"number": 101}]]) as request:
            results = list(self.notifier.iterate_repository_items("/pulls?state=open"))
            self.assertEqual(len(results), 101)
            self.assertEqual(request.call_args.args[0], "/pulls?state=open&per_page=100&page=2")

    def test_marker_lookup_includes_later_pages(self):
        first_page = [{"user": {"login": "alice", "type": "User"}, "body": "comment"}] * 100
        marker = {"user": {"login": "github-actions[bot]", "type": "Bot"},
                  "body": "<!-- discord-notify:v1:pr-merged -->"}
        with patch.object(self.notifier, "request_repository_json", side_effect=[first_page, [marker]]), \
             patch.object(d, "request_json") as request:
            self.assertFalse(self.notifier.send_notification_once(12, "pr-merged", "pr", {}))
            request.assert_not_called()

    def test_still_unknown_never_notifies(self):
        unknown = dict(self.graphql_pull_request, mergeable="UNKNOWN", mergeStateStatus="UNKNOWN")
        self.notify_merge_ready([unknown, unknown, unknown]).assert_not_called()

    def test_changed_base_branch_cancels_notification(self):
        self.notify_merge_ready([self.graphql_pull_request, dict(self.graphql_pull_request, baseRefName="other")]).assert_not_called()

    def test_api_failure_does_not_announce_ready(self):
        with patch.object(self.notifier, "iterate_repository_items", return_value=iter([self.rest_pull_request])), \
             patch.object(self.notifier, "request_pull_request", side_effect=d.SafeError("GitHub HTTP 403")), \
             patch.object(self.notifier, "send_notification_once") as send, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(d.SafeError):
                self.notifier.notify_merge_ready_pull_requests()
            send.assert_not_called()

    def test_no_available_mapping_does_not_disable_issue_notifications(self):
        with patch.dict(os.environ, {"DISCORD_USER_MAP": "invalid"}), \
             patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "issue": self.rest_pull_request}, "issues")
            send.assert_called_once()

    def test_issue_webhook_does_not_fall_back_to_pr_room(self):
        with patch.dict(os.environ, {"DISCORD_ISSUE_WEBHOOK_URL": ""}), \
             patch.object(d, "request_json") as request:
            with self.assertRaises(d.SafeError):
                self.notifier.send_discord_message("issue", {})
            request.assert_not_called()

    def test_title_mentions_are_not_in_allowed_mentions(self):
        message = d.build_discord_message(
            "New PR", "@everyone <@123456789012345678>", self.graphql_pull_request["url"], "description")
        self.assertEqual(message["allowed_mentions"], {"parse": [], "users": []})
        self.assertNotIn("@", message["content"])

    def review_message(self, author, action="opened", branch="main"):
        item = dict(self.rest_pull_request, user={"login": author}, base={"ref": branch})
        with patch.object(self.notifier, "send_notification_once") as send, \
             patch.object(self.notifier, "request_repository_json", return_value=item):
            self.notifier.handle_event({"action": action, "pull_request": item}, "pull_request_target")
            return send.call_args.args[3]

    def test_each_team_author_pings_only_the_other_three_reviewers(self):
        for author in d.DEFAULT_REVIEWERS:
            with self.subTest(author=author):
                message = self.review_message(author)
                expected = [self.discord_user_ids[login] for login in d.DEFAULT_REVIEWERS if login != author]
                self.assertEqual(message["allowed_mentions"]["users"], expected)
                self.assertNotIn(f'<@{self.discord_user_ids[author]}>', message["content"])
                self.assertIn(f"작성자: {author}", message["content"])
                self.assertTrue(message["content"].startswith("🚨 리뷰할 PR이 올라왔어요.\n"))
                self.assertTrue(message["content"].endswith("리뷰어: " + " ".join(f"<@{uid}>" for uid in expected)))

    def test_ready_for_review_uses_same_reviewer_mentions(self):
        self.assertEqual(self.review_message("tobae-time"), self.review_message("tobae-time", "ready_for_review"))

    def test_author_outside_reviewer_group_pings_all_four(self):
        message = self.review_message("alice")
        self.assertEqual(message["allowed_mentions"]["users"], [self.discord_user_ids[login] for login in d.DEFAULT_REVIEWERS])
        self.assertNotIn(self.discord_user_ids["alice"], message["content"])

    def test_case_insensitive_author_is_excluded(self):
        message = self.review_message("Tobae-Time")
        self.assertNotIn(self.discord_user_ids["tobae-time"], message["allowed_mentions"]["users"])
        self.assertEqual(len(message["allowed_mentions"]["users"]), 3)

    def test_reviewer_override_is_deduplicated(self):
        with patch.dict(os.environ, {"REVIEWER_LOGINS": " hana5111, HANa5111, tobae-time "}):
            message = self.review_message("tobae-time")
            self.assertEqual(message["allowed_mentions"]["users"], [self.discord_user_ids["hana5111"]])

    def test_missing_reviewer_mapping_defers_without_partial_ping(self):
        users = dict(self.discord_user_ids)
        del users["decl5th"]
        with patch.dict(os.environ, {"DISCORD_USER_MAP": json.dumps(users)}), \
             patch.object(self.notifier, "send_notification_once") as send, \
             patch.object(self.notifier, "request_repository_json", return_value=self.rest_pull_request):
            with self.assertRaises(d.SafeError):
                self.notifier.handle_event({"action": "opened", "pull_request": self.rest_pull_request},
                                    "pull_request_target")
            send.assert_not_called()

    def test_issue_author_is_github_login_and_title_is_linked(self):
        item = dict(self.rest_pull_request, html_url="https://github.com/example/project/issues/12")
        with patch.object(self.notifier, "send_discord_message") as send:
            self.notifier.handle_event({"action": "opened", "issue": item}, "issues")
            message = send.call_args.args[1]
            self.assertEqual(message["content"],
                             "📝 새 이슈가 등록됐어요.\n**[#12 Feature](https://github.com/example/project/issues/12)**\n작성자: alice")
            self.assertEqual(message["allowed_mentions"]["users"], [])

    def test_pr_title_is_linked_to_pr(self):
        self.assertIn(f'**[#12 Feature]({self.graphql_pull_request["url"]})**', self.review_message("tobae-time")["content"])

    def test_ready_author_uses_discord_mention_and_no_internal_state(self):
        message = self.notify_merge_ready().call_args.args[3]
        self.assertEqual(message["content"],
                         "✅ <@123456789012345678> GitHub에서 머지 준비 상태가 확인됐어요. PR을 확인하고 직접 머지해 주세요.\n"
                         "**[#12 Feature](https://github.com/example/project/pull/12)**\n작성자: <@123456789012345678>\n대상: main")
        self.assertEqual(message["allowed_mentions"]["users"], [self.discord_user_ids["alice"]])

    def test_merge_ready_supports_develop(self):
        self.rest_pull_request = dict(self.rest_pull_request, base={"ref": "develop"})
        self.graphql_pull_request = dict(self.graphql_pull_request, baseRefName="develop")
        self.notify_merge_ready().assert_called_once()

    def test_merge_ready_to_other_branches_is_silent(self):
        self.rest_pull_request = dict(self.rest_pull_request, base={"ref": "feature"})
        with patch.object(self.notifier, "iterate_repository_items", return_value=iter([self.rest_pull_request])), \
             patch.object(self.notifier, "request_pull_request") as request, \
             patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.notify_merge_ready_pull_requests()
            request.assert_not_called()
            send.assert_not_called()
        self.assertFalse(d.pull_request_is_ready(dict(self.graphql_pull_request, baseRefName="feature")))

    def test_merge_completed_to_other_branches_is_silent(self):
        for branch in ("feature", "Main"):
            with self.subTest(branch=branch), patch.object(self.notifier, "send_notification_once") as send:
                item = dict(self.rest_pull_request, base={"ref": branch}, merged=True)
                self.notifier.handle_event({"action": "closed", "pull_request": item}, "pull_request_target")
                send.assert_not_called()

    def test_review_request_to_develop_notifies(self):
        message = self.review_message("tobae-time", branch="develop")
        self.assertIn("feature → develop", message["content"])
        self.assertEqual(len(message["allowed_mentions"]["users"]), 3)

    def test_merge_completed_to_develop_notifies(self):
        item = dict(self.rest_pull_request, base={"ref": "develop"}, merged=True)
        with patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": item}, "pull_request_target")
            self.assertIn("대상: develop", send.call_args.args[3]["content"])

    def test_merge_completed_message_omits_merger_and_mentions(self):
        item = dict(self.rest_pull_request, merged=True, merged_by={"login": "bob"})
        with patch.object(self.notifier, "send_notification_once") as send:
            self.notifier.handle_event({"action": "closed", "pull_request": item}, "pull_request_target")
            message = send.call_args.args[3]
            self.assertEqual(message["content"],
                             "🎉 PR이 머지됐어요.\n**[#12 Feature](https://github.com/example/project/pull/12)**\n작성자: alice\n대상: main")
            self.assertEqual(message["allowed_mentions"]["users"], [])


if __name__ == "__main__":
    unittest.main()
