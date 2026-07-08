import base64
import calendar
import json
import os
import re
import threading
import secrets
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque

import botconfig
import trust


BASE_DIR = os.path.dirname(os.path.abspath(__file__))


EVENTSUB_HOST = "eventsub.wss.twitch.tv"
EVENTSUB_PATH = "/ws"
HELIX_BASE = "https://api.twitch.tv/helix"
OAUTH_BASE = "https://id.twitch.tv/oauth2"

SPAM_PATTERNS = [
    re.compile(r"https?://\S+", re.IGNORECASE),
    re.compile(r"discord\.gg/\S+", re.IGNORECASE),
    re.compile(r"bit\.ly/\S+", re.IGNORECASE),
    re.compile(r"t\.me/\S+", re.IGNORECASE),
    re.compile(r"follow\s+(me|us|back)\b", re.IGNORECASE),
    re.compile(r"free\s+(followers|views|subs|subscribers)", re.IGNORECASE),
    re.compile(r"buy\s+(followers|views|subs|subscribers)", re.IGNORECASE),
    re.compile(r"check\s+my\s+(channel|stream|profile)", re.IGNORECASE),
    re.compile(r"@everyone", re.IGNORECASE),
    # Only flag genuinely floody runs (15+ identical chars). The old {6,}
    # threshold caught normal chat like "LMAOOOOOOO" and "noooooo way".
    re.compile(r"(\w)\1{14,}", re.IGNORECASE),
]

BOT_USERNAME_PATTERNS = [
    re.compile(r"^[a-z]{2,5}\d{7,}$"),
    re.compile(r"^[a-z]{2}\d{8,}$"),
    re.compile(r"^bot\d{4,}$", re.IGNORECASE),
    re.compile(r"^(viewer|user|guest|watcher|spectator)\d{5,}$", re.IGNORECASE),
]

NEW_ACCOUNT_AGE_DAYS = 7


def log(message):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] {message}", flush=True)


