#!/usr/bin/env python3
"""Local brand-only experiment: locate labels -> crop pixels -> transcribe crops.

The app credential is read server-side from a built app's Info.plist. It is never
served to the browser, logged, or written to reports. No OpenAI key is needed.
"""
import argparse
import base64
import io
import hashlib
import subprocess
import json
import math
import plistlib
import secrets
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image, ImageOps

WORKER = "https://dobby-openai.dobbyisvintage.workers.dev"
MAX_BODY = 12 * 1024 * 1024
Image.MAX_IMAGE_PIXELS = 20_000_000


class PilotError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise PilotError("API 리다이렉트가 발생해 중단했습니다.")


def encode_image(image, maximum=2048):
    image = ImageOps.exif_transpose(image).convert("RGB")
    image.thumbnail((maximum, maximum))
    for quality in (90, 80, 65, 50):
        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=quality)
        data = buffer.getvalue()
        if len(data) <= 1500 * 1024:
            return image, "data:image/jpeg;base64," + base64.b64encode(data).decode("ascii")
    raise PilotError("이미지 용량을 줄이지 못했습니다.")


def decode_image(data_url):
    if not isinstance(data_url, str) or not data_url.startswith(("data:image/jpeg;base64,", "data:image/png;base64,", "data:image/webp;base64,")):
        raise PilotError("JPG·PNG·WebP 이미지를 선택해 주세요.")
    data = base64.b64decode(data_url.split(",", 1)[1], validate=True)
    with Image.open(io.BytesIO(data)) as image:
        if image.width * image.height > Image.MAX_IMAGE_PIXELS:
            raise PilotError("이미지가 너무 큽니다.")
        image.load()
        return ImageOps.exif_transpose(image).convert("RGB")


def crop_box(box, size):
    """Top-left normalized coordinates -> clipped pixel box, including context."""
    values = [box.get(key) for key in ("x", "y", "width", "height")]
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in values):
        raise PilotError("라벨 영역 좌표가 올바르지 않습니다.")
    x, y, width, height = values
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1.000001 or y + height > 1.000001:
        raise PilotError("라벨 영역이 사진을 벗어났습니다.")
    iw, ih = size
    px, py = max(8, width * iw * .08), max(8, height * ih * .08)
    result = (max(0, math.floor(x * iw - px)), max(0, math.floor(y * ih - py)),
              min(iw, math.ceil((x + width) * iw + px)), min(ih, math.ceil((y + height) * ih + py)))
    if result[2] - result[0] < 16 or result[3] - result[1] < 16:
        raise PilotError("찾은 라벨 영역이 너무 작습니다.")
    return result


def ocr_readings(output):
    """Keep the last complete progress frame when the OCR budget expires."""
    readings = []
    for line in (output or b"").splitlines():
        try:
            value = json.loads(line)
            if isinstance(value.get("readings"), list):
                readings = value["readings"][:50]
        except (ValueError, AttributeError):
            pass
    return readings


