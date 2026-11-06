import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


DEFAULT_REVIEWERS = ("moogoochung", "tobae-time", "hana5111", "decl5th")
MERGE_TARGETS = frozenset(("develop", "main"))
NETWORK_ERRORS = (URLError, TimeoutError, OSError, ValueError)
REQUEST_ATTEMPTS = 3
SUPPRESS_LINK_EMBEDS = 4


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


def request_json(url, headers, method="GET", body=None, service="Discord"):
    for attempt in range(REQUEST_ATTEMPTS):
        try:
            return read_json_response(build_json_request(url, headers, method, body))
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


def valid_discord_user_id(login, user_id):
    return (isinstance(login, str) and isinstance(user_id, str)
            and re.fullmatch(r"[0-9]{17,20}", user_id))


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


def valid_webhook(webhook):
    path_pattern = r"/api(?:/v\d+)?/webhooks/\d+/[A-Za-z0-9._-]+"
    return (webhook.scheme == "https" and webhook.netloc == "discord.com"
            and re.fullmatch(path_pattern, webhook.path))


def build_confirmed_webhook_url(raw_url):
    webhook = urlsplit(raw_url)
    if not valid_webhook(webhook):
        raise SafeError("Discord Webhook Secret 형식이 잘못되었거나 비어 있습니다.")
    query = dict(parse_qsl(webhook.query))
    query["wait"] = "true"
    return urlunsplit((webhook.scheme, webhook.netloc, webhook.path, urlencode(query), ""))


def select_reviewer_user_ids(author_login, discord_user_ids):
    configured_logins = os.environ.get("REVIEWER_LOGINS", "").strip()
    reviewer_logins = configured_logins.split(",") if configured_logins else DEFAULT_REVIEWERS
    reviewer_logins = dict.fromkeys(login.strip().lower() for login in reviewer_logins if login.strip())
    selected_logins = [login for login in reviewer_logins if login != author_login.lower()]
    if any(login not in discord_user_ids for login in selected_logins):
        raise SafeError("리뷰어의 DISCORD_USER_MAP 항목이 누락되어 리뷰 요청 알림을 보류합니다.")
    return list(dict.fromkeys(discord_user_ids[login] for login in selected_logins
                              if discord_user_ids[login] != discord_user_ids.get(author_login.lower())))


def build_discord_message(content, title, url, description, user_ids=()):
    message = f"{content}\n**[{escape_discord_text(title)}]({url})**\n{description}"
    if len(message) > 2000:
        raise SafeError("Discord 알림이 메시지 길이 제한을 초과했습니다.")
    return {"content": message,
            "allowed_mentions": {"parse": [], "users": list(dict.fromkeys(user_ids))},
            "flags": SUPPRESS_LINK_EMBEDS}


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


def build_approval_message(pull_request, reviewer_login, author_user_id):
    title = f'#{pull_request["number"]} {pull_request["title"]}'
    branch = escape_discord_text(pull_request["base"]["ref"])
    reviewer = escape_discord_text(reviewer_login)
    content = f"✅ <@{author_user_id}> PR이 승인됐어요. CI 상태를 확인하고 머지해 주세요."
    description = f"대상: {branch}\n승인자: {reviewer}"
    return build_discord_message(content, title, pull_request["html_url"],
                                 description, [author_user_id])


def build_review_request_message(pull_request, reviewer_ids):
    author = escape_discord_text(pull_request["user"]["login"])
    source = escape_discord_text(pull_request["head"]["ref"], 120)
    target = escape_discord_text(pull_request["base"]["ref"], 120)
    reviewers = " ".join(f"<@{user_id}>" for user_id in reviewer_ids) or "없음"
    description = f"작성자: {author}\n{source} → {target}\n리뷰어: {reviewers}"
    title = f'#{pull_request["number"]} {pull_request["title"]}'
    return build_discord_message("🚨 리뷰할 PR이 올라왔어요.", title,
                                 pull_request["html_url"], description, reviewer_ids)


def review_request_is_current(pull_request):
    return (pull_request["state"] == "open" and not pull_request["draft"]
            and pull_request["base"]["ref"] in MERGE_TARGETS)