def load_env_file(path=".env"):
    if not os.path.exists(path):
        return

    with open(path, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip("'").strip('"')
            if key not in os.environ:
                os.environ[key] = value


def env_required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def env_bool(name, default=False):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def env_int(name, default):
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default


class TwitchApi:
    def __init__(self, config):
        self.config = config
        self.access_token = config["access_token"]

    def _headers(self, content_type="application/json"):
        headers = {
            "Authorization": f"Bearer {self.access_token}",
            "Client-Id": self.config["client_id"],
        }
        if content_type:
            headers["Content-Type"] = content_type
        return headers

    def _request(self, method, url, body=None, headers=None, auth_retry=True):
        final_headers = dict(headers or {})
        request = urllib.request.Request(url=url, method=method, headers=final_headers)
        data = None
        if body is not None:
            if isinstance(body, (dict, list)):
                data = json.dumps(body).encode("utf-8")
            elif isinstance(body, str):
                data = body.encode("utf-8")
            else:
                data = body

        try:
            with urllib.request.urlopen(request, data=data, timeout=30) as response:
                payload = response.read().decode("utf-8")
                return response.status, json.loads(payload) if payload else {}
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(payload) if payload else {}
            except json.JSONDecodeError:
                parsed = {"message": payload}

            # If the token expired mid-session, refresh once and retry the call
            # with the new bearer token. Guard against loops with auth_retry.
            if exc.code == 401 and auth_retry and self._can_refresh():
                try:
                    self._maybe_refresh_access_token()
                except Exception as refresh_exc:
                    log(f"Token refresh after 401 failed: {refresh_exc}")
                    return exc.code, parsed
                if final_headers.get("Authorization", "").startswith("Bearer "):
                    final_headers["Authorization"] = f"Bearer {self.access_token}"
                return self._request(method, url, body=body,
                                     headers=final_headers, auth_retry=False)
            return exc.code, parsed

    def _can_refresh(self):
        return bool(self.config.get("refresh_token") and self.config.get("client_secret"))

    def validate_token(self):
        # _request transparently refreshes and retries once on 401 when a
        # refresh token + client secret are configured.
        status, payload = self._request(
            "GET",
            f"{OAUTH_BASE}/validate",
            headers={"Authorization": f"Bearer {self.access_token}"},
        )
        if status != 200:
            raise RuntimeError(f"Token validation failed ({status}): {payload}")
        return payload

    def _maybe_refresh_access_token(self):
        refresh_token = self.config["refresh_token"]
        client_secret = self.config["client_secret"]
        if not refresh_token or not client_secret:
            raise RuntimeError(
                "Access token is invalid and refresh is unavailable. Add TWITCH_CLIENT_SECRET to enable token refresh."
            )

        body = urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": self.config["client_id"],
                "client_secret": client_secret,
            }
        )
        status, payload = self._request(
            "POST",
            f"{OAUTH_BASE}/token",
            body=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            auth_retry=False,
        )
        if status != 200:
            raise RuntimeError(f"Access token refresh failed ({status}): {payload}")

        self.access_token = payload["access_token"]
        self.config["access_token"] = payload["access_token"]
        if payload.get("refresh_token"):
            self.config["refresh_token"] = payload["refresh_token"]
        log("Refreshed Twitch access token in memory.")

    def get_users(self, logins):
        query = urllib.parse.urlencode([("login", login) for login in logins])
        status, payload = self._request(
            "GET",
            f"{HELIX_BASE}/users?{query}",
            headers=self._headers(content_type=None),
        )
        if status != 200:
            raise RuntimeError(f"Failed to resolve Twitch users ({status}): {payload}")
        return payload.get("data", [])

    def get_user_by_id(self, user_id):
        status, payload = self._request(
            "GET",
            f"{HELIX_BASE}/users?id={user_id}",
            headers=self._headers(content_type=None),
        )
        if status != 200:
            return None
        data = payload.get("data", [])
        return data[0] if data else None

    def create_subscription(self, session_id, subscription_type, version, condition):
        status, payload = self._request(
            "POST",
            f"{HELIX_BASE}/eventsub/subscriptions",
            body={
                "type": subscription_type,
                "version": version,
                "condition": condition,
                "transport": {
                    "method": "websocket",
                    "session_id": session_id,
                },
            },
            headers=self._headers(),
        )
        if status != 202:
            raise RuntimeError(
                f"Failed to create subscription {subscription_type} ({status}): {payload}"
            )
        return payload

    def ban_user(self, broadcaster_id, moderator_id, user_id, reason=None, duration=None):
        query = urllib.parse.urlencode(
            {
                "broadcaster_id": broadcaster_id,
                "moderator_id": moderator_id,
            }
        )
        data = {"data": {"user_id": user_id}}
        if reason:
            data["data"]["reason"] = reason[:500]
        if duration:
            data["data"]["duration"] = duration

        status, payload = self._request(
            "POST",
            f"{HELIX_BASE}/moderation/bans?{query}",
            body=data,
            headers=self._headers(),
        )
        if status != 200:
            raise RuntimeError(f"Failed to ban user ({status}): {payload}")
        return payload


