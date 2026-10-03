#!/usr/bin/env python3
import argparse
import base64
import hmac
import json
import mimetypes
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bcrypt


ROOT = pathlib.Path(__file__).resolve().parent
BASE_URL = "https://api.commerce.naver.com/external"
CATEGORY_CACHE = None
ALLOWED_CATEGORY_ROOTS = {"패션의류", "패션잡화"}


class NaverHTTPError(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body
        super().__init__(body.get("message") or body.get("code") or f"HTTP {status}")


def load_env():
    values = {}
    for raw_line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    client_id = values.get("NAVER_CLIENT_ID", "")
    client_secret = values.get("NAVER_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        raise SystemExit(".env에 NAVER_CLIENT_ID와 NAVER_CLIENT_SECRET을 입력해 주세요.")
    return client_id, client_secret


def request_json(path, method="GET", token=None, data=None, headers=None):
    request_headers = {"Accept": "application/json;charset=UTF-8"}
    if token:
        request_headers["Authorization"] = f"Bearer {token}"
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=data,
        headers=request_headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode("utf-8")
            return response.status, json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        text = error.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(text)
        except json.JSONDecodeError:
            body = {"raw": text}
        raise NaverHTTPError(error.code, body)


def issue_token():
    client_id, client_secret = load_env()
    timestamp = str(int(time.time() * 1000))
    hashed = bcrypt.hashpw(f"{client_id}_{timestamp}".encode(), client_secret.encode())
    signature = base64.b64encode(hashed).decode()
    form = urllib.parse.urlencode({
        "client_id": client_id,
        "timestamp": timestamp,
        "grant_type": "client_credentials",
        "client_secret_sign": signature,
        "type": "SELF",
    }).encode()
    _, body = request_json(
        "/v1/oauth2/token",
        method="POST",
        data=form,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    token = body.get("access_token")
    if not token:
        raise SystemExit("네이버가 access_token을 반환하지 않았습니다.")
    return token, body.get("expires_in")


def auth_summary():
    token, expires_in = issue_token()
    print(json.dumps({
        "authenticated": True,
        "expiresInSeconds": expires_in,
        "accessToken": f"{token[:6]}...{token[-4:]}",
    }, ensure_ascii=False, indent=2))


def seller_summary():
    token, _ = issue_token()
    _, account = request_json("/v1/seller/account", token=token)
    _, channels = request_json("/v1/seller/channels", token=token)
    _, addresses = request_json("/v1/seller/addressbooks-for-page?page=1", token=token)
    print(json.dumps({
        "account": account,
        "channels": channels,
        "addresses": addresses,
    }, ensure_ascii=False, indent=2))


def product_summary():
    token, _ = issue_token()
    body = json.dumps({"page": 1, "size": 10, "orderType": "REG_DATE"}).encode()
    _, products = request_json(
        "/v1/products/search",
        method="POST",
        token=token,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    print(json.dumps(products, ensure_ascii=False, indent=2))


def multipart_image(image_path):
    path = pathlib.Path(image_path)
    if not path.is_file():
        raise SystemExit(f"이미지 파일을 찾을 수 없습니다: {path}")
    boundary = f"----DobbyNaver{int(time.time() * 1000)}"
    mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    body = bytearray()
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(f'Content-Disposition: form-data; name="imageFiles"; filename="{path.name}"\r\n'.encode())
    body.extend(f"Content-Type: {mime_type}\r\n\r\n".encode())
    body.extend(path.read_bytes())
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    return bytes(body), boundary


def upload_image(image_path):
    token, _ = issue_token()
    body, boundary = multipart_image(image_path)
    _, result = request_json(
        "/v1/product-images/upload",
        method="POST",
        token=token,
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


def create_product(payload_path):
    payload = pathlib.Path(payload_path).read_bytes()
    json.loads(payload.decode("utf-8"))
    token, _ = issue_token()
    _, result = request_json(
        "/v2/products",
        method="POST",
        token=token,
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


def app_api_key():
    config = ROOT.parent.parent / "Config" / "DobbySecrets.xcconfig"
    if not config.exists():
        raise RuntimeError("Config/DobbySecrets.xcconfig를 찾을 수 없습니다.")
    for raw_line in config.read_text(encoding="utf-8").splitlines():
        if raw_line.strip().startswith("DOBBY_APP_API_KEY") and "=" in raw_line:
            value = raw_line.split("=", 1)[1].strip()
            if value:
                return value
    raise RuntimeError("DOBBY_APP_API_KEY가 설정되지 않았습니다.")


def all_categories(token):
    global CATEGORY_CACHE
    if CATEGORY_CACHE is None:
        _, CATEGORY_CACHE = request_json("/v1/categories?last=true", token=token)
    return CATEGORY_CACHE


def allowed_categories(token):
    return [category for category in all_categories(token)
            if category.get("wholeCategoryName", "").split(">", 1)[0] in ALLOWED_CATEGORY_ROOTS]


def seller_delivery_defaults(token):
    _, response = request_json("/v1/seller/addressbooks-for-page?page=1", token=token)
    addresses = response if isinstance(response, list) else (
        response.get("contents") or response.get("content") or response.get("addressBooks") or []
    )
    if isinstance(addresses, dict):
        addresses = list(addresses.values())

    def find_address(*types):
        expected = {value.upper() for value in types}
        return next((item for item in addresses
                     if str(item.get("addressType", "")).upper() in expected), None)

    shipping = find_address("RELEASE", "SHIPPING", "OUTBOUND")
    returning = find_address("REFUND_OR_EXCHANGE", "RETURN", "EXCHANGE")
    if not shipping or not returning:
        raise RuntimeError("네이버 판매자센터에서 출고지와 반품/교환지를 먼저 등록해 주세요.")

    shipping_id = shipping.get("addressBookNo") or shipping.get("id")
    return_id = returning.get("addressBookNo") or returning.get("id")
    phone = shipping.get("phoneNumber1") or shipping.get("phoneNumber2")
    if not shipping_id or not return_id or not phone:
        raise RuntimeError("네이버 출고지/반품지의 식별번호 또는 연락처를 확인할 수 없습니다.")
    return shipping_id, return_id, phone


def upload_image_bytes(token, image_bytes):
    boundary = f"----DobbyNaver{int(time.time() * 1000)}"
    body = bytearray()
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(b'Content-Disposition: form-data; name="imageFiles"; filename="product.jpg"\r\n')
    body.extend(b"Content-Type: image/jpeg\r\n\r\n")
    body.extend(image_bytes)
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    _, result = request_json(
        "/v1/product-images/upload", method="POST", token=token, data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    images = result.get("images") or []
    if not images or not images[0].get("url"):
        raise RuntimeError("네이버가 업로드된 이미지 URL을 반환하지 않았습니다.")
    return images[0]["url"]


def html_text(value):
    escaped = (value or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"<p>{escaped.replace(chr(10), '<br>')}</p>"


def publish_from_app(input_value):
    required = ["productName", "description", "categoryID", "imageBase64"]
    if any(not input_value.get(key) for key in required) or int(input_value.get("price", 0)) <= 0:
        raise ValueError("상품명, 가격, 카테고리, 사진을 확인해 주세요.")
    token, _ = issue_token()
    category_id = str(input_value["categoryID"])
    if not any(str(category.get("id")) == category_id for category in allowed_categories(token)):
        raise ValueError("패션의류 또는 패션잡화의 최종 카테고리를 선택해 주세요.")
    shipping_address_id, return_address_id, after_service_phone = seller_delivery_defaults(token)
    image_url = upload_image_bytes(token, base64.b64decode(input_value["imageBase64"], validate=True))
    notice_reference = "상품상세 참조"
    payload = {
        "originProduct": {
            "statusType": "SUSPENSION",
            "saleType": "OLD",
            "leafCategoryId": category_id,
            "name": str(input_value["productName"])[:100],
            "detailContent": html_text(input_value["description"]),
            "images": {"representativeImage": {"url": image_url}, "optionalImages": []},
            "salePrice": int(input_value["price"]),
            "stockQuantity": 1,
            "deliveryInfo": {
                "deliveryType": "DELIVERY",
                "deliveryAttributeType": "NORMAL",
                "deliveryCompany": "CJGLS",
                "deliveryFee": {
                    "deliveryFeeType": "PAID",
                    "baseFee": 4000,
                    "deliveryFeePayType": "PREPAID"
                },
                "claimDeliveryInfo": {
                    "returnDeliveryCompanyPriorityType": "PRIMARY",
                    "returnDeliveryFee": 4000,
                    "exchangeDeliveryFee": 8000,
                    "shippingAddressId": shipping_address_id,
                    "returnAddressId": return_address_id,
                    "freeReturnInsuranceYn": False
                }
            },
            "detailAttribute": {
                "originAreaInfo": {
                    "originAreaCode": "03",
                    "content": notice_reference,
                    "plural": False
                },
                "afterServiceInfo": {
                    "afterServiceTelephoneNumber": after_service_phone,
                    "afterServiceGuideContent": notice_reference
                },
                "minorPurchasable": True,
                "productInfoProvidedNotice": {
                    "productInfoProvidedNoticeType": "WEAR",
                    "wear": {
                        "returnCostReason": "0",
                        "noRefundReason": "0",
                        "qualityAssuranceStandard": "0",
                        "compensationProcedure": "1",
                        "troubleShootingContents": "1",
                        "material": input_value.get("material") or notice_reference,
                        "color": input_value.get("color") or notice_reference,
                        "size": input_value.get("size") or notice_reference,
                        "manufacturer": notice_reference,
                        "caution": notice_reference,
                        "packDateText": notice_reference,
                        "warrantyPolicy": notice_reference,
                        "afterServiceDirector": notice_reference
                    }
                }
            }
        },
        "smartstoreChannelProduct": {
            "naverShoppingRegistration": False,
            "channelProductDisplayStatusType": "SUSPENSION"
        }
    }
    body = json.dumps(payload, ensure_ascii=False).encode()
    _, result = request_json(
        "/v2/products", method="POST", token=token, data=body,
        headers={"Content-Type": "application/json"},
    )
    return {
        "originProductNo": result["originProductNo"],
        "smartstoreChannelProductNo": result["smartstoreChannelProductNo"],
    }


class AppHandler(BaseHTTPRequestHandler):
    server_version = "DobbyNaverLocal/1.0"

    def log_message(self, format, *args):
        print(f"[Naver Local] {self.address_string()} - {format % args}")

    def send_json(self, body, status=200):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        try:
            expected = app_api_key()
        except RuntimeError as error:
            self.send_json({"error": "server_not_configured", "message": str(error)}, 500)
            return False
        provided = self.headers.get("X-Dobby-App-Key", "")
        if not provided or not hmac.compare_digest(provided, expected):
            self.send_json({"error": "unauthorized", "message": "인증되지 않은 앱 요청입니다."}, 401)
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path == "/health":
                self.send_json({"ready": True})
                return
            if parsed.path == "/categories":
                query = urllib.parse.parse_qs(parsed.query).get("q", [""])[0].strip().lower()
                token, _ = issue_token()
                categories = allowed_categories(token)
                matches = ([category for category in categories
                            if query in category.get("wholeCategoryName", "").lower()]
                           if query else categories)
                self.send_json(matches if not query else matches[:50])
                return
            self.send_json({"error": "not_found"}, 404)
        except Exception as error:
            self.handle_error(error)

    def do_POST(self):
        if not self.authorized():
            return
        try:
            if self.path != "/products":
                self.send_json({"error": "not_found"}, 404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            input_value = json.loads(self.rfile.read(length))
            self.send_json(publish_from_app(input_value), 201)
        except Exception as error:
            self.handle_error(error)

    def handle_error(self, error):
        if isinstance(error, NaverHTTPError):
            print(json.dumps({"event": "naver_api_error", "status": error.status, "response": error.body},
                             ensure_ascii=False))
            details = []
            for invalid in error.body.get("invalidInputs") or []:
                field = invalid.get("name") or invalid.get("field") or invalid.get("path")
                reason = invalid.get("message") or invalid.get("reason")
                details.append(": ".join(value for value in (field, reason) if value))
            message = error.body.get("message") or str(error)
            if details:
                message += "\n확인할 항목: " + ", ".join(details)
            trace_id = error.body.get("traceId") or error.body.get("trace_id")
            if trace_id:
                message += f"\n추적 ID: {trace_id}"
            self.send_json({"error": error.body.get("code", "naver_error"),
                            "message": message, "traceId": trace_id}, error.status)
        elif isinstance(error, (ValueError, base64.binascii.Error)):
            self.send_json({"error": "invalid_request", "message": str(error)}, 400)
        else:
            print(json.dumps({"event": "local_server_error", "message": str(error)}, ensure_ascii=False))
            self.send_json({"error": "server_error", "message": str(error)}, 500)


def serve(port):
    server = ThreadingHTTPServer(("0.0.0.0", port), AppHandler)
    print(f"Dobby Naver local server: http://0.0.0.0:{port}")
    print("종료: Control-C")
    server.serve_forever()


def local_check(port, query):
    encoded_query = urllib.parse.urlencode({"q": query})
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/categories?{encoded_query}",
        headers={"X-Dobby-App-Key": app_api_key()},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        categories = json.loads(response.read())
    print(json.dumps({"connected": True, "matchingCategories": len(categories),
                      "examples": categories[:3]}, ensure_ascii=False, indent=2))


parser = argparse.ArgumentParser(description="Dobby 네이버 커머스API 로컬 테스트")
subparsers = parser.add_subparsers(dest="command", required=True)
subparsers.add_parser("auth")
subparsers.add_parser("seller")
subparsers.add_parser("products")
upload_parser = subparsers.add_parser("upload-image")
upload_parser.add_argument("image")
product_parser = subparsers.add_parser("create-product")
product_parser.add_argument("payload")
serve_parser = subparsers.add_parser("serve")
serve_parser.add_argument("--port", type=int, default=8788)
check_parser = subparsers.add_parser("local-check")
check_parser.add_argument("--port", type=int, default=8788)
check_parser.add_argument("--query", default="청바지")
args = parser.parse_args()

if args.command == "auth":
    auth_summary()
elif args.command == "seller":
    seller_summary()
elif args.command == "products":
    product_summary()
elif args.command == "upload-image":
    upload_image(args.image)
elif args.command == "create-product":
    create_product(args.payload)
elif args.command == "serve":
    serve(args.port)
elif args.command == "local-check":
    local_check(args.port, args.query)