def required_environment(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise SafeError(f"필수 GitHub Actions 설정 {name}이 비어 있습니다.")
    return value


def github_headers():
    return {"Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {required_environment('GITHUB_TOKEN')}",
            "User-Agent": "dobby-discord-notifier",
            "X-GitHub-Api-Version": "2022-11-28"}


def github_repository():
    repository = required_environment("GITHUB_REPOSITORY")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SafeError("GITHUB_REPOSITORY 형식이 올바르지 않습니다.")
    return repository


def pull_request_number():
    number = required_environment("PULL_REQUEST_NUMBER")
    if not number.isdigit():
        raise SafeError("PULL_REQUEST_NUMBER 형식이 올바르지 않습니다.")
    return number


def github_pull_request_path(number, suffix=""):
    repository = github_repository()
    return f"https://api.github.com/repos/{repository}/pulls/{number}{suffix}"


def latest_current_approval(pull_request, reviews):
    head_sha = pull_request["head"]["sha"]
    approvals = [review for review in reviews
                 if review.get("state") == "APPROVED" and review.get("commit_id") == head_sha]
    return max(approvals, key=lambda review: review.get("submitted_at", ""), default=None)


class Notifier:
    def branch_receives_notifications(self, branch):
        return branch in MERGE_TARGETS

    def send_discord_message(self, route, message):
        variable = "DISCORD_ISSUE_WEBHOOK_URL" if route == "issue" else "DISCORD_PR_WEBHOOK_URL"
        url = build_confirmed_webhook_url(os.environ.get(variable, ""))
        headers = {"Content-Type": "application/json", "User-Agent": "dobby-discord-notifier"}
        response = request_json(url, headers, "POST", message)
        if not isinstance(response, dict) or not response.get("id"):
            raise SafeError("Discord에서 발송 확인을 받지 못했습니다.")

    def handle_event(self, event, event_name):
        handlers = {"issues": self.handle_issue_event,
                    "pull_request_target": self.handle_pull_request_event}
        handler = handlers.get(event_name)
        if handler:
            handler(event)

    def handle_issue_event(self, event):
        if event.get("action") != "opened" or event["issue"].get("pull_request"):
            return
        self.send_discord_message("issue", build_issue_opened_message(event["issue"]))

    def handle_pull_request_event(self, event):
        pull_request = event["pull_request"]
        if not self.branch_receives_notifications(pull_request["base"]["ref"]):
            return
        action = event.get("action")
        if action == "closed" and pull_request.get("merged"):
            self.notify_merge_completed(pull_request)
        elif action in ("opened", "ready_for_review") and not pull_request.get("draft"):
            self.notify_review_requested(pull_request)

    def discord_user_ids(self):
        return parse_discord_user_ids(os.environ.get("DISCORD_USER_MAP", ""))

    def discord_user_id_for_author(self, pull_request):
        author_login = pull_request["user"]["login"].lower()
        return self.discord_user_ids().get(author_login)

    def request_pull_request(self, number):
        return request_json(github_pull_request_path(number), github_headers(), service="GitHub")

    def request_reviews(self, number):
        path = github_pull_request_path(number, "/reviews?per_page=100")
        return request_json(path, github_headers(), service="GitHub")

    def notify_approved_pull_request(self):
        number = pull_request_number()
        pull_request = self.request_pull_request(number)
        if not review_request_is_current(pull_request):
            return
        approval = latest_current_approval(pull_request, self.request_reviews(number))
        if not approval:
            return
        self.notify_approval(pull_request, approval["user"]["login"])

    def notify_approval(self, pull_request, reviewer_login):
        author_user_id = self.discord_user_id_for_author(pull_request)
        if not author_user_id:
            print(f'::warning::PR #{pull_request["number"]}: 작성자 대응표가 없어 승인 알림을 보류합니다.')
            return
        message = build_approval_message(pull_request, reviewer_login, author_user_id)
        self.send_discord_message("pr", message)

    def notify_merge_completed(self, pull_request):
        self.send_discord_message("pr", build_merge_completed_message(pull_request))

    def notify_review_requested(self, pull_request):
        if not review_request_is_current(pull_request):
            return
        user_ids = self.discord_user_ids()
        reviewer_ids = select_reviewer_user_ids(pull_request["user"]["login"], user_ids)
        self.send_discord_message("pr", build_review_request_message(pull_request, reviewer_ids))


def load_event():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
        return json.load(source)


def main():
    command = sys.argv[1:]
    if command == ["event"]:
        Notifier().handle_event(load_event(), required_environment("GITHUB_EVENT_NAME"))
    elif command == ["approval"]:
        Notifier().notify_approved_pull_request()
    else:
        raise SafeError("사용법: discord_notify.py event|approval")


if __name__ == "__main__":
    try:
        main()
    except SafeError as error:
        print(f"::error::{error}")
        sys.exit(1)
    except Exception:
        print("::error::알림 실행 실패. 비밀 보호를 위해 상세 예외와 환경변수는 출력하지 않습니다.")
        sys.exit(1)
