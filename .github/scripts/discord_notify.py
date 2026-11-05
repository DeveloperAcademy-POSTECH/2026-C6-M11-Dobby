import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


DEFAULT_REVIEWERS = ("moogoochung", "tobae-time", "hana5111", "decl5th")
MERGE_TARGETS = frozenset(("develop", "main"))
NETWORK_ERRORS = (URLError, TimeoutError, OSError, ValueError)
REQUEST_ATTEMPTS = 3
SUPPRESS_LINK_EMBEDS = 4
PULL_REQUEST_QUERY = """query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) { pullRequest(number:$number) {
    number title url state isDraft headRefOid baseRefName
    author { login } mergeable mergeStateStatus reviewDecision mergeQueueEntry { id }
  } }
}"""
MERGE_QUEUE_QUERY = """query($owner:String!, $name:String!, $branch:String!) {
  repository(owner:$owner, name:$name) { mergeQueue(branch:$branch) { id } }
}"""


class SafeError(Exception):
    pass


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_json_request(url, headers, method, body):
    encoded_body = None if body is None else json.dumps(body).encode()
    return Request(url, data=encoded_body, headers=headers, method=method)


def read_json_response(request):
    with build_opener(RejectRedirects()).open(request, timeout=25) as response:
        response_body = response.read()
        return json.loads(response_body) if response_body else None


def parse_retry_delay(raw_delay):
    try:
        return float(raw_delay)
    except ValueError:
        return 2


def retry_after_rate_limit(error, attempt):
    if error.code != 429 or attempt == REQUEST_ATTEMPTS - 1:
        return False
    delay = parse_retry_delay(error.headers.get("Retry-After", "2"))
    if 0 <= delay <= 30:
        time.sleep(delay + 1)
        return True
    return False


def request_json(url, headers, method="GET", body=None, service="GitHub"):
    for attempt in range(REQUEST_ATTEMPTS):
        try:
            request = build_json_request(url, headers, method, body)
            return read_json_response(request)
        except HTTPError as error:
            if retry_after_rate_limit(error, attempt):
                continue
            raise SafeError(f"{service} HTTP {error.code}; 응답/URL은 비밀 보호를 위해 생략합니다.") from None
        except NETWORK_ERRORS:
            raise SafeError(f"{service} 연결 또는 응답 오류. 비밀 값은 로그에 출력하지 않습니다.") from None


def escape_discord_text(value, limit=250):
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value))[:limit]
    text = text.replace("@", "＠").replace("<", "＜").replace(">", "＞")
    return re.sub(r"([\\`*_~|\[\]])", r"\\\1", text)


def parse_discord_user_ids(raw_user_ids):
    try:
        user_ids = json.loads(raw_user_ids or "{}")
        if not isinstance(user_ids, dict):
            raise ValueError()
        if any(not valid_discord_user_id(login, user_id) for login, user_id in user_ids.items()):
            raise ValueError()
        return {login.lower(): user_id for login, user_id in user_ids.items()}
    except (ValueError, TypeError):
        raise SafeError("DISCORD_USER_MAP 형식 오류. GitHub 아이디:문자열 사용자 ID 형태의 JSON이 필요합니다.") from None


def valid_discord_user_id(login, user_id):
    return (isinstance(login, str) and isinstance(user_id, str)
            and re.fullmatch(r"[0-9]{17,20}", user_id))


def build_confirmed_webhook_url(raw_url):
    webhook = urlsplit(raw_url)
    if not valid_webhook(webhook):
        raise SafeError("Discord Webhook Secret 형식이 잘못되었거나 비어 있습니다.")
    query = dict(parse_qsl(webhook.query))
    query["wait"] = "true"
    return urlunsplit((webhook.scheme, webhook.netloc, webhook.path, urlencode(query), ""))


def valid_webhook(webhook):
    path_pattern = r"/api(?:/v\d+)?/webhooks/\d+/[A-Za-z0-9._-]+"
    return (webhook.scheme == "https" and webhook.netloc == "discord.com"
            and re.fullmatch(path_pattern, webhook.path))


