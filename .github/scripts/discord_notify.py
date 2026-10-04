"""Discord notifications. Python standard library only; never log secrets/payloads."""

import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


class SafeError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward credentials to another host.


def request_json(url, headers, method="GET", body=None, service="GitHub"):
    data = None if body is None else json.dumps(body).encode()
    for attempt in range(3):
        try:
            req = Request(url, data=data, headers=headers, method=method)
            with build_opener(NoRedirect()).open(req, timeout=25) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except HTTPError as error:
            if error.code == 429 and attempt < 2:
                try:
                    delay = float(error.headers.get("Retry-After", "2"))
                except ValueError:
                    delay = 2
                if 0 <= delay <= 30:
                    time.sleep(delay + 1)
                    continue
            raise SafeError(f"{service} HTTP {error.code}; 응답/URL은 비밀 보호를 위해 생략합니다.") from None
        except (URLError, TimeoutError, OSError, ValueError):
            # Do not expose webhook URL, request, response or the member map.
            raise SafeError(f"{service} 연결 또는 응답 오류. 비밀 값은 로그에 출력하지 않습니다.") from None


def clean(value, limit=250):
    # Prevent titles/branch names from introducing mentions or formatting.
    text = re.sub(r"[\x00-\x1f\x7f]", " ", str(value))[:limit]
    text = text.replace("@", "＠").replace("<", "＜").replace(">", "＞")
    return re.sub(r"([\\`*_~|\[\]])", r"\\\1", text)


def member_map(raw):
    try:
        result = json.loads(raw or "{}")
        if not isinstance(result, dict):
            raise ValueError()
        if any(not isinstance(k, str) or not isinstance(v, str)
               or not re.fullmatch(r"[0-9]{17,20}", v) for k, v in result.items()):
            raise ValueError()
        return {key.lower(): value for key, value in result.items()}
    except (ValueError, TypeError):
        raise SafeError("DISCORD_USER_MAP 형식 오류. GitHub 아이디:문자열 사용자 ID 형태의 JSON이 필요합니다.") from None


def webhook_url(raw):
    parsed = urlsplit(raw)
    if (parsed.scheme != "https" or parsed.netloc != "discord.com"
            or not re.fullmatch(r"/api(?:/v\d+)?/webhooks/\d+/[A-Za-z0-9._-]+", parsed.path)):
        raise SafeError("Discord Webhook Secret 형식이 잘못되었거나 비어 있습니다.")
    query = dict(parse_qsl(parsed.query))
    query["wait"] = "true"
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))


def payload(content, title, url, description, color, user_id=None):
    return {
        "content": content,
        "allowed_mentions": {"parse": [], "users": [user_id] if user_id else []},
        "embeds": [{"title": clean(title), "url": url,
                    "description": description, "color": color}],
    }


def is_ready(pr):
    return (pr["state"] == "OPEN" and not pr["isDraft"]
            and pr["mergeable"] == "MERGEABLE"
            and pr["mergeStateStatus"] == "CLEAN"
            and pr.get("reviewDecision") in (None, "APPROVED")
            and pr.get("mergeQueueEntry") is None)


