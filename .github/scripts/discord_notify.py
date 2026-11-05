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


def payload(content, title, url, description, user_ids=()):
    message = f"{content}\n**[{escape_discord_text(title)}]({url})**\n{description}"
    if len(message) > 2000:
        raise SafeError("Discord 알림이 메시지 길이 제한을 초과했습니다.")
    return {
        "content": message,
        "allowed_mentions": {"parse": [], "users": list(dict.fromkeys(user_ids))},
        "flags": SUPPRESS_LINK_EMBEDS,
    }


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

    def send(self, route, message):
        variable = "DISCORD_ISSUE_WEBHOOK_URL" if route == "issue" else "DISCORD_PR_WEBHOOK_URL"
        response = request_json(build_confirmed_webhook_url(os.environ.get(variable, "")),
                                {"Content-Type": "application/json", "User-Agent": "dobby-discord-notifier"},
                                "POST", message, "Discord")
        if not isinstance(response, dict) or not response.get("id"):
            raise SafeError("Discord에서 발송 확인을 받지 못했습니다.")

    def send_once(self, number, key, route, message):
        marker = f"<!-- discord-notify:v1:{key} -->"
        for comment in self.pages(f"/issues/{number}/comments"):
            author = comment.get("user") or {}
            if (author.get("login") == "github-actions[bot]" and author.get("type") == "Bot"
                    and marker in (comment.get("body") or "")):
                return False
        self.send(route, message)
        self.request_repository_json(f"/issues/{number}/comments", "POST", {
            "body": marker + "\nDiscord 알림 발송 기록입니다. 중복 방지를 위해 유지해 주세요."})
        print(f"Notification sent: #{number}, {key.split(':')[0]}.")
        return True

    def event(self, event, event_name):
        if event_name == "issues" and event.get("action") == "opened":
            item = event["issue"]
            if item.get("pull_request"):
                return
            self.send("issue", payload(
                "📝 새 이슈가 등록됐어요.", f'#{item["number"]} {item["title"]}',
                item["html_url"], f'작성자: {escape_discord_text(item["user"]["login"])}'))
            return
        if event_name != "pull_request_target":
            return
        item = event["pull_request"]
        action = event.get("action")
        if not self.allowed(item["base"]["ref"]):
            return
        if action == "closed" and item.get("merged"):
            branch = item["base"]["ref"]
            author = escape_discord_text(item["user"]["login"])
            self.send_once(item["number"], "pr-merged", "pr", payload(
                "🎉 PR이 머지됐어요.", f'#{item["number"]} {item["title"]}', item["html_url"],
                f'작성자: {author}\n대상: {escape_discord_text(branch)}'))
        elif action in ("opened", "ready_for_review") and not item.get("draft"):
            current = self.request_repository_json(f'/pulls/{item["number"]}')
            if current["draft"] or current["state"] != "open" or not self.allowed(current["base"]["ref"]):
                return
            users = parse_discord_user_ids(os.environ.get("DISCORD_USER_MAP", ""))
            reviewer_ids = reviewers_for(current["user"]["login"], users)
            reviewer_line = " ".join(f"<@{user_id}>" for user_id in reviewer_ids) or "없음"
            self.send_once(item["number"], "pr-announced", "pr", payload(
                "🚨 리뷰할 PR이 올라왔어요.", f'#{current["number"]} {current["title"]}',
                current["html_url"], f'작성자: {escape_discord_text(current["user"]["login"])}\n'
                f'{escape_discord_text(current["head"]["ref"], 120)} → '
                f'{escape_discord_text(current["base"]["ref"], 120)}\n'
                f'리뷰어: {reviewer_line}', reviewer_ids))

    def snapshot(self, number):
        query = """query($owner:String!, $name:String!, $number:Int!) {
          repository(owner:$owner, name:$name) { pullRequest(number:$number) {
            number title url state isDraft headRefOid baseRefName
            author { login } mergeable mergeStateStatus reviewDecision mergeQueueEntry { id }
          } }
        }"""
        return self.graphql(query, {"number": number})["pullRequest"]

    def queue_enabled(self, branch):
        query = """query($owner:String!, $name:String!, $branch:String!) {
          repository(owner:$owner, name:$name) { mergeQueue(branch:$branch) { id } }
        }"""
        return self.graphql(query, {"branch": branch})["mergeQueue"] is not None

    def ready(self):
        users = parse_discord_user_ids(os.environ.get("DISCORD_USER_MAP", ""))
        failed = False
        queues = {}
        for listed in self.pages("/pulls?state=open"):
            if listed["draft"] or not self.allowed(listed["base"]["ref"]):
                continue
            number = listed["number"]
            try:
                pr = self.snapshot(number)
                for _ in range(2):
                    if pr["mergeable"] != "UNKNOWN" and pr["mergeStateStatus"] != "UNKNOWN":
                        break
                    time.sleep(5)
                    pr = self.snapshot(number)
                if not is_ready(pr) or not self.allowed(pr["baseRefName"]):
                    continue
                branch = pr["baseRefName"]
                if branch not in queues:
                    queues[branch] = self.queue_enabled(branch)
                if queues[branch]:
                    print(f"Skipped #{number}: merge queue requires a separate notification policy.")
                    continue
                latest = self.snapshot(number)
                if (not is_ready(latest) or latest["headRefOid"] != pr["headRefOid"]
                        or latest["baseRefName"] != branch):
                    continue
                pr = latest
                login = (pr.get("author") or {}).get("login", "")
                user_id = users.get(login.lower())
                if not user_id:
                    print(f"::warning::PR #{number}: 작성자 대응표가 없어 머지 준비 알림을 보류합니다.")
                    continue
                key = f'pr-ready:{pr["headRefOid"]}'
                self.send_once(number, key, "pr", payload(
                    f"✅ <@{user_id}> GitHub에서 머지 준비 상태가 확인됐어요. PR을 확인하고 직접 머지해 주세요.",
                    f'#{number} {pr["title"]}', pr["url"],
                    f'작성자: <@{user_id}>\n대상: {escape_discord_text(branch)}', [user_id]))
            except SafeError as error:
                print(f"::error::PR #{number}: {error}")
                failed = True
        if failed:
            raise SafeError("일부 PR 알림 처리가 실패했습니다. 위의 비밀 값 없는 오류를 확인하세요.")


def main():
    notifier = Notifier()
    if sys.argv[1:] == ["event"]:
        with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as source:
            notifier.event(json.load(source), os.environ["GITHUB_EVENT_NAME"])
    elif sys.argv[1:] == ["ready"]:
        notifier.ready()
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