class WebSocketClient:
    def __init__(self, host, path, ssl_context=None):
        self.host = host
        self.path = path
        self.ssl_context = ssl_context or ssl.create_default_context()
        self.sock = None

    def connect(self):
        raw_sock = socket.create_connection((self.host, 443), timeout=30)
        self.sock = self.ssl_context.wrap_socket(raw_sock, server_hostname=self.host)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.sock.sendall(request.encode("ascii"))
        response = self._read_http_response()
        if "101" not in response.split("\r\n", 1)[0]:
            raise RuntimeError(f"WebSocket handshake failed: {response}")

    def _read_http_response(self):
        chunks = []
        while True:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\r\n\r\n" in b"".join(chunks):
                break
        return b"".join(chunks).decode("utf-8", errors="replace")

    def close(self):
        if self.sock is None:
            return
        try:
            self.send_frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        finally:
            self.sock = None

    def send_text(self, text):
        self.send_frame(0x1, text.encode("utf-8"))

    def send_pong(self, payload):
        self.send_frame(0xA, payload)

    def send_frame(self, opcode, payload):
        if self.sock is None:
            raise RuntimeError("WebSocket is not connected")

        fin_opcode = 0x80 | (opcode & 0x0F)
        mask_bit = 0x80
        length = len(payload)
        frame = bytearray([fin_opcode])

        if length < 126:
            frame.append(mask_bit | length)
        elif length < 65536:
            frame.append(mask_bit | 126)
            frame.extend(struct.pack("!H", length))
        else:
            frame.append(mask_bit | 127)
            frame.extend(struct.pack("!Q", length))

        mask_key = secrets.token_bytes(4)
        frame.extend(mask_key)
        masked_payload = bytes(payload[i] ^ mask_key[i % 4] for i in range(length))
        frame.extend(masked_payload)
        self.sock.sendall(frame)

    def receive_frame(self):
        header = self._recv_exact(2)
        byte1, byte2 = header[0], header[1]
        opcode = byte1 & 0x0F
        masked = (byte2 & 0x80) != 0
        length = byte2 & 0x7F

        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]

        mask_key = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length) if length else b""
        if masked:
            payload = bytes(payload[i] ^ mask_key[i % 4] for i in range(length))
        return opcode, payload

    def _recv_exact(self, size):
        buffer = bytearray()
        while len(buffer) < size:
            chunk = self.sock.recv(size - len(buffer))
            if not chunk:
                raise RuntimeError("WebSocket connection closed unexpectedly")
            buffer.extend(chunk)
        return bytes(buffer)


def _is_bot_username(username):
    for pattern in BOT_USERNAME_PATTERNS:
        if pattern.search(username):
            return True
    return False


def _spam_reason(message_text):
    for pattern in SPAM_PATTERNS:
        match = pattern.search(message_text)
        if match:
            return f"spam pattern matched: {match.group(0)[:60]}"
    return None


def _account_age_days(created_at_str):
    # Twitch returns created_at in UTC (e.g. "2017-04-08T20:15:04Z").
    # calendar.timegm treats the struct_time as UTC; time.mktime would
    # (incorrectly) treat it as local time and skew the age by the host's
    # UTC offset — enough to misjudge a 7-day threshold.
    if not created_at_str:
        return None
    stamp = created_at_str.split(".", 1)[0].rstrip("Z")
    try:
        ts = time.strptime(stamp, "%Y-%m-%dT%H:%M:%S")
        created_ts = calendar.timegm(ts)
        return (time.time() - created_ts) / 86400
    except Exception:
        return None