class Pilot:
    def __init__(self, app_plist):
        with open(app_plist, "rb") as handle:
            key = plistlib.load(handle).get("InstagramAppAPIKey", "")
        if not isinstance(key, str) or not key or len(key) > 1024 or any(c.isspace() for c in key) or "$(" in key:
            raise PilotError("빌드된 앱의 공통 API 인증 설정을 확인해 주세요.")
        self._key = key
        installation_file = Path(tempfile.gettempdir()) / "dobby-brand-label-pilot-installation"
        try:
            installation = installation_file.read_text().strip()
        except FileNotFoundError:
            installation = secrets.token_hex(32)
            # Stable between launches; restarting does not reset installation limits.
            with installation_file.open("x") as handle:
                handle.write(installation)
            installation_file.chmod(0o600)
        if len(installation) != 64 or any(c not in "0123456789abcdef" for c in installation):
            raise PilotError("로컬 테스트 설치 식별자를 확인해 주세요.")
        self._installation = installation
        self._opener = urllib.request.build_opener(NoRedirect)
        source = Path(__file__).with_name("read-label-text.swift")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
        self._ocr_binary = Path(tempfile.gettempdir()) / ("dobby-brand-label-ocr-" + digest)
        if not self._ocr_binary.exists():
            subprocess.run(["swiftc", str(source), "-o", str(self._ocr_binary)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=45)

    def call(self, path, photos):
        request = urllib.request.Request(WORKER + "/v1/garments/" + path,
            data=json.dumps({"photos": photos}).encode(), method="POST", headers={
                "Content-Type": "application/json", "Cache-Control": "no-store", "User-Agent": "DobbyBrandLabelPilot/1.0",
                "Authorization": "Bearer " + self._installation, "X-Dobby-App-Key": self._key,
            })
        try:
            with self._opener.open(request, timeout=35) as response:
                return json.loads(response.read(MAX_BODY))
        except urllib.error.HTTPError as error:
            # Do not relay upstream response bodies or authorization headers.
            stage = "라벨 위치 찾기" if path.endswith("regions") else "크롭 원문 판독"
            try:
                failure = json.loads(error.read(4096)).get("error", {})
                code = failure.get("code", "")
                message = failure.get("message", "")
            except (ValueError, AttributeError):
                code, message = "", ""
            safe_codes = {"invalid_label_activity", "invalid_label_regions", "invalid_label_region", "invalid_label_box",
                "invalid_label_readings", "invalid_label_reading", "invalid_label_brand", "invalid_label_response", "incomplete_model_response", "model_refusal", "ai_unavailable", "invalid_ai_response", "ai_request_failed", "ai_rate_limited", "ai_configuration_error", "service_not_configured", "internal_error", "invalid_request", "invalid_photo", "photo_too_large", "photos_too_large", "request_too_large", "usage_protection_unavailable", "label_request_invalid_json_schema", "label_request_unsupported_parameter", "label_request_unsupported_value", "label_request_invalid_value", "label_request_bad_request"}
            detail = f" ({code})" if code in safe_codes else ""
            for param in ("text.format.schema", "text.format", "max_output_tokens", "reasoning.effort", "input", "model", "unknown_setting"):
                if message == "라벨 요청 설정 확인 필요: " + param:
                    detail += " · " + param
                    break
            raise PilotError(stage + f" (HTTP {error.code}): " + {429: "요청이 많습니다. 잠시 후 다시 시도해 주세요.",
                401: "앱 공통 API 인증을 확인해 주세요.", 404: "브랜드 테스트 API가 아직 배포되지 않았습니다.",
                504: "브랜드 판독 시간이 초과되었습니다."}.get(error.code, "브랜드 테스트 API 요청에 실패했습니다.") + detail) from None
        except (urllib.error.URLError, TimeoutError):
            raise PilotError("브랜드 테스트 서버에 연결하지 못했습니다.") from None

    def ocr(self, data_url):
        if not hasattr(self, "_ocr_binary"):
            return []
        with tempfile.TemporaryDirectory(prefix="dobby-label-ocr-") as directory:
            path = Path(directory) / "label.jpg"
            path.write_bytes(base64.b64decode(data_url.split(",", 1)[1]))
            try:
                run = subprocess.run([str(self._ocr_binary), str(path)], capture_output=True, check=True, timeout=35)
                return ocr_readings(run.stdout)
            except subprocess.TimeoutExpired as error:
                return ocr_readings(error.output)
            except (subprocess.SubprocessError, ValueError, KeyError):
                return []

    def run(self, value):
        raw_photos = value.get("photos") if isinstance(value, dict) else None
        if not isinstance(raw_photos, list) or not 1 <= len(raw_photos) <= 5:
            raise PilotError("같은 옷의 사진을 1~5장 선택해 주세요.")
        originals, photos = {}, []
        for raw in raw_photos:
            if not isinstance(raw, dict):
                raise PilotError("사진 요청 형식이 올바르지 않습니다.")
            photo_id = raw.get("id", str(uuid.uuid4()))
            if not isinstance(photo_id, str) or not photo_id.strip() or len(photo_id) > 100 or photo_id in originals:
                raise PilotError("사진 ID가 올바르지 않습니다.")
            image, data_url = encode_image(decode_image(raw.get("imageDataUrl")))
            originals[photo_id] = image
            photos.append({"id": photo_id, "role": "detail", "imageDataUrl": data_url})
        started = time.monotonic()
        located = self.call("brand-label-regions", photos)
        located_seconds = time.monotonic() - started
        regions = located.get("regions")
        if not isinstance(regions, list) or len(regions) > 3:
            raise PilotError("라벨 위치 응답을 확인하지 못했습니다.")
        crop_started = time.monotonic()
        crops, crop_photos = [], []
        for index, region in enumerate(regions):
            source_id = region.get("photoId")
            if source_id not in originals:
                raise PilotError("라벨의 원본 사진을 찾지 못했습니다.")
            image = originals[source_id]
            pixels = crop_box(region["box"], image.size)
            _, data_url = encode_image(image.crop(pixels))
            crop_id = f"label-crop-{index + 1}"
            crops.append({"id": crop_id, "sourcePhotoId": source_id, "kind": region["kind"],
                "normalizedBox": region["box"], "pixelBox": pixels,
                "sourceSize": list(image.size), "imageDataUrl": data_url})
            crop_photos.append({"id": crop_id, "role": "label", "imageDataUrl": data_url})
        # Prefer an actual brand label over care text, then the largest crop.
        # A single Vision process avoids cold-start contention between readers.
        best = min(crops, key=lambda c: (c["kind"] == "care_label",
            -(c["pixelBox"][2] - c["pixelBox"][0]) * (c["pixelBox"][3] - c["pixelBox"][1]))) if crops else None
        for crop, photo in zip(crops, crop_photos):
            ocr = self.ocr(crop["imageDataUrl"]) if crop is best else []
            crop["ocr"] = ocr
            crop["ocrStatus"] = "completed" if ocr else "unavailable" if crop is best else "not_selected"
            reliable = [item for item in ocr if item["confidence"] >= .8]
            photo["ocrText"] = "\n".join(f'{item["rotationDegrees"]}°: {item["text"]}' for item in reliable)[:1200]
        read_started = time.monotonic()
        read_error = None
        try:
            if crop_photos and not any(photo["ocrText"] for photo in crop_photos):
                raise PilotError("회전 OCR 원문을 확보하지 못해 브랜드 확정을 중단했습니다.")
            read = self.call("brand-label-readings", crop_photos) if crop_photos else {"brand": None, "readings": []}
        except PilotError as error:
            read = {"brand": None, "readings": []}
            read_error = str(error)
        return {"version": "brand-label-pilot-v1", "status": "read_failed" if read_error else "read" if crops else "no_label_region", "readError": read_error,
            "timing": {"locateSeconds": round(located_seconds, 2),
                "cropOCRSeconds": round(read_started - crop_started, 2), "readSeconds": round(time.monotonic() - read_started, 2), "totalSeconds": round(time.monotonic() - started, 2)},
            "photos": photos, "crops": crops, "readings": read["readings"], "brand": read["brand"]}


def serve(pilot, port):
    nonce, lock = secrets.token_urlsafe(32), threading.Lock()
    origin = f"http://127.0.0.1:{port}"
    page = Path(__file__).with_name("index.html").read_text().replace("__PILOT_NONCE__", nonce)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, status, data, mime="application/json; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.headers.get("Host") != f"127.0.0.1:{port}" or self.path != "/":
                return self.send(404, b'{}')
            self.send(200, page.encode(), "text/html; charset=utf-8")

        def do_POST(self):
            if self.path != "/analyze" or self.headers.get("Host") != f"127.0.0.1:{port}" or self.headers.get("Origin") != origin or self.headers.get("X-Pilot-Nonce") != nonce:
                return self.send(403, b'{}')
            if not lock.acquire(blocking=False):
                return self.send(409, json.dumps({"error": "이미 판독 중입니다."}).encode())
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY or self.headers.get("Content-Type") != "application/json":
                    raise PilotError("사진 요청 용량을 확인해 주세요.")
                result = pilot.run(json.loads(self.rfile.read(length)))
                self.send(200, json.dumps(result).encode())
            except (PilotError, ValueError, KeyError, OSError, Image.DecompressionBombError) as error:
                message = str(error) if isinstance(error, PilotError) else "사진 요청을 처리하지 못했습니다."
                self.send(400, json.dumps({"error": message}).encode())
            finally:
                lock.release()

    print(f"브랜드 라벨 분리 테스트: {origin}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-plist", required=True, type=Path)
    parser.add_argument("--port", type=int, default=8776)
    parser.add_argument("--request-json", type=Path, help="Run one saved photo request instead of the web UI")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    pilot = Pilot(args.app_plist)
    if args.request_json:
        if not args.output_dir:
            parser.error("--request-json requires --output-dir")
        result = pilot.run(json.loads(args.request_json.read_text()))
        args.output_dir.mkdir(parents=True, exist_ok=True)
        (args.output_dir / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        for crop in result["crops"]:
            (args.output_dir / f'{crop["id"]}.jpg').write_bytes(base64.b64decode(crop["imageDataUrl"].split(",", 1)[1]))
        print(json.dumps({key: result[key] for key in ("status", "brand", "readings", "timing")}, ensure_ascii=False))
    else:
        serve(pilot, args.port)


if __name__ == "__main__":
    main()
