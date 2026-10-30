#!/usr/bin/env python3
"""Configure a private Xcode run scheme; never put the token in the app bundle."""

import getpass
import os
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


def main():
    repo = Path(__file__).resolve().parent.parent
    credential_file = repo / "Backend/garment-ai-worker/.dev.vars.live-check"
    if not credential_file.is_file():
        sys.exit("로컬 Worker 개발용 인증 파일이 필요합니다. 토큰을 채팅이나 소스에 입력하지 마세요.")
    if credential_file.stat().st_mode & 0o077:
        sys.exit("개발용 인증 파일의 권한을 600으로 설정해 주세요.")
    match = re.search(r'^DRAFT_API_TOKEN=([A-Za-z0-9_-]{32,1024})\s*$',
                      credential_file.read_text(), re.MULTILINE)
    if not match:
        sys.exit("개발용 인증 파일의 DRAFT_API_TOKEN 형식을 확인해 주세요.")

    project = repo / "Dobby/Dobby.xcodeproj"
    shared = project / "xcshareddata/xcschemes/Dobby.xcscheme"
    directory = project / "xcuserdata" / (getpass.getuser() + ".xcuserdatad") / "xcschemes"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = directory / "Dobby AI Local.xcscheme"
    tree = ET.parse(destination if destination.exists() else shared)
    launch = tree.getroot().find("LaunchAction")
    if launch is None:
        sys.exit("Xcode 실행 설정을 확인하지 못했습니다.")
    environment = launch.find("EnvironmentVariables")
    if environment is None:
        environment = ET.SubElement(launch, "EnvironmentVariables")
    for entry in list(environment):
        if entry.get("key") in {"DOBBY_AI_AUTH_TOKEN", "DOBBY_AI_FIXTURE_RESULT"}:
            environment.remove(entry)
    ET.SubElement(environment, "EnvironmentVariable", {
        "key": "DOBBY_AI_AUTH_TOKEN", "value": match[1], "isEnabled": "YES"
    })
    ET.indent(tree, space="   ")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        tree.write(output, encoding="UTF-8", xml_declaration=True)
    destination.chmod(0o600)

    management = directory / "xcschememanagement.plist"
    values = plistlib.loads(management.read_bytes()) if management.exists() else {}
    values.setdefault("SchemeUserState", {}).setdefault(destination.name, {
        "isShown": True, "orderHint": 0
    })
    descriptor = os.open(management, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        plistlib.dump(values, output)
    management.chmod(0o600)
    print("개인용 Xcode 실행 설정 준비 완료: Dobby AI Local")
    print("인증값은 출력하거나 앱에 포함하지 않았습니다. 공유 scheme은 변경하지 않았습니다.")


if __name__ == "__main__":
    main()