class TwitchAutoBanBot:
    def __init__(self, config):
        self.config = config
        self.api = TwitchApi(config)
        self.moderator_id = config["moderator_user_id"]
        self.broadcaster_id = config["broadcaster_user_id"]
        self._channel = config["broadcaster_login"].lower()
        self._banned_cache = set()
        self._user_cache = {}
        self._validator_thread = None
        self._action_times = deque()

    def initialize(self):
        self._resolve_ids()
        validation = self.api.validate_token()
        self._validate_scopes(validation)
        log(f"Validated Twitch token for {validation.get('login', 'unknown')}.")
        self._start_token_validator()

    def _start_token_validator(self):
        # Twitch requires OAuth tokens be validated at least hourly. Doing it in
        # a daemon thread also refreshes the token before it expires (validate_token
        # refreshes on 401), so a bot left running overnight keeps working.
        if self._validator_thread is not None:
            return

        def _loop():
            while True:
                time.sleep(3000)  # 50 minutes
                try:
                    self.api.validate_token()
                except Exception as exc:
                    log(f"Periodic token validation failed: {exc}")

        self._validator_thread = threading.Thread(target=_loop, daemon=True)
        self._validator_thread.start()

    def _resolve_ids(self):
        if self.moderator_id and self.broadcaster_id:
            return

        users = self.api.get_users(
            [self.config["moderator_login"], self.config["broadcaster_login"]]
        )
        by_login = {user["login"].lower(): user for user in users}

        moderator = by_login.get(self.config["moderator_login"].lower())
        broadcaster = by_login.get(self.config["broadcaster_login"].lower())
        if not moderator:
            raise RuntimeError(f"Could not resolve moderator login {self.config['moderator_login']}")
        if not broadcaster:
            raise RuntimeError(f"Could not resolve broadcaster login {self.config['broadcaster_login']}")

        self.moderator_id = moderator["id"]
        self.broadcaster_id = broadcaster["id"]
        log(f"Resolved moderator user ID {self.moderator_id}.")
        log(f"Resolved broadcaster user ID {self.broadcaster_id}.")

    def _validate_scopes(self, validation):
        scopes = set(validation.get("scopes", []))
        required = {
            "moderator:manage:banned_users",
            "moderator:read:suspicious_users",
            "user:read:chat",
        }
        missing = sorted(required - scopes)
        if missing:
            log(f"WARNING: Missing optional scopes (some features disabled): {', '.join(missing)}")
        if validation.get("user_id") != self.moderator_id:
            raise RuntimeError("The provided access token does not belong to the moderator account.")

    def run_forever(self):
        # Flat reconnect loop (no recursion, so the call stack stays constant no
        # matter how many reconnects happen over a long stream).
        #
        # A fresh connection to EVENTSUB_PATH must (re)subscribe on welcome.
        # A connection opened from a session_reconnect URL keeps the existing
        # subscriptions, so we must NOT subscribe again on its welcome.
        next_host, next_path = EVENTSUB_HOST, EVENTSUB_PATH
        subscribe_on_welcome = True

        while True:
            ws = WebSocketClient(next_host, next_path)
            try:
                log(f"Connecting to Twitch EventSub at wss://{next_host}{next_path}")
                ws.connect()
                reconnect_url = self._event_loop(ws, subscribe_on_welcome)
                if reconnect_url:
                    next_host, next_path = self._parse_reconnect_url(reconnect_url)
                    subscribe_on_welcome = False
                    ws.close()
                    continue
                # Clean close without a reconnect URL -> start fresh.
                next_host, next_path = EVENTSUB_HOST, EVENTSUB_PATH
                subscribe_on_welcome = True
            except KeyboardInterrupt:
                ws.close()
                raise
            except Exception as exc:
                log(f"Connection loop error: {exc}")
                ws.close()
                next_host, next_path = EVENTSUB_HOST, EVENTSUB_PATH
                subscribe_on_welcome = True
                time.sleep(5)

    def _event_loop(self, ws, subscribe_on_welcome):
        """Pump frames until Twitch asks us to reconnect (returns the URL) or
        the connection ends (returns None)."""
        while True:
            opcode, payload = ws.receive_frame()
            if opcode == 0x1:
                message = json.loads(payload.decode("utf-8"))
                reconnect = self._handle_eventsub_message(message, subscribe_on_welcome)
                if reconnect:
                    return reconnect
            elif opcode == 0x9:
                ws.send_pong(payload)
            elif opcode == 0x8:
                raise RuntimeError("Twitch closed the EventSub connection")

    def _handle_eventsub_message(self, message, subscribe_on_welcome=True):
        message_type = message.get("metadata", {}).get("message_type")
        payload = message.get("payload", {})
        if message_type == "session_welcome":
            session_id = payload["session"]["id"]
            if subscribe_on_welcome:
                self._subscribe(session_id)
            else:
                log("Reconnected; existing subscriptions carried over.")
            return None
        if message_type == "session_keepalive":
            return None
        if message_type == "session_reconnect":
            return payload["session"]["reconnect_url"]
        if message_type == "revocation":
            log(f"EventSub subscription revoked: {payload}")
            return None
        if message_type != "notification":
            return None

        subscription = payload.get("subscription", {})
        event = payload.get("event", {})
        sub_type = subscription.get("type")
        if sub_type == "channel.suspicious_user.message":
            self._handle_suspicious_user_message(event)
        elif sub_type == "channel.chat.message":
            self._handle_chat_message(event)
        return None

    def _subscribe(self, session_id):
        any_subscribed = False

        try:
            self.api.create_subscription(
                session_id,
                "channel.suspicious_user.message",
                "1",
                {
                    "moderator_user_id": self.moderator_id,
                    "broadcaster_user_id": self.broadcaster_id,
                },
            )
            log("Subscribed to channel.suspicious_user.message.")
            any_subscribed = True
        except Exception as exc:
            log(f"WARNING: Could not subscribe to channel.suspicious_user.message: {exc}")
            log("  -> Requires scopes: moderator:read:suspicious_users, moderator:manage:banned_users")
            log("  -> Regenerate your Twitch token with those scopes and update TWITCH_ACCESS_TOKEN in your .env")

        try:
            self.api.create_subscription(
                session_id,
                "channel.chat.message",
                "1",
                {
                    "broadcaster_user_id": self.broadcaster_id,
                    "user_id": self.moderator_id,
                },
            )
            log("Subscribed to channel.chat.message (spam/bot/new-account detection active).")
            any_subscribed = True
        except Exception as exc:
            log(f"WARNING: Could not subscribe to channel.chat.message: {exc}")
            log("  -> Requires scope: user:read:chat")
            log("  -> Spam, bot-username, and new-account detection will be disabled.")

        if not any_subscribed:
            raise RuntimeError(
                "Failed to subscribe to any EventSub events. "
                "Check your token scopes and that the moderator account has mod rights on the channel."
            )

    def _handle_chat_message(self, event):
        user_id = event.get("chatter_user_id", "")
        user_login = event.get("chatter_user_login", "unknown")
        message_text = event.get("message", {}).get("text", "")
        badges = {b.get("set_id") for b in event.get("badges", [])}

        log(f"[CHAT] {user_login}: {message_text[:80]}")

        if user_id == self.broadcaster_id or user_id == self.moderator_id:
            log(f"[SKIP] {user_login} is broadcaster/moderator account.")
            return

        if user_login.lower() in self.config["allowlist_users"]:
            log(f"[SKIP] {user_login} is on the allow-list.")
            return

        # Local trust list (managed by clicking a user in the launcher).
        # effective_tier honors both this channel and the global (all-channels) list.
        tier = trust.effective_tier(BASE_DIR, self._channel, user_login)
        if tier == "trusted":
            log(f"[SKIP] {user_login} is marked Trusted.")
            return
        if tier == "blocked":
            log(f"[FLAG] {user_login} — manually Blocked")
            self._apply_action(
                user_id, user_login, ["manually blocked in launcher"],
                action=self.config["spam_action"],
                duration=self.config["spam_timeout_seconds"],
            )
            return

        # Badges that always protect an established/trusted chatter. Subscribers,
        # VIPs, and founders are regulars — never auto-action them on heuristics.
        protected = {"broadcaster", "moderator", "partner"}
        if self.config["exempt_subscribers"]:
            protected |= {"subscriber", "founder"}
        if self.config["exempt_vips"]:
            protected |= {"vip"}
        hit = badges & protected
        if hit:
            log(f"[SKIP] {user_login} has protected badge: {hit}")
            return

        if user_id in self._banned_cache:
            log(f"[SKIP] {user_login} already actioned this session.")
            return

        reasons = []
        min_signals = self.config["min_signals"]

        if self.config["ban_spam_messages"]:
            spam_reason = _spam_reason(message_text)
            if spam_reason:
                reasons.append(spam_reason)
                log(f"[FLAG] {user_login} — {spam_reason}")

        if self.config["ban_bot_usernames"] and _is_bot_username(user_login):
            reasons.append(f"bot-like username: {user_login}")
            log(f"[FLAG] {user_login} — bot-like username")

        # Only pay for the account-age lookup if it could still change the outcome
        # (i.e. we haven't already reached the signal threshold on cheaper checks).
        if self.config["ban_new_accounts"] and len(reasons) < min_signals:
            user_data = self._user_cache.get(user_id)
            if user_data is None:
                user_data = self.api.get_user_by_id(user_id)
                # Cache the result (including None) so repeat chatters during a
                # raid don't each trigger a Helix call.
                self._user_cache[user_id] = user_data or {}
            if user_data:
                created_at = user_data.get("created_at", "")
                age_days = _account_age_days(created_at)
                max_age = self.config["new_account_age_days"]
                if age_days is not None and age_days < max_age:
                    reasons.append(f"account age {age_days:.1f} days (threshold: {max_age})")
                    log(f"[FLAG] {user_login} — new account ({age_days:.1f} days old)")

        if len(reasons) < min_signals:
            if reasons:
                log(f"[HOLD] {user_login} — {len(reasons)}/{min_signals} signals, "
                    f"not actioning: {'; '.join(reasons)}")
            else:
                log(f"[OK]   {user_login} — no issues detected.")
            return

        # Heuristic detections (spam text, username shape, account age) are the
        # false-positive-prone ones, so they use spam_action (a recoverable
        # timeout by default) rather than a permaban.
        self._apply_action(
            user_id, user_login, reasons,
            action=self.config["spam_action"],
            duration=self.config["spam_timeout_seconds"],
        )
        return

    def _handle_suspicious_user_message(self, event):
        user_login = event.get("user_login", "unknown_user")
        user_id = event.get("user_id", "")
        low_trust_status = event.get("low_trust_status", "none")
        ban_evasion = event.get("ban_evasion_evaluation", "unknown")
        user_types = [value.lower() for value in event.get("types", [])]

        if user_id in self._banned_cache:
            return

        if user_login.lower() in self.config["allowlist_users"]:
            log(f"[SKIP] {user_login} is on the allow-list (suspicious-user event).")
            return
        if trust.effective_tier(BASE_DIR, self._channel, user_login) == "trusted":
            log(f"[SKIP] {user_login} is marked Trusted (suspicious-user event).")
            return

        reasons = []
        if self.config["ban_likely_ban_evaders"]:
            if ban_evasion == "likely":
                reasons.append("Twitch ban_evasion_evaluation=likely")
            if "ban_evader" in user_types:
                reasons.append("Twitch suspicious user type includes ban_evader")
        if self.config["ban_restricted_suspicious_users"] and low_trust_status == "restricted":
            reasons.append("Twitch low_trust_status=restricted")

        if not reasons:
            log(
                f"Ignored suspicious user message from {user_login} "
                f"(low_trust_status={low_trust_status}, ban_evasion_evaluation={ban_evasion})."
            )
            return

        self._apply_action(user_id, user_login, reasons)

    def _rate_limit(self):
        """Block briefly so we never exceed action_rate_limit actions/second.
        Prevents hammering Twitch's moderation endpoint during a large raid."""
        limit = self.config["action_rate_limit"]
        if limit <= 0:
            return
        q = self._action_times
        now = time.monotonic()
        while q and now - q[0] >= 1.0:
            q.popleft()
        if len(q) >= limit:
            sleep_for = 1.0 - (now - q[0])
            if sleep_for > 0:
                time.sleep(sleep_for)
            now = time.monotonic()
            while q and now - q[0] >= 1.0:
                q.popleft()
        q.append(time.monotonic())

    def _apply_action(self, user_id, user_login, reasons, action=None, duration=None):
        action = (action or self.config["action_mode"]).lower()
        if action == "timeout" and not duration:
            duration = self.config["timeout_seconds"]
        # A ban is permanent, so any duration must be cleared for it.
        if action == "ban":
            duration = None

        moderation_reason = self.config["moderation_reason"] or "; ".join(reasons)
        label = f"{action}" + (f" ({duration}s)" if action == "timeout" and duration else "")

        if self.config["dry_run"]:
            log(f"[DRY RUN] Would {label} {user_login}. Reasons: {'; '.join(reasons)}")
            return

        self._rate_limit()
        try:
            self.api.ban_user(
                broadcaster_id=self.broadcaster_id,
                moderator_id=self.moderator_id,
                user_id=user_id,
                reason=moderation_reason,
                duration=duration,
            )
            self._banned_cache.add(user_id)
            log(f"Applied {label} to {user_login}. Reasons: {'; '.join(reasons)}")
        except Exception as exc:
            log(f"Failed to {label} {user_login}: {exc}")

    @staticmethod
    def _parse_reconnect_url(url):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "wss":
            raise RuntimeError(f"Unexpected reconnect URL: {url}")
        path = parsed.path
        if parsed.query:
            path = f"{path}?{parsed.query}"
        return parsed.hostname, path