class Notifier:
    def __init__(self):
        self.repo = os.environ["GITHUB_REPOSITORY"]
        self.owner, self.name = self.repo.split("/")
        self.api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        self.graphql_url = os.environ.get("GITHUB_GRAPHQL_URL", "https://api.github.com/graphql")
        self.headers = {"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
                        "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                        "User-Agent": "dobby-discord-notifier", "X-GitHub-Api-Version": "2022-11-28"}
        self.branches = {x.strip() for x in os.environ.get("TARGET_BRANCHES", "").split(",") if x.strip()}

    def github(self, path, method="GET", body=None):
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
            items = self.github(f"{path}{separator}per_page=100&page={page}")
            yield from items
            if len(items) < 100:
                return
            page += 1

    def allowed(self, branch):
        return not self.branches or branch in self.branches

    def send_once(self, number, key, route, message):
        marker = f"<!-- discord-notify:v1:{key} -->"
        for comment in self.pages(f"/issues/{number}/comments"):
            author = comment.get("user") or {}
            if (author.get("login") == "github-actions[bot]" and author.get("type") == "Bot"
                    and marker in (comment.get("body") or "")):
                return False
        variable = "DISCORD_ISSUE_WEBHOOK_URL" if route == "issue" else "DISCORD_PR_WEBHOOK_URL"
        response = request_json(webhook_url(os.environ.get(variable, "")),
                                {"Content-Type": "application/json", "User-Agent": "dobby-discord-notifier"},
                                "POST", message, "Discord")
        if not isinstance(response, dict) or not response.get("id"):
            raise SafeError("Discord에서 발송 확인을 받지 못했습니다.")
        # Only GitHub state appears in this public comment. No Discord IDs/URLs.
        self.github(f"/issues/{number}/comments", "POST", {
            "body": marker + "\nDiscord 알림 발송 기록입니다. 중복 방지를 위해 유지해 주세요."})
        print(f"Notification sent: #{number}, {key.split(':')[0]}.")
        return True

    def event(self, event, event_name):
        if event_name == "issues" and event.get("action") == "opened":
            item = event["issue"]
            if item.get("pull_request"):
                return
            self.send_once(item["number"], "issue-opened", "issue", payload(
                "📝 새 이슈가 등록됐어요.", f'#{item["number"]} {item["title"]}',
                item["html_url"], f'작성자: {clean(item["user"]["login"])}', 0x3498DB))
            return
        if event_name != "pull_request_target":
            return
        item = event["pull_request"]
        action = event.get("action")
        if not self.allowed(item["base"]["ref"]):
            return
        if action == "closed" and item.get("merged"):
            author = clean(item["user"]["login"])
            merger = clean((item.get("merged_by") or {}).get("login", "확인 불가"))
            self.send_once(item["number"], "pr-merged", "pr", payload(
                "🎉 PR이 머지됐어요.", f'#{item["number"]} {item["title"]}', item["html_url"],
                f'작성자: {author}\n머지한 사람: {merger}\n대상: {clean(item["base"]["ref"])}', 0x9B59B6))
        elif action in ("opened", "ready_for_review") and not item.get("draft"):
            current = self.github(f'/pulls/{item["number"]}')
            if current["draft"] or current["state"] != "open" or not self.allowed(current["base"]["ref"]):
                return
            # Shared key: drafting/reopening repeatedly won't repeat the introduction.
            self.send_once(item["number"], "pr-announced", "pr", payload(
                "👀 리뷰할 PR이 올라왔어요.", f'#{current["number"]} {current["title"]}',
                current["html_url"], f'작성자: {clean(current["user"]["login"])}\n'
                f'{clean(current["head"]["ref"])} → {clean(current["base"]["ref"])}', 0xF1C40F))

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
        users = member_map(os.environ.get("DISCORD_USER_MAP", ""))
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
                # Re-query before notifying to catch new commits/drafts/changed approvals.
                latest = self.snapshot(number)
                if (not is_ready(latest) or latest["headRefOid"] != pr["headRefOid"]
                        or latest["baseRefName"] != branch):
                    continue
                pr = latest
                login = (pr.get("author") or {}).get("login", "")
                user_id = users.get(login.lower())
                if not user_id:
                    # No unmentionable notification/marker: fixing the map lets next run retry.
                    print(f"::warning::PR #{number}: 작성자 대응표가 없어 머지 준비 알림을 보류합니다.")
                    continue
                key = f'pr-ready:{pr["headRefOid"]}'
                self.send_once(number, key, "pr", payload(
                    f"✅ <@{user_id}> GitHub에서 머지 준비 상태가 확인됐어요. PR을 확인하고 직접 머지해 주세요.",
                    f'#{number} {pr["title"]}', pr["url"],
                    f'작성자: {clean(login)}\n대상: {clean(branch)}\n'
                    '확인 시점 기준 GitHub 상태: CLEAN\n최종 상태는 PR 화면에서 확인해 주세요.', 0x2ECC71, user_id))
            except SafeError as error:
                # Error strings here are controlled and never contain secrets.
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