def reviewers_for(author, users):
    configured = os.environ.get("REVIEWER_LOGINS", "").strip()
    logins = configured.split(",") if configured else DEFAULT_REVIEWERS
    logins = dict.fromkeys(login.strip().lower() for login in logins if login.strip())
    selected = [login for login in logins if login != author.lower()]
    if any(login not in users for login in selected):
        raise SafeError("리뷰어의 DISCORD_USER_MAP 항목이 누락되어 리뷰 요청 알림을 보류합니다.")
    return list(dict.fromkeys(users[login] for login in selected
                              if users[login] != users.get(author.lower())))


def build_discord_message(content, title, url, description, user_ids=()):
    message = f"{content}\n**[{escape_discord_text(title)}]({url})**\n{description}"
    if len(message) > 2000:
        raise SafeError("Discord 알림이 메시지 길이 제한을 초과했습니다.")
    return {
        "content": message,
        "allowed_mentions": {"parse": [], "users": list(dict.fromkeys(user_ids))},
        "flags": SUPPRESS_LINK_EMBEDS,
    }


def build_issue_opened_message(issue):
    author = escape_discord_text(issue["user"]["login"])
    title = f'#{issue["number"]} {issue["title"]}'
    return build_discord_message("📝 새 이슈가 등록됐어요.", title,
                                 issue["html_url"], f"작성자: {author}")


def build_merge_completed_message(pull_request):
    author = escape_discord_text(pull_request["user"]["login"])
    branch = escape_discord_text(pull_request["base"]["ref"])
    title = f'#{pull_request["number"]} {pull_request["title"]}'
    description = f"작성자: {author}\n대상: {branch}"
    return build_discord_message("🎉 PR이 머지됐어요.", title,
                                 pull_request["html_url"], description)


def build_review_request_message(pull_request, reviewer_ids):
    author = escape_discord_text(pull_request["user"]["login"])
    source = escape_discord_text(pull_request["head"]["ref"], 120)
    target = escape_discord_text(pull_request["base"]["ref"], 120)
    reviewers = " ".join(f"<@{user_id}>" for user_id in reviewer_ids) or "없음"
    description = f"작성자: {author}\n{source} → {target}\n리뷰어: {reviewers}"
    title = f'#{pull_request["number"]} {pull_request["title"]}'
    return build_discord_message("🚨 리뷰할 PR이 올라왔어요.", title,
                                 pull_request["html_url"], description, reviewer_ids)


def is_delivery_record(comment, marker):
    author = comment.get("user") or {}
    return (author.get("login") == "github-actions[bot]"
            and author.get("type") == "Bot"
            and marker in (comment.get("body") or ""))


def review_request_is_current(pull_request):
    return (pull_request["state"] == "open" and not pull_request["draft"]
            and pull_request["base"]["ref"] in MERGE_TARGETS)


def merge_state_is_known(pull_request):
    return (pull_request["mergeable"] != "UNKNOWN"
            and pull_request["mergeStateStatus"] != "UNKNOWN")


def same_ready_revision(previous, latest):
    return (is_ready(latest)
            and latest["headRefOid"] == previous["headRefOid"]
            and latest["baseRefName"] == previous["baseRefName"])


def build_merge_ready_message(pull_request, user_id):
    title = f'#{pull_request["number"]} {pull_request["title"]}'
    branch = escape_discord_text(pull_request["baseRefName"])
    content = f"✅ <@{user_id}> GitHub에서 머지 준비 상태가 확인됐어요. PR을 확인하고 직접 머지해 주세요."
    description = f"작성자: <@{user_id}>\n대상: {branch}"
    return build_discord_message(content, title, pull_request["url"], description, [user_id])


def is_ready(pr):
    return (pr["state"] == "OPEN" and not pr["isDraft"]
            and pr["baseRefName"] in MERGE_TARGETS
            and pr["mergeable"] == "MERGEABLE"
            and pr["mergeStateStatus"] == "CLEAN"
            and pr.get("reviewDecision") in (None, "APPROVED")
            and pr.get("mergeQueueEntry") is None)