def load_config():
    access_token = env_required("TWITCH_ACCESS_TOKEN")
    if access_token.lower().startswith("oauth:"):
        access_token = access_token[6:]
    return {
        "client_id": env_required("TWITCH_CLIENT_ID"),
        "access_token": access_token,
        "refresh_token": os.environ.get("TWITCH_REFRESH_TOKEN", "").strip(),
        "client_secret": os.environ.get("TWITCH_CLIENT_SECRET", "").strip(),
        "moderator_login": env_required("MODERATOR_LOGIN"),
        "broadcaster_login": env_required("BROADCASTER_LOGIN"),
        "moderator_user_id": os.environ.get("MODERATOR_USER_ID", "").strip(),
        "broadcaster_user_id": os.environ.get("BROADCASTER_USER_ID", "").strip(),
        "dry_run": env_bool("DRY_RUN", False),
        "action_mode": os.environ.get("ACTION_MODE", "ban").strip().lower(),
        "timeout_seconds": env_int("TIMEOUT_SECONDS", 600),
        # Heuristic matches (spam/username/age) are false-positive-prone, so they
        # default to a recoverable timeout rather than a permaban.
        "spam_action": os.environ.get("SPAM_ACTION", "timeout").strip().lower(),
        "spam_timeout_seconds": env_int("SPAM_TIMEOUT_SECONDS", 600),
        # Require this many independent heuristic signals before actioning a
        # stranger. 1 = current behavior; 2 makes false positives much rarer.
        "min_signals": env_int("MIN_SIGNALS", 1),
        # Cap moderation actions per second so a big raid can't blow past
        # Twitch's rate limits (0 disables the cap).
        "action_rate_limit": env_int("ACTION_RATE_LIMIT", 10),
        # Logins that are never auto-actioned, regardless of what they say.
        "allowlist_users": {
            u.strip().lower().lstrip("@")
            for u in os.environ.get("ALLOWLIST_USERS", "").split(",")
            if u.strip()
        },
        # Established chatters are exempt from heuristic actions.
        "exempt_subscribers": env_bool("EXEMPT_SUBSCRIBERS", True),
        "exempt_vips": env_bool("EXEMPT_VIPS", True),
        "moderation_reason": os.environ.get("MODERATION_REASON", "").strip(),
        "ban_restricted_suspicious_users": env_bool("BAN_RESTRICTED_SUSPICIOUS_USERS", False),
        "ban_likely_ban_evaders": env_bool("BAN_LIKELY_BAN_EVADERS", True),
        "ban_spam_messages": env_bool("BAN_SPAM_MESSAGES", True),
        "ban_bot_usernames": env_bool("BAN_BOT_USERNAMES", False),
        "ban_new_accounts": env_bool("BAN_NEW_ACCOUNTS", False),
        "new_account_age_days": env_int("NEW_ACCOUNT_AGE_DAYS", NEW_ACCOUNT_AGE_DAYS),
    }


def _select_config():
    """Resolve which profile/config to load from the command line.

    Usage:
      python bot.py                 -> menu of profiles from bots.ini (or legacy .env)
      python bot.py <ProfileName>   -> that profile from bots.ini
      python bot.py path/to/x.env   -> legacy single flat .env file
    """
    base_dir = os.path.dirname(os.path.abspath(__file__))
    arg = sys.argv[1] if len(sys.argv) > 1 else ""

    # Legacy: an explicit .env path still works.
    if arg.endswith(".env") and os.path.isfile(arg):
        load_env_file(arg)
        return

    if arg:
        botconfig.load_profile_into_env(base_dir, arg)
        return

    profiles = botconfig.list_profiles(base_dir)
    if not profiles:
        raise RuntimeError(
            "No profiles found. Create bots.ini (see example) or pass an .env path."
        )
    if len(profiles) == 1:
        botconfig.load_profile_into_env(base_dir, profiles[0])
        return

    print("Select a channel:")
    for i, name in enumerate(profiles, 1):
        print(f"  {i}. {name}")
    choice = input("Enter number: ").strip()
    try:
        name = profiles[int(choice) - 1]
    except (ValueError, IndexError):
        raise RuntimeError("Invalid selection.")
    botconfig.load_profile_into_env(base_dir, name)