def build_github_headers(token):
    return {"Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "dobby-discord-notifier",
            "X-GitHub-Api-Version": "2022-11-28"}


class Notifier:
    def __init__(self):
        self.repo = os.environ["GITHUB_REPOSITORY"]
        self.owner, self.name = self.repo.split("/")
        self.api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        self.graphql_url = os.environ.get("GITHUB_GRAPHQL_URL", "https://api.github.com/graphql")
        self.headers = build_github_headers(os.environ["GITHUB_TOKEN"])

    def request_repository_json(self, path, method="GET", body=None):
        return request_json(self.api + "/repos/" + self.repo + path, self.headers, method, body)

    def graphql(self, query, variables):
        result = request_json(self.graphql_url, self.headers, "POST", {
            "query": query, "variables": dict(owner=self.owner, name=self.name, **variables)})
        if not result or result.get("errors"):
            raise SafeError("GitHub GraphQL 조회 실패. 민감한 응답 내용은 출력하지 않습니다.")
        return result["data"]["repository"]

    def pages(self, path):
        separator = "&" if "?" in path else "?"
        page = 1
        while True:
            items = self.request_repository_json(f"{path}{separator}per_page=100&page={page}")
            yield from items
            if len(items) < 100:
                return
            page += 1

    def allowed(self, branch):
        return branch in MERGE_TARGETS

    def send_discord_message(self, route, message):
        variable = "DISCORD_ISSUE_WEBHOOK_URL" if route == "issue" else "DISCORD_PR_WEBHOOK_URL"
        response = request_json(build_confirmed_webhook_url(os.environ.get(variable, "")),
                                {"Content-Type": "application/json", "User-Agent": "dobby-discord-notifier"},
                                "POST", message, "Discord")
        if not isinstance(response, dict) or not response.get("id"):
            raise SafeError("Discord에서 발송 확인을 받지 못했습니다.")

    def has_delivery_record(self, number, marker):
        comments = self.pages(f"/issues/{number}/comments")
        return any(is_delivery_record(comment, marker) for comment in comments)

    def record_delivery(self, number, marker):
        body = marker + "\nDiscord 알림 발송 기록입니다. 중복 방지를 위해 유지해 주세요."
        self.request_repository_json(f"/issues/{number}/comments", "POST", {"body": body})

    def send_notification_once(self, number, key, route, message):
        marker = f"<!-- discord-notify:v1:{key} -->"
        if self.has_delivery_record(number, marker):
            return False
        self.send_discord_message(route, message)
        self.record_delivery(number, marker)
        print(f"Notification sent: #{number}, {key.split(':')[0]}.")
        return True

    def handle_event(self, event, event_name):
        if event_name == "issues":
            self.handle_issue_event(event)
        elif event_name == "pull_request_target":
            self.handle_pull_request_event(event)

    def handle_issue_event(self, event):
        if event.get("action") != "opened" or event["issue"].get("pull_request"):
            return
        self.send_discord_message("issue", build_issue_opened_message(event["issue"]))

    def handle_pull_request_event(self, event):
        pull_request = event["pull_request"]
        if not self.allowed(pull_request["base"]["ref"]):
            return
        action = event.get("action")
        if action == "closed" and pull_request.get("merged"):
            self.notify_merge_completed(pull_request)
        elif action in ("opened", "ready_for_review") and not pull_request.get("draft"):
            self.notify_review_requested(pull_request["number"])

    def notify_merge_completed(self, pull_request):
        message = build_merge_completed_message(pull_request)
        self.send_notification_once(pull_request["number"], "pr-merged", "pr", message)

    def notify_review_requested(self, number):
        pull_request = self.request_repository_json(f"/pulls/{number}")
        if not review_request_is_current(pull_request):
            return
        user_ids = parse_discord_user_ids(os.environ.get("DISCORD_USER_MAP", ""))
        reviewer_ids = reviewers_for(pull_request["user"]["login"], user_ids)
        message = build_review_request_message(pull_request, reviewer_ids)
        self.send_notification_once(number, "pr-announced", "pr", message)

    def request_pull_request(self, number):
        return self.graphql(PULL_REQUEST_QUERY, {"number": number})["pullRequest"]

    def branch_uses_merge_queue(self, branch):
        repository = self.graphql(MERGE_QUEUE_QUERY, {"branch": branch})
        return repository["mergeQueue"] is not None

    def request_resolved_pull_request(self, number):
        pull_request = self.request_pull_request(number)
        for _ in range(2):
            if merge_state_is_known(pull_request):
                return pull_request
            time.sleep(5)
            pull_request = self.request_pull_request(number)
        return pull_request

    def branch_requires_merge_queue(self, branch, queue_states):
        if branch not in queue_states:
            queue_states[branch] = self.branch_uses_merge_queue(branch)
        return queue_states[branch]

    def request_unchanged_ready_pull_request(self, pull_request):
        latest = self.request_pull_request(pull_request["number"])
        return latest if same_ready_revision(pull_request, latest) else None

    def request_notifiable_pull_request(self, number, queue_states):
        pull_request = self.request_resolved_pull_request(number)
        if not is_ready(pull_request):
            return None
        branch = pull_request["baseRefName"]
        if self.branch_requires_merge_queue(branch, queue_states):
            print(f"Skipped #{number}: merge queue requires a separate notification policy.")
            return None
        return self.request_unchanged_ready_pull_request(pull_request)

    def notify_merge_ready_author(self, pull_request, user_ids):
        login = (pull_request.get("author") or {}).get("login", "").lower()
        user_id = user_ids.get(login)
        if not user_id:
            print(f'::warning::PR #{pull_request["number"]}: 작성자 대응표가 없어 머지 준비 알림을 보류합니다.')
            return
        key = f'pr-ready:{pull_request["headRefOid"]}'
        message = build_merge_ready_message(pull_request, user_id)
        self.send_notification_once(pull_request["number"], key, "pr", message)

    def notify_merge_ready_pull_request(self, number, user_ids, queue_states):
        pull_request = self.request_notifiable_pull_request(number, queue_states)
        if pull_request:
            self.notify_merge_ready_author(pull_request, user_ids)

    def process_merge_ready_pull_request(self, number, user_ids, queue_states):
        try:
            self.notify_merge_ready_pull_request(number, user_ids, queue_states)
            return True
        except SafeError as error:
            print(f"::error::PR #{number}: {error}")
            return False

    def notify_merge_ready_pull_requests(self):
        user_ids = parse_discord_user_ids(os.environ.get("DISCORD_USER_MAP", ""))
        queue_states = {}
        results = [self.process_merge_ready_pull_request(item["number"], user_ids, queue_states)
                   for item in self.pages("/pulls?state=open") if self.merge_ready_candidate(item)]
        if not all(results):
            raise SafeError("일부 PR 알림 처리가 실패했습니다. 위의 비밀 값 없는 오류를 확인하세요.")

    def merge_ready_candidate(self, pull_request):
        return (not pull_request["draft"]
                and self.allowed(pull_request["base"]["ref"]))


def main():
    notifier = Notifier()
    if sys.argv[1:] == ["event"]:
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
            notifier.handle_event(json.load(source), os.environ["GITHUB_EVENT_NAME"])
    elif sys.argv[1:] == ["ready"]:
        notifier.notify_merge_ready_pull_requests()
    else:
        raise SafeError("사용법: discord_notify.py event|ready")


if __name__ == "__main__":
    try:
        main()
    except SafeError as error:
        print(f"::error::{error}")
        sys.exit(1)
    except Exception:
        print("::error::알림 실행 실패. 비밀 보호를 위해 상세 예외와 환경변수는 출력하지 않습니다.")
        sys.exit(1)