def main():
    _select_config()
    config = load_config()
    if config["action_mode"] not in {"ban", "timeout"}:
        raise RuntimeError("ACTION_MODE must be ban or timeout")
    if config["spam_action"] not in {"ban", "timeout"}:
        raise RuntimeError("SPAM_ACTION must be ban or timeout")
    if config["min_signals"] < 1:
        raise RuntimeError("MIN_SIGNALS must be >= 1")

    log("=" * 60)
    log(f"  Twitch AutoBan Bot starting up")
    log(f"  DRY_RUN          : {config['dry_run']}  {'<-- BANS ARE LOGGED ONLY, NOT APPLIED' if config['dry_run'] else '<-- LIVE MODE: bans will be applied'}")
    log(f"  ACTION_MODE      : {config['action_mode']}  (Twitch hard flags, e.g. ban-evaders)")
    log(f"  SPAM_ACTION      : {config['spam_action']}  (heuristic spam/username/age matches)")
    log(f"  ban_spam_messages: {config['ban_spam_messages']}")
    log(f"  ban_bot_usernames: {config['ban_bot_usernames']}")
    log(f"  ban_new_accounts : {config['ban_new_accounts']} (age threshold: {config['new_account_age_days']} days)")
    log(f"  ban_evaders      : {config['ban_likely_ban_evaders']}")
    log(f"  exempt subs/vips : subs={config['exempt_subscribers']} vips={config['exempt_vips']}")
    log(f"  min_signals      : {config['min_signals']}  (independent flags needed to action)")
    log(f"  action_rate_limit: {config['action_rate_limit']}/sec")
    log(f"  allow-list       : {', '.join(sorted(config['allowlist_users'])) or '(none)'}")
    log(f"  moderator        : {config['moderator_login']}")
    log(f"  broadcaster      : {config['broadcaster_login']}")
    log("=" * 60)

    if config["refresh_token"] and not config["client_secret"]:
        log("Refresh token is present, but TWITCH_CLIENT_SECRET is empty, so automatic refresh is disabled.")

    bot = TwitchAutoBanBot(config)
    bot.initialize()
    bot.run_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Stopped by user.")
    except Exception as exc:
        log(f"FATAL ERROR: {exc}")
        import traceback
        traceback.print_exc()
        print("\nPress Enter to close...")
        input()
