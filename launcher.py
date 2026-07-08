import base64
import json
import os
import queue
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import zlib
import tkinter as tk
import urllib.error
import urllib.parse
import urllib.request
from tkinter import messagebox, ttk

import botconfig
import trust

try:
    from spellchecker import SpellChecker as _SC
    _spell = _SC()
    SPELL_OK = True
except ImportError:
    SPELL_OK = False


FALLBACK_PYTHON = r"C:\Users\lahne\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
POLL_INTERVAL_MS = 2000
CHAT_POLL_MS = 80
MAX_CHAT_LINES = 500
EMOTE_CDN_STATIC   = "https://static-cdn.jtvnw.net/emoticons/v2/{emote_id}/default/dark/1.0"
EMOTE_CDN_ANIMATED = "https://static-cdn.jtvnw.net/emoticons/v2/{emote_id}/animated/dark/1.0"

CHAT_COLORS = [
    "#f38ba8", "#fab387", "#f9e2af", "#a6e3a1",
    "#94e2d5", "#89dceb", "#89b4fa", "#cba6f7",
]

# Windows: 0x08000000 = CREATE_NO_WINDOW. Keeps bot subprocesses from flashing
# a console window each time one starts.
_CREATE_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0



# ── helpers ───────────────────────────────────────────────────────────────────

def find_python():
    for cmd in ["py -3", "python"]:
        parts = cmd.split()
        try:
            result = subprocess.run(parts + ["--version"],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    creationflags=_CREATE_NO_WINDOW)
            if result.returncode == 0:
                return parts
        except FileNotFoundError:
            continue
    if os.path.isfile(FALLBACK_PYTHON):
        return [FALLBACK_PYTHON]
    return None


def scan_profiles(base_dir):
    return botconfig.list_profiles(base_dir)


def scan_env_configs(base_dir):
    result = []
    for name in botconfig.list_profiles(base_dir):
        try:
            result.append((name, botconfig.profile_env(base_dir, name)))
        except Exception:
            pass
    return result


def username_color(name: str) -> str:
    # zlib.crc32 is deterministic; Python's built-in hash() is salted per
    # process (PYTHONHASHSEED), which would reshuffle every user's color on
    # each launch.
    return CHAT_COLORS[zlib.crc32(name.lower().encode("utf-8")) % len(CHAT_COLORS)]


def parse_irc_tags(tag_str: str) -> dict:
    tags = {}
    for part in tag_str.split(";"):
        if "=" in part:
            k, _, v = part.partition("=")
            tags[k] = v
    return tags


def parse_emotes(emote_tag: str) -> list:
    if not emote_tag:
        return []
    positions = []
    for entry in emote_tag.split("/"):
        if ":" not in entry:
            continue
        emote_id, ranges = entry.split(":", 1)
        for r in ranges.split(","):
            if "-" in r:
                try:
                    s, e = r.split("-")
                    positions.append((int(s), int(e), emote_id))
                except ValueError:
                    pass
    positions.sort(key=lambda x: x[0])
    return positions


def parse_gif_delays(gif_bytes: bytes) -> list:
    """Extract per-frame delay times (ms) from raw GIF bytes."""
    delays = []
    if len(gif_bytes) < 13 or gif_bytes[:3] != b"GIF":
        return [100]
    packed = gif_bytes[10]
    has_gct = (packed >> 7) & 1
    gct_size = packed & 0x7
    i = 13 + has_gct * 3 * (2 ** (gct_size + 1))
    while i < len(gif_bytes) - 1:
        s = gif_bytes[i]
        if s == 0x3B:
            break
        elif s == 0x21:
            ext = gif_bytes[i + 1]; i += 2
            if ext == 0xF9 and i < len(gif_bytes):
                bs = gif_bytes[i]
                if bs >= 4 and i + 4 < len(gif_bytes):
                    dc = gif_bytes[i + 2] + (gif_bytes[i + 3] << 8)
                    delays.append(max(dc * 10, 40))
            while i < len(gif_bytes):
                bs = gif_bytes[i]; i += 1
                if bs == 0:
                    break
                i += bs
        elif s == 0x2C:
            i += 1
            if i + 9 > len(gif_bytes):
                break
            pk = gif_bytes[i + 8]
            has_lct = (pk >> 7) & 1
            lct_size = pk & 0x7
            i += 9 + has_lct * 3 * (2 ** (lct_size + 1))
            if i < len(gif_bytes):
                i += 1
            while i < len(gif_bytes):
                bs = gif_bytes[i]; i += 1
                if bs == 0:
                    break
                i += bs
        else:
            break
    return delays or [100]


# ── emote cache ───────────────────────────────────────────────────────────────

class EmoteCache:
    """
    Downloads static PNG (for inline chat) and animated GIF (for picker).
    All PhotoImage creation happens on the main thread.
    """

    def __init__(self):
        self._static_raw:  dict[str, bytes] = {}
        self._anim_raw:    dict[str, bytes] = {}
        self._photos:      dict[str, tk.PhotoImage] = {}         # static PNG photos
        self._frames:      dict[str, list] = {}                  # (PhotoImage, delay_ms)
        self._lock = threading.Lock()

    # ── prefetch ──────────────────────────────────────────────────────────────

    def prefetch(self, emote_id: str):
        """Download static PNG for inline chat display."""
        with self._lock:
            if emote_id in self._static_raw:
                return
            self._static_raw[emote_id] = b""
        threading.Thread(target=self._dl_static, args=(emote_id,), daemon=True).start()

    def prefetch_animated(self, emote_id: str):
        """Download both static PNG and animated GIF (for picker)."""
        self.prefetch(emote_id)
        with self._lock:
            if emote_id in self._anim_raw:
                return
            self._anim_raw[emote_id] = b""
        threading.Thread(target=self._dl_anim, args=(emote_id,), daemon=True).start()

    def _dl_static(self, emote_id: str):
        url = EMOTE_CDN_STATIC.format(emote_id=emote_id)
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                data = r.read()
            with self._lock:
                self._static_raw[emote_id] = data
        except Exception:
            pass

    def _dl_anim(self, emote_id: str):
        url = EMOTE_CDN_ANIMATED.format(emote_id=emote_id)
        try:
            with urllib.request.urlopen(url, timeout=8) as r:
                data = r.read()
            with self._lock:
                self._anim_raw[emote_id] = data
        except Exception:
            pass

    # ── getters (main thread only) ────────────────────────────────────────────

    def get_display(self, emote_id: str) -> tk.PhotoImage | None:
        """Static PNG PhotoImage for inline chat."""
        if emote_id in self._photos:
            return self._photos[emote_id]
        with self._lock:
            data = self._static_raw.get(emote_id, b"")
        if not data:
            return None
        try:
            photo = tk.PhotoImage(data=base64.b64encode(data).decode("ascii"))
            self._photos[emote_id] = photo
            return photo
        except Exception:
            return None

    def has_anim_data(self, emote_id: str) -> bool:
        with self._lock:
            return bool(self._anim_raw.get(emote_id, b""))

    def get_frames(self, emote_id: str) -> list | None:
        """
        Load GIF frames as separate PhotoImage objects (main thread only).
        Returns [(PhotoImage, delay_ms), ...] or None.
        Cycling between separate PhotoImage objects on a tk.Button avoids
        all palette-corruption issues that plague configure(data=...).
        """
        if emote_id in self._frames:
            return self._frames[emote_id]
        with self._lock:
            data = self._anim_raw.get(emote_id, b"")
        if not data or data[:3] != b"GIF":
            return None
        fd, path = tempfile.mkstemp(suffix=".gif")
        try:
            os.write(fd, data)
            os.close(fd)
            delays = parse_gif_delays(data)
            frames = []
            idx = 0
            while True:
                try:
                    img = tk.PhotoImage(file=path, format=f"gif -index {idx}")
                    delay = delays[idx] if idx < len(delays) else 100
                    frames.append((img, delay))
                    idx += 1
                except tk.TclError:
                    break
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        if frames:
            self._frames[emote_id] = frames
            return frames
        return None


_emote_cache = EmoteCache()


# ── process manager ─────────────────────────────────────────────────────────

class ProcessManager:
    def __init__(self):
        self._procs: dict[str, subprocess.Popen] = {}
        self._logs: dict[str, object] = {}

    def log_path(self, base_dir: str, name: str) -> str:
        return os.path.join(base_dir, "logs", f"{name}.log")

    def start(self, name: str, python_cmd: list, base_dir: str):
        bot_path = os.path.join(base_dir, "bot.py")

        # Send the bot's stdout/stderr to a per-profile log file so ban reasons
        # are actually visible afterwards (previously they went to DEVNULL, which
        # is why a mystery ban was impossible to diagnose).
        logs_dir = os.path.join(base_dir, "logs")
        os.makedirs(logs_dir, exist_ok=True)
        log_file = self.log_path(base_dir, name)
        try:
            if os.path.exists(log_file) and os.path.getsize(log_file) > 2_000_000:
                os.replace(log_file, log_file + ".1")  # keep one previous log
        except OSError:
            pass
        logf = open(log_file, "a", buffering=1, encoding="utf-8")

        # Pass the profile name; bot.py resolves it from bots.ini (or legacy .env).
        proc = subprocess.Popen(
            python_cmd + [bot_path, name],
            stdout=logf, stderr=subprocess.STDOUT, cwd=base_dir,
            creationflags=_CREATE_NO_WINDOW,
        )
        self._procs[name] = proc
        self._logs[name] = logf

    def _close_log(self, name: str):
        logf = self._logs.pop(name, None)
        if logf is not None:
            try:
                logf.close()
            except Exception:
                pass

    def stop(self, name: str):
        proc = self._procs.get(name)
        if proc is None:
            self._close_log(name)
            return
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        del self._procs[name]
        self._close_log(name)

    def is_running(self, name: str) -> bool:
        proc = self._procs.get(name)
        if proc is None:
            return False
        if proc.poll() is not None:
            del self._procs[name]
            self._close_log(name)
            return False
        return True

    def stop_all(self):
        for name in list(self._procs.keys()):
            self.stop(name)


# ── IRC ─────────────────────────────────────────────────────────────────────

class IRCConnection:
    IRC_HOST = "irc.chat.twitch.tv"
    IRC_PORT = 6697  # TLS. Plaintext 6667 would send the OAuth token in the clear.

    def __init__(self, token, nick, channel, on_message, on_status):
        # Token generators often include an "oauth:" prefix; the PASS line adds
        # its own, so strip it here to avoid "oauth:oauth:..." auth failures.
        self._token = token.strip()
        if self._token.lower().startswith("oauth:"):
            self._token = self._token[6:]
        self._nick = nick.lower()
        self._channel = channel.lower()
        self._on_message = on_message
        self._on_status = on_status
        self._stop = threading.Event()
        self._sock = None
        self._thread = None
        self._auth_failed = False

    def start(self):
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass

    def _send(self, text: str):
        try:
            self._sock.sendall((text + "\r\n").encode("utf-8"))
        except Exception:
            pass

    def send_privmsg(self, message: str, reply_parent_msg_id: str = None):
        if reply_parent_msg_id:
            self._send(f"@reply-parent-msg-id={reply_parent_msg_id} "
                       f"PRIVMSG #{self._channel} :{message}")
        else:
            self._send(f"PRIVMSG #{self._channel} :{message}")

    def _run(self):
        attempt = 0
        while not self._stop.is_set():
            clean_close = self._connect_and_listen()
            if self._stop.is_set() or self._auth_failed:
                break
            attempt = 1 if clean_close else attempt + 1
            delay = min(30, 5 * attempt)
            self._on_status(f"Chat disconnected — reconnecting in {delay}s…")
            if self._stop.wait(delay):   # returns True if stopped during the wait
                break
        self._on_status("Disconnected")

    def _connect_and_listen(self) -> bool:
        """Connect, then pump lines until the socket drops or we're stopped.
        Returns True on a clean/stop close, False on an error drop (so the
        caller can back off before retrying)."""
        self._on_status("Connecting…")
        try:
            raw = socket.create_connection((self.IRC_HOST, self.IRC_PORT), timeout=10)
            ctx = ssl.create_default_context()
            self._sock = ctx.wrap_socket(raw, server_hostname=self.IRC_HOST)
            self._sock.settimeout(1.0)
            self._send("CAP REQ :twitch.tv/tags twitch.tv/commands")
            self._send(f"PASS oauth:{self._token}")
            self._send(f"NICK {self._nick}")
            self._send(f"JOIN #{self._channel}")
            self._on_status(f"Connected  •  #{self._channel}")
        except Exception as exc:
            self._on_status(f"Connection failed: {exc}")
            return False

        buf = ""
        while not self._stop.is_set():
            try:
                data = self._sock.recv(4096)
                if not data:
                    return False   # server closed the connection
                buf += data.decode("utf-8", errors="replace")
                while "\r\n" in buf:
                    line, buf = buf.split("\r\n", 1)
                    self._handle_line(line)
            except socket.timeout:
                continue
            except ssl.SSLWantReadError:
                continue
            except OSError:
                return False       # network error -> reconnect
        return True                # stopped cleanly

    def _handle_line(self, line: str):
        if line.startswith("PING"):
            self._send("PONG :tmi.twitch.tv")
            return

        tags = {}
        rest = line
        if line.startswith("@"):
            tag_str, _, rest = line[1:].partition(" ")
            tags = parse_irc_tags(tag_str)

        # Twitch reports a bad/expired token via NOTICE, then closes the socket.
        # Detect it so we can tell the user instead of reconnect-looping forever.
        if " NOTICE " in rest and "authentication failed" in line.lower():
            self._auth_failed = True
            self._on_status("Chat login failed — token invalid or missing "
                            "chat:read / chat:edit scopes.")
            return

        m = re.match(r":(\w+)!\w+@\w+\.tmi\.twitch\.tv PRIVMSG #\w+ :(.+)", rest)
        if m:
            self._on_message(m.group(1), m.group(2),
                             tags.get("emotes", ""), tags.get("id", ""))


# ── Twitch API ───────────────────────────────────────────────────────────────

class TwitchAPI:
    BASE = "https://api.twitch.tv/helix"

    def __init__(self, client_id: str, access_token: str):
        self._client_id = client_id
        token = (access_token or "").strip()
        if token.lower().startswith("oauth:"):
            token = token[6:]
        self._access_token = token
        self._id_cache: dict[str, str] = {}

    def _headers(self):
        return {
            "Client-Id": self._client_id,
            "Authorization": f"Bearer {self._access_token}",
            "Content-Type": "application/json",
        }

    def get_user_id(self, login: str) -> str:
        login = login.lower()
        if login in self._id_cache:
            return self._id_cache[login]
        url = f"{self.BASE}/users?login={urllib.parse.quote(login)}"
        req = urllib.request.Request(url, headers=self._headers())
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        if not data.get("data"):
            raise ValueError(f"User '{login}' not found.")
        uid = data["data"][0]["id"]
        self._id_cache[login] = uid
        return uid

    def ban_user(self, broadcaster_login, moderator_login, target_login, reason=""):
        bid = self.get_user_id(broadcaster_login)
        mid = self.get_user_id(moderator_login)
        tid = self.get_user_id(target_login)
        url = f"{self.BASE}/moderation/bans?broadcaster_id={bid}&moderator_id={mid}"
        body = json.dumps({"data": {"user_id": tid, "reason": reason}}).encode()
        req = urllib.request.Request(url, data=body, headers=self._headers(), method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status

    def timeout_user(self, broadcaster_login, moderator_login,
                     target_login, duration=600, reason=""):
        bid = self.get_user_id(broadcaster_login)
        mid = self.get_user_id(moderator_login)
        tid = self.get_user_id(target_login)
        url = f"{self.BASE}/moderation/bans?broadcaster_id={bid}&moderator_id={mid}"
        body = json.dumps(
            {"data": {"user_id": tid, "duration": duration, "reason": reason}}
        ).encode()
        req = urllib.request.Request(url, data=body, headers=self._headers(), method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status

    def add_vip(self, broadcaster_login, target_login):
        # Requires the BROADCASTER's token with channel:manage:vips.
        bid = self.get_user_id(broadcaster_login)
        tid = self.get_user_id(target_login)
        url = f"{self.BASE}/channels/vips?broadcaster_id={bid}&user_id={tid}"
        req = urllib.request.Request(url, headers=self._headers(), method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status

    def remove_vip(self, broadcaster_login, target_login):
        bid = self.get_user_id(broadcaster_login)
        tid = self.get_user_id(target_login)
        url = f"{self.BASE}/channels/vips?broadcaster_id={bid}&user_id={tid}"
        req = urllib.request.Request(url, headers=self._headers(), method="DELETE")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status

    def get_global_emotes(self) -> list:
        req = urllib.request.Request(f"{self.BASE}/chat/emotes/global",
                                     headers=self._headers())
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("data", [])

    def get_channel_emotes(self, broadcaster_id: str) -> list:
        req = urllib.request.Request(
            f"{self.BASE}/chat/emotes?broadcaster_id={broadcaster_id}",
            headers=self._headers())
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("data", [])


# ── emote picker ─────────────────────────────────────────────────────────────

class EmotePickerWindow:
    def __init__(self, parent, api: TwitchAPI, broadcaster_id: str, on_select):
        self._api = api
        self._broadcaster_id = broadcaster_id
        self._on_select = on_select
        self._all_emotes: list[dict] = []
        self._photo_refs: list[tk.PhotoImage] = []
        self._pending_anim: list[tuple] = []   # (emote_id, button)

        self._win = tk.Toplevel(parent)
        self._win.title("Emote Picker")
        self._win.configure(bg="#1e1e2e")
        self._win.geometry("480x400")
        self._win.resizable(True, True)
        self._build()
        self._win.after(50, self._load_emotes)

    def _build(self):
        top = tk.Frame(self._win, bg="#181825", pady=6)
        top.pack(fill="x")
        tk.Label(top, text="Search:", bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(side="left", padx=(10, 4))
        self._search_var = tk.StringVar()
        self._search_var.trace_add("write", lambda *_: self._filter())
        tk.Entry(top, textvariable=self._search_var,
                 bg="#313244", fg="#cdd6f4", insertbackground="#cdd6f4",
                 relief="flat", font=("Segoe UI", 10),
                 ).pack(side="left", fill="x", expand=True, ipady=4, padx=(0, 10))

        self._status_var = tk.StringVar(value="Loading emotes…")
        tk.Label(self._win, textvariable=self._status_var,
                 bg="#1e1e2e", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(anchor="w", padx=10)

        container = tk.Frame(self._win, bg="#1e1e2e")
        container.pack(fill="both", expand=True, padx=6, pady=(0, 6))
        sb = tk.Scrollbar(container, bg="#313244", troughcolor="#1e1e2e",
                          relief="flat", width=10)
        sb.pack(side="right", fill="y")
        self._canvas = tk.Canvas(container, bg="#11111b", relief="flat",
                                 yscrollcommand=sb.set, highlightthickness=0)
        self._canvas.pack(side="left", fill="both", expand=True)
        sb.config(command=self._canvas.yview)
        self._grid_frame = tk.Frame(self._canvas, bg="#11111b")
        self._cw = self._canvas.create_window((0, 0), window=self._grid_frame, anchor="nw")
        self._grid_frame.bind("<Configure>",
                              lambda _: self._canvas.configure(
                                  scrollregion=self._canvas.bbox("all")))
        self._canvas.bind("<Configure>",
                          lambda e: self._canvas.itemconfig(self._cw, width=e.width))
        self._canvas.bind("<MouseWheel>",
                          lambda e: self._canvas.yview_scroll(
                              int(-1 * (e.delta / 120)), "units"))

    def _load_emotes(self):
        threading.Thread(target=self._fetch, daemon=True).start()

    def _fetch(self):
        emotes = []
        try:
            emotes += self._api.get_global_emotes()
        except Exception:
            pass
        try:
            emotes += self._api.get_channel_emotes(self._broadcaster_id)
        except Exception:
            pass
        for em in emotes:
            if em.get("id"):
                _emote_cache.prefetch_animated(em["id"])
        self._all_emotes = emotes
        self._win.after(0, lambda: self._status_var.set(
            f"{len(emotes)} emotes — downloading images…"))
        self._win.after(1500, self._filter)

    def _filter(self):
        q = self._search_var.get().lower()
        shown = [e for e in self._all_emotes if q in e.get("name", "").lower()]
        self._render(shown)

    def _render(self, emotes):
        self._pending_anim.clear()
        for w in self._grid_frame.winfo_children():
            w.destroy()
        self._photo_refs.clear()
        cols = 8
        for i, em in enumerate(emotes):
            row, col = divmod(i, cols)
            eid, name = em.get("id", ""), em.get("name", "")
            photo = _emote_cache.get_display(eid) if eid else None
            if photo:
                self._photo_refs.append(photo)
                btn = tk.Button(self._grid_frame, image=photo,
                                bg="#11111b", activebackground="#313244",
                                relief="flat", cursor="hand2", bd=0,
                                command=lambda n=name: self._pick(n))
                btn.grid(row=row, column=col, padx=3, pady=3)
                self._tooltip(btn, name)
                if eid:
                    self._pending_anim.append((eid, btn))
            else:
                btn = tk.Button(self._grid_frame, text=name,
                                bg="#11111b", fg="#cdd6f4",
                                activebackground="#313244",
                                font=("Consolas", 8), relief="flat",
                                cursor="hand2", padx=4, pady=2,
                                command=lambda n=name: self._pick(n))
                btn.grid(row=row, column=col, padx=2, pady=2)
        self._status_var.set(f"Showing {len(emotes)} emotes")
        self._process_next_anim()

    def _process_next_anim(self):
        """Upgrade buttons to animated GIFs in batches as data arrives."""
        if not self._pending_anim:
            return
        still_waiting = []
        processed = 0
        for eid, btn in self._pending_anim:
            try:
                alive = btn.winfo_exists()
            except Exception:
                continue
            if not alive:
                continue
            if _emote_cache.has_anim_data(eid) and processed < 8:
                frames = _emote_cache.get_frames(eid)
                processed += 1
                if frames and len(frames) > 1:
                    self._start_anim(btn, frames)
            else:
                still_waiting.append((eid, btn))
        self._pending_anim = still_waiting
        if still_waiting:
            try:
                self._win.after(150, self._process_next_anim)
            except Exception:
                pass

    def _start_anim(self, btn: tk.Button, frames: list):
        """Cycle through GIF frames on a Button by swapping PhotoImage references."""
        def step(i: int = 0):
            try:
                if not btn.winfo_exists():
                    return
            except Exception:
                return
            photo, delay = frames[i]
            btn.configure(image=photo)
            btn.after(delay, step, (i + 1) % len(frames))
        step()

    def _tooltip(self, widget, text):
        tip = None
        def enter(_):
            nonlocal tip
            tip = tk.Toplevel(widget)
            tip.wm_overrideredirect(True)
            tip.wm_geometry(f"+{widget.winfo_rootx()+20}+{widget.winfo_rooty()+20}")
            tk.Label(tip, text=text, bg="#313244", fg="#cdd6f4",
                     font=("Segoe UI", 8), relief="flat", padx=4, pady=2).pack()
        def leave(_):
            nonlocal tip
            if tip:
                tip.destroy(); tip = None
        widget.bind("<Enter>", enter)
        widget.bind("<Leave>", leave)

    def _pick(self, name):
        self._on_select(name)


# ── profile row ──────────────────────────────────────────────────────────────

class ProfileRow:
    """Bubble-style toggle card — click to start, click again to stop."""

    _BG_OFF     = "#313244"
    _BG_OFF_HOV = "#3d4060"
    _BG_ON      = "#1e3a28"
    _BG_ON_HOV  = "#264d34"

    def __init__(self, parent, name: str, on_toggle):
        self.name = name
        self._running = False
        self._on_toggle = on_toggle

        self._frame = tk.Frame(parent, bg=self._BG_OFF, cursor="hand2", relief="flat")
        self._frame.pack(fill="x", padx=8, pady=5)

        self._dot = tk.Label(self._frame, text="●", bg=self._BG_OFF, fg="#585b70",
                             font=("Segoe UI", 13))
        self._dot.pack(side="left", padx=(14, 8), pady=11)

        self._name_lbl = tk.Label(self._frame, text=name, bg=self._BG_OFF,
                                  fg="#cdd6f4", font=("Segoe UI", 10, "bold"),
                                  anchor="w")
        self._name_lbl.pack(side="left", fill="x", expand=True, pady=11)

        self._status_lbl = tk.Label(self._frame, text="○  Stopped",
                                    bg=self._BG_OFF, fg="#585b70",
                                    font=("Segoe UI", 9), padx=16)
        self._status_lbl.pack(side="right", pady=11)

        for w in (self._frame, self._dot, self._name_lbl, self._status_lbl):
            w.bind("<Button-1>", lambda _: self._on_toggle(self.name, not self._running))
            w.bind("<Enter>", self._on_enter)
            w.bind("<Leave>", self._on_leave)

    def _on_enter(self, _=None):
        bg = self._BG_ON_HOV if self._running else self._BG_OFF_HOV
        for w in (self._frame, self._dot, self._name_lbl, self._status_lbl):
            w.configure(bg=bg)

    def _on_leave(self, _=None):
        self._apply_style()

    def _apply_style(self):
        if self._running:
            bg         = self._BG_ON
            dot_fg     = "#a6e3a1"
            name_fg    = "#a6e3a1"
            status_txt = "●  Running"
            status_fg  = "#a6e3a1"
        else:
            bg         = self._BG_OFF
            dot_fg     = "#585b70"
            name_fg    = "#cdd6f4"
            status_txt = "○  Stopped"
            status_fg  = "#585b70"
        self._frame.configure(bg=bg)
        self._dot.configure(bg=bg, fg=dot_fg)
        self._name_lbl.configure(bg=bg, fg=name_fg)
        self._status_lbl.configure(bg=bg, text=status_txt, fg=status_fg)

    def set_running(self, running: bool):
        self._running = running
        self._apply_style()

    def is_running(self) -> bool:
        return self._running

    def destroy(self):
        self._frame.destroy()


# ── spell-checked message input ──────────────────────────────────────────────

class _MentionPopup:
    """
    Floating listbox that appears when the user types @ in the message input.
    Positions itself just above the entry widget.
    """

    MAX_ROWS = 8

    def __init__(self, entry: "SpellEntry"):
        self._entry = entry
        self._win: tk.Toplevel | None = None
        self._lb: tk.Listbox | None = None
        self._names: list[str] = []

    def show(self, names: list[str]):
        if not names:
            self.hide()
            return
        self._names = names
        if self._win is None or not self._win.winfo_exists():
            self._win = tk.Toplevel(self._entry)
            self._win.wm_overrideredirect(True)
            self._win.configure(bg="#313244")
            self._lb = tk.Listbox(
                self._win,
                bg="#313244", fg="#cdd6f4",
                selectbackground="#89b4fa", selectforeground="#1e1e2e",
                font=("Segoe UI", 10), relief="flat",
                activestyle="none", highlightthickness=0,
                borderwidth=0,
            )
            self._lb.pack(fill="both", expand=True)
            self._lb.bind("<ButtonRelease-1>", lambda _: self._pick())
            self._lb.bind("<Return>", lambda _: self._pick())
        self._lb.delete(0, "end")
        for n in names[:self.MAX_ROWS]:
            self._lb.insert("end", n)
        self._lb.selection_set(0)
        rows = min(len(names), self.MAX_ROWS)
        h = rows * 22 + 4
        x = self._entry.winfo_rootx()
        y = self._entry.winfo_rooty() - h - 2
        w = max(self._entry.winfo_width(), 180)
        self._win.geometry(f"{w}x{h}+{x}+{y}")
        self._win.lift()

    def hide(self):
        if self._win and self._win.winfo_exists():
            self._win.destroy()
        self._win = None
        self._lb = None

    def is_visible(self) -> bool:
        return self._win is not None and self._win.winfo_exists()

    def move_selection(self, delta: int):
        if not self.is_visible() or not self._lb:
            return
        cur = self._lb.curselection()
        idx = (cur[0] if cur else 0) + delta
        idx = max(0, min(idx, self._lb.size() - 1))
        self._lb.selection_clear(0, "end")
        self._lb.selection_set(idx)
        self._lb.see(idx)

    def pick_current(self) -> str | None:
        if not self.is_visible() or not self._lb:
            return None
        cur = self._lb.curselection()
        if cur:
            return self._lb.get(cur[0])
        if self._names:
            return self._names[0]
        return None

    def _pick(self):
        name = self.pick_current()
        if name:
            self._entry._complete_mention(name)


class SpellEntry(tk.Text):
    """Single-line Text widget with live spell-check underlining and @ mention autocomplete."""

    MISSPELL_TAG = "misspell"
    CHECK_DELAY_MS = 400

    def __init__(self, master, **kw):
        kw.setdefault("height", 1)
        kw.setdefault("wrap", "none")
        super().__init__(master, **kw)
        self.tag_configure(self.MISSPELL_TAG,
                           underline=True, foreground="#f38ba8")
        self._after_id = None
        self._mention_popup = _MentionPopup(self)
        self._chatters_fn = None
        if SPELL_OK:
            self.bind("<KeyRelease>", self._on_key_release)
            self.bind("<Button-3>", self._on_right_click)
            self.bind("<Button-2>", self._on_right_click)
        else:
            self.bind("<KeyRelease>", self._check_mention)
        self.bind("<Escape>", lambda _: self._mention_popup.hide())
        self.bind("<FocusOut>", self._on_focus_out)
        self.bind("<Down>", self._on_down)
        self.bind("<Up>", self._on_up)
        self.bind("<Tab>", self._on_tab)
        self.bind("<Return>", self._on_return)

    def enable_mentions(self, chatters_fn):
        """Pass a callable that returns an iterable of known usernames."""
        self._chatters_fn = chatters_fn

    def get_text(self) -> str:
        return self.get("1.0", "end-1c")

    def set_text(self, text: str):
        self.delete("1.0", "end")
        self.insert("1.0", text)
        if SPELL_OK:
            self._run_check()

    def clear(self):
        self.delete("1.0", "end")
        self.tag_remove(self.MISSPELL_TAG, "1.0", "end")

    def _on_key_release(self, event=None):
        """Combined handler: spell-check + mention autocomplete."""
        self._check_mention(event)
        self._schedule_check(event)

    def _schedule_check(self, _event=None):
        if self._after_id:
            self.after_cancel(self._after_id)
        self._after_id = self.after(self.CHECK_DELAY_MS, self._run_check)

    def _run_check(self):
        if not SPELL_OK:
            return
        self.tag_remove(self.MISSPELL_TAG, "1.0", "end")
        text = self.get_text()
        try:
            cursor_col = int(self.index("insert").split(".")[1])
        except Exception:
            cursor_col = len(text)

        for m in re.finditer(r"\b[a-zA-Z']{2,}\b", text):
            word = m.group()
            s, e = m.start(), m.end()
            # Don't underline the word currently being typed
            if s < cursor_col <= e:
                continue
            if _spell.unknown([word.lower()]):
                self.tag_add(self.MISSPELL_TAG, f"1.{s}", f"1.{e}")

    def _on_right_click(self, event):
        if not SPELL_OK:
            return
        idx = self.index(f"@{event.x},{event.y}")
        # Find word boundaries at click position
        word_start = self.index(f"{idx} wordstart")
        word_end   = self.index(f"{idx} wordend")
        word = self.get(word_start, word_end).strip()

        if not word or not _spell.unknown([word.lower()]):
            return

        candidates = sorted(_spell.candidates(word.lower()) or [])[:6]
        if not candidates:
            return

        menu = tk.Menu(self, tearoff=0, bg="#313244", fg="#cdd6f4",
                       activebackground="#45475a", activeforeground="#cdd6f4",
                       relief="flat")
        menu.add_command(label=f'"{word}" — suggestions:', state="disabled")
        menu.add_separator()
        for c in candidates:
            menu.add_command(
                label=c,
                command=lambda c=c, ws=word_start, we=word_end: self._replace(ws, we, c)
            )
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def _replace(self, start, end, replacement):
        self.delete(start, end)
        self.insert(start, replacement)
        self._run_check()

    # ── mention autocomplete ──────────────────────────────────────────────────

    def _get_at_prefix(self) -> str | None:
        """Return the word being typed after @ at cursor, or None."""
        text = self.get_text()
        try:
            col = int(self.index("insert").split(".")[1])
        except Exception:
            return None
        segment = text[:col]
        m = re.search(r"@(\w*)$", segment)
        return m.group(1) if m else None

    def _check_mention(self, event=None):
        """Show/hide mention popup based on current cursor context."""
        if not self._chatters_fn:
            return
        if event and event.keysym in ("Return", "Tab", "Escape",
                                      "Up", "Down", "Left", "Right"):
            return
        prefix = self._get_at_prefix()
        if prefix is None:
            self._mention_popup.hide()
            return
        all_names = list(self._chatters_fn())
        matches = sorted(
            (n for n in all_names if n.lower().startswith(prefix.lower())),
            key=str.lower,
        )
        self._mention_popup.show(matches)

    def _complete_mention(self, name: str):
        """Replace the @partial text with the chosen @name."""
        text = self.get_text()
        try:
            col = int(self.index("insert").split(".")[1])
        except Exception:
            return
        segment = text[:col]
        m = re.search(r"@\w*$", segment)
        if not m:
            return
        start_col = m.start()
        self.delete(f"1.{start_col}", f"1.{col}")
        self.insert(f"1.{start_col}", f"@{name} ")
        self._mention_popup.hide()
        self.focus_set()

    def _on_focus_out(self, event=None):
        self.after(150, self._mention_popup.hide)

    def _on_down(self, event=None):
        if self._mention_popup.is_visible():
            self._mention_popup.move_selection(1)
            return "break"

    def _on_up(self, event=None):
        if self._mention_popup.is_visible():
            self._mention_popup.move_selection(-1)
            return "break"

    def _on_tab(self, event=None):
        if self._mention_popup.is_visible():
            name = self._mention_popup.pick_current()
            if name:
                self._complete_mention(name)
            return "break"

    def _on_return(self, event=None):
        if self._mention_popup.is_visible():
            name = self._mention_popup.pick_current()
            if name:
                self._complete_mention(name)
                return "break"


# ── chat tab ─────────────────────────────────────────────────────────────────

class ChatTab:
    def __init__(self, parent: tk.Widget, base_dir: str):
        self._base_dir = base_dir
        self._irc: IRCConnection | None = None
        self._api: TwitchAPI | None = None
        self._q: queue.Queue = queue.Queue()
        self._messages: dict[int, tuple[str, str, str]] = {}
        self._msg_seq = 0
        self._broadcaster = ""
        self._broadcaster_id = ""
        self._moderator = ""
        self._nick = ""
        self._photo_refs: list[tk.PhotoImage] = []
        self._reply_to_id = ""
        self._reply_to_user = ""
        self._chatters: set[str] = set()

        self._build(parent)
        self._refresh_profiles()
        self._poll_queue()

    def _build(self, parent: tk.Widget):
        parent.configure(bg="#1e1e2e")

        # ── top bar ──────────────────────────────────────────────────────────
        top = tk.Frame(parent, bg="#181825", pady=8)
        top.pack(fill="x")
        tk.Label(top, text="Profile:", bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(side="left", padx=(12, 4))
        self._profile_var = tk.StringVar()
        self._profile_menu = ttk.Combobox(top, textvariable=self._profile_var,
                                          state="readonly", width=20,
                                          font=("Segoe UI", 9))
        self._profile_menu.pack(side="left", padx=(0, 10))
        bs = {"relief": "flat", "cursor": "hand2",
              "font": ("Segoe UI", 9), "padx": 10, "pady": 4}
        self._connect_btn = tk.Button(top, text="Connect", bg="#a6e3a1", fg="#1e1e2e",
                                      activebackground="#94d3a2",
                                      command=self._connect, **bs)
        self._connect_btn.pack(side="left", padx=(0, 6))
        self._disconnect_btn = tk.Button(top, text="Disconnect", bg="#f38ba8",
                                         fg="#1e1e2e", activebackground="#e07a96",
                                         command=self._disconnect, state="disabled", **bs)
        self._disconnect_btn.pack(side="left")

        # ── chat display ──────────────────────────────────────────────────────
        chat_frame = tk.Frame(parent, bg="#1e1e2e")
        chat_frame.pack(fill="both", expand=True, padx=8, pady=(6, 0))
        sb = tk.Scrollbar(chat_frame, bg="#313244", troughcolor="#1e1e2e",
                          relief="flat", width=10)
        sb.pack(side="right", fill="y")
        self._chat = tk.Text(chat_frame, bg="#11111b", fg="#cdd6f4",
                             font=("Consolas", 10), relief="flat",
                             state="disabled", wrap="word",
                             yscrollcommand=sb.set,
                             selectbackground="#313244",
                             insertbackground="#cdd6f4",
                             width=60, height=22)
        self._chat.pack(side="left", fill="both", expand=True)
        sb.config(command=self._chat.yview)
        self._chat.tag_configure("hover_line", background="#1e2030")
        self._chat.bind("<Motion>", self._on_chat_hover)
        self._chat.bind("<Leave>", self._on_chat_leave)
        self._chat.bind("<Button-3>", self._on_right_click)
        self._chat.bind("<Button-2>", self._on_right_click)

        # ── status bar ────────────────────────────────────────────────────────
        self._status_var = tk.StringVar(value="Not connected")
        tk.Label(parent, textvariable=self._status_var,
                 bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9), anchor="w", pady=4).pack(fill="x", padx=12)

        # ── reply indicator ───────────────────────────────────────────────────
        self._reply_frame = tk.Frame(parent, bg="#313244")
        self._reply_label = tk.Label(self._reply_frame, text="",
                                     bg="#313244", fg="#cba6f7",
                                     font=("Segoe UI", 9, "italic"), anchor="w")
        self._reply_label.pack(side="left", padx=(10, 0), pady=3,
                               fill="x", expand=True)
        tk.Button(self._reply_frame, text="✕", bg="#313244", fg="#f38ba8",
                  activebackground="#45475a", relief="flat", cursor="hand2",
                  font=("Segoe UI", 9), padx=6,
                  command=self._cancel_reply).pack(side="right", padx=4)

        # ── send bar ──────────────────────────────────────────────────────────
        send_frame = tk.Frame(parent, bg="#181825", pady=6)
        send_frame.pack(fill="x", padx=8)

        self._emote_btn = tk.Button(send_frame, text="😀", bg="#313244",
                                    fg="#cdd6f4", activebackground="#45475a",
                                    command=self._open_emote_picker,
                                    relief="flat", cursor="hand2",
                                    font=("Segoe UI", 11), padx=6, pady=3,
                                    state="disabled")
        self._emote_btn.pack(side="left", padx=(0, 6))

        self._msg_entry = SpellEntry(
            send_frame,
            bg="#313244", fg="#cdd6f4", insertbackground="#cdd6f4",
            relief="flat", font=("Segoe UI", 10),
            selectbackground="#45475a",
        )
        self._msg_entry.pack(side="left", fill="x", expand=True, ipady=5, padx=(0, 6))
        self._msg_entry.bind("<Return>", self._on_msg_return)
        self._msg_entry.enable_mentions(lambda: self._chatters)

        self._send_btn = tk.Button(send_frame, text="Send", bg="#89b4fa",
                                   fg="#1e1e2e", activebackground="#74a9f0",
                                   command=self._send_message,
                                   relief="flat", cursor="hand2",
                                   font=("Segoe UI", 9), padx=12, pady=4,
                                   state="disabled")
        self._send_btn.pack(side="left")

        spell_note = ("  ✓ spell check" if SPELL_OK else "  spell check unavailable")
        tk.Label(parent, text=spell_note, bg="#1e1e2e",
                 fg="#45475a" if SPELL_OK else "#f38ba8",
                 font=("Segoe UI", 8)).pack(anchor="e", padx=12)

        # ── action bar ────────────────────────────────────────────────────────
        action = tk.Frame(parent, bg="#181825", pady=8)
        action.pack(fill="x", padx=8)
        tk.Label(action, text="Username:", bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(side="left", padx=(4, 4))
        self._target_var = tk.StringVar()
        self._target_entry = tk.Entry(action, textvariable=self._target_var,
                                      bg="#313244", fg="#cdd6f4",
                                      insertbackground="#cdd6f4",
                                      relief="flat", font=("Segoe UI", 10), width=18)
        self._target_entry.pack(side="left", padx=(0, 8), ipady=4)
        self._target_entry.bind("<Return>", lambda _: self._do_ban())
        tk.Button(action, text="Ban", bg="#f38ba8", fg="#1e1e2e",
                  activebackground="#e07a96", command=self._do_ban, **bs,
                  ).pack(side="left", padx=(0, 6))
        tk.Button(action, text="Timeout 10 m", bg="#fab387", fg="#1e1e2e",
                  activebackground="#e0926a",
                  command=lambda: self._do_timeout(600), **bs).pack(side="left")

    # ── profiles ──────────────────────────────────────────────────────────────

    def _refresh_profiles(self):
        configs = scan_env_configs(self._base_dir)
        names = [n for n, _ in configs]
        self._configs = {n: e for n, e in configs}
        self._profile_menu["values"] = names
        if names and not self._profile_var.get():
            self._profile_var.set(names[0])

    # ── connect / disconnect ──────────────────────────────────────────────────

    def _connect(self):
        name = self._profile_var.get()
        if not name:
            messagebox.showinfo("No profile", "Select a profile first.")
            return
        env = self._configs.get(name)
        if not env:
            messagebox.showerror("Profile error", f"Could not load profile '{name}'.")
            return
        token = env.get("TWITCH_ACCESS_TOKEN", "")
        nick = env.get("MODERATOR_LOGIN", "")
        broadcaster = env.get("BROADCASTER_LOGIN", "")
        client_id = env.get("TWITCH_CLIENT_ID", "")
        if not token or not nick or not broadcaster:
            messagebox.showerror("Missing fields",
                                 "Profile needs TWITCH_ACCESS_TOKEN, "
                                 "MODERATOR_LOGIN, and BROADCASTER_LOGIN.")
            return
        self._broadcaster = broadcaster.lower()
        self._moderator = nick.lower()
        self._nick = nick.lower()
        self._api = TwitchAPI(client_id, token)
        self._broadcaster_id = ""
        threading.Thread(target=self._resolve_broadcaster_id, daemon=True).start()
        if self._irc:
            self._irc.stop()
        self._irc = IRCConnection(
            token=token, nick=nick, channel=broadcaster,
            on_message=lambda u, m, e, mid: self._q.put(("chat", u, m, e, mid)),
            on_status=lambda s: self._q.put(("status", s)),
        )
        self._irc.start()
        self._connect_btn.config(state="disabled")
        self._disconnect_btn.config(state="normal")
        self._profile_menu.config(state="disabled")
        self._send_btn.config(state="normal")
        self._emote_btn.config(state="normal")

    def _resolve_broadcaster_id(self):
        try:
            self._broadcaster_id = self._api.get_user_id(self._broadcaster)
        except Exception:
            pass

    def _disconnect(self):
        if self._irc:
            self._irc.stop()
            self._irc = None
        self._connect_btn.config(state="normal")
        self._disconnect_btn.config(state="disabled")
        self._profile_menu.config(state="readonly")
        self._status_var.set("Disconnected")
        self._send_btn.config(state="disabled")
        self._emote_btn.config(state="disabled")
        self._cancel_reply()

    # ── reply ─────────────────────────────────────────────────────────────────

    def _start_reply(self, username: str, msg_id: str):
        self._reply_to_id = msg_id
        self._reply_to_user = username
        self._reply_label.config(text=f"↩ Replying to @{username}")
        self._reply_frame.pack(fill="x", padx=8, before=self._msg_entry.master)
        self._msg_entry.focus()

    def _cancel_reply(self):
        self._reply_to_id = ""
        self._reply_to_user = ""
        self._reply_frame.pack_forget()

    # ── emote picker ──────────────────────────────────────────────────────────

    def _open_emote_picker(self):
        if not self._api:
            return
        EmotePickerWindow(self._chat, self._api, self._broadcaster_id,
                          on_select=self._insert_emote)

    def _insert_emote(self, name: str):
        current = self._msg_entry.get_text()
        if current and not current.endswith(" "):
            current += " "
        self._msg_entry.set_text(current + name + " ")
        self._msg_entry.mark_set("insert", "end")
        self._msg_entry.focus()

    # ── send ──────────────────────────────────────────────────────────────────

    def _on_msg_return(self, event=None):
        """Return key: pick from mention popup if open, otherwise send message."""
        if self._msg_entry._mention_popup.is_visible():
            name = self._msg_entry._mention_popup.pick_current()
            if name:
                self._msg_entry._complete_mention(name)
            return "break"
        self._send_message()
        return "break"

    def _send_message(self):
        text = self._msg_entry.get_text().strip()
        if not text:
            return
        if not self._irc:
            messagebox.showinfo("Not connected", "Connect to a channel first.")
            return
        reply_id = self._reply_to_id or None
        self._irc.send_privmsg(text, reply_parent_msg_id=reply_id)
        prefix = f"↩ @{self._reply_to_user}  " if self._reply_to_user else ""
        self._append_message(self._nick, prefix + text, "", "")
        self._msg_entry.clear()
        self._cancel_reply()
        self._msg_entry.focus()

    # ── queue poll ────────────────────────────────────────────────────────────

    def _poll_queue(self):
        try:
            while True:
                item = self._q.get_nowait()
                try:
                    if item[0] == "chat":
                        _, username, message, emote_tag, msg_id = item
                        for _, _, eid in parse_emotes(emote_tag):
                            _emote_cache.prefetch(eid)
                        self._append_message(username, message, emote_tag, msg_id)
                    elif item[0] == "status":
                        self._status_var.set(item[1])
                    elif item[0] == "system":
                        self._append_system(item[1])
                except Exception as exc:
                    # A single malformed message must never freeze the chat pump.
                    try:
                        self._append_system(f"(couldn't render a message: {exc})")
                    except Exception:
                        pass
        except queue.Empty:
            pass
        finally:
            # Reschedule unconditionally so the pump can't die.
            self._chat.after(CHAT_POLL_MS, self._poll_queue)

    # ── render ────────────────────────────────────────────────────────────────

    def _append_message(self, username: str, message: str,
                        emote_tag: str, msg_id: str):
        self._chatters.add(username)
        seq = self._msg_seq
        self._msg_seq += 1
        self._messages[seq] = (username, message, msg_id)
        idx_tag = f"msgidx_{seq}"
        color = username_color(username)
        tag = f"u_{username}"
        self._chat.config(state="normal")
        prefix = "\n" if self._chat.get("1.0", "end-1c") else ""
        start = self._chat.index("end-1c")
        # Marker showing this chatter's protection status at a glance.
        tier = trust.effective_tier(self._base_dir, self._broadcaster, username)
        marker = "🛡 " if tier == "trusted" else ("⛔ " if tier == "blocked" else "")
        self._chat.tag_configure(tag, foreground=color,
                                 font=("Consolas", 10, "bold"))
        self._chat.insert("end", prefix + marker + username + ": ", tag)

        emote_positions = parse_emotes(emote_tag)
        if emote_positions:
            chars = list(message)
            segments, cursor = [], 0
            for start, end, eid in emote_positions:
                if cursor < start:
                    segments.append(("".join(chars[cursor:start]), False))
                segments.append((eid, True))
                cursor = end + 1
            if cursor < len(chars):
                segments.append(("".join(chars[cursor:]), False))
        else:
            segments = [(message, False)]

        for content, is_emote in segments:
            if is_emote:
                photo = _emote_cache.get_display(content)
                if photo:
                    self._photo_refs.append(photo)
                    self._chat.image_create("end", image=photo, padx=1)
                else:
                    self._chat.insert("end", f"[{content}]")
            else:
                self._chat.insert("end", content)

        # Tag the whole message region so right-click resolves to the correct
        # message regardless of word-wrap or interleaved system lines.
        self._chat.tag_add(idx_tag, start, self._chat.index("end-1c"))

        # Trim oldest messages beyond the cap, deleting their exact tagged range
        # (the leading newline is included in the range, so no blank lines pile up).
        while len(self._messages) > MAX_CHAT_LINES:
            old_seq = min(self._messages)
            ranges = self._chat.tag_ranges(f"msgidx_{old_seq}")
            if ranges:
                self._chat.delete(ranges[0], ranges[-1])
            self._chat.tag_delete(f"msgidx_{old_seq}")
            self._messages.pop(old_seq, None)

        self._chat.config(state="disabled")
        self._chat.see("end")

    def _append_system(self, text: str):
        self._chat.config(state="normal")
        prefix = "\n" if self._chat.get("1.0", "end-1c") else ""
        self._chat.tag_configure("system", foreground="#7f849c",
                                 font=("Consolas", 9, "italic"))
        self._chat.insert("end", f"{prefix}▸ {text}", "system")
        self._chat.config(state="disabled")
        self._chat.see("end")

    # ── right-click (chat messages) ───────────────────────────────────────────

    def _on_chat_hover(self, event):
        """Highlight the full line under the cursor."""
        idx = self._chat.index(f"@{event.x},{event.y}")
        line = idx.split(".")[0]
        self._chat.tag_remove("hover_line", "1.0", "end")
        self._chat.tag_add("hover_line", f"{line}.0", f"{line}.end+1c")

    def _on_chat_leave(self, _event=None):
        self._chat.tag_remove("hover_line", "1.0", "end")

    def _on_right_click(self, event):
        idx = self._chat.index(f"@{event.x},{event.y}")
        seq = None
        for tag_name in self._chat.tag_names(idx):
            if tag_name.startswith("msgidx_"):
                try:
                    seq = int(tag_name[len("msgidx_"):])
                except ValueError:
                    seq = None
                break
        if seq is not None and seq in self._messages:
            username, message, msg_id = self._messages[seq]
            menu = tk.Menu(self._chat, tearoff=0,
                           bg="#313244", fg="#cdd6f4",
                           activebackground="#45475a",
                           activeforeground="#cdd6f4",
                           relief="flat")
            # Reply first
            menu.add_command(label=f"Reply to @{username}",
                             command=lambda: self._start_reply(username, msg_id))
            menu.add_separator()
            menu.add_command(label=f"Ban {username}",
                             command=lambda: self._action_on(username, "ban"))
            menu.add_command(label=f"Timeout {username} (10 m)",
                             command=lambda: self._action_on(username, "timeout"))
            menu.add_separator()

            # Protection list — users the auto-bot will never ban or time out.
            current = trust.get_tier(self._base_dir, self._broadcaster, username)
            global_current = trust.get_global_tier(self._base_dir, username)
            if current == "trusted":
                menu.add_command(
                    label=f"🛡 Remove protection from {username} (this channel)",
                    command=lambda: self._set_trust(username, "regular"))
            else:
                menu.add_command(
                    label=f"🛡 Protect {username} (this channel)",
                    command=lambda: self._set_trust(username, "trusted"))
            if global_current == "trusted":
                menu.add_command(
                    label=f"🌐 Remove protection from {username} (all channels)",
                    command=lambda: self._set_trust_global(username, "regular"))
            else:
                menu.add_command(
                    label=f"🌐 Protect {username} (all channels)",
                    command=lambda: self._set_trust_global(username, "trusted"))
            if current == "blocked":
                menu.add_command(
                    label=f"Unblock {username}",
                    command=lambda: self._set_trust(username, "regular"))
            else:
                menu.add_command(
                    label=f"Block {username} (auto-timeout on sight)",
                    command=lambda: self._set_trust(username, "blocked"))

            # Real Twitch VIP role (needs the broadcaster's token + channel:manage:vips).
            vip_menu = tk.Menu(menu, tearoff=0, bg="#313244", fg="#cdd6f4",
                               activebackground="#45475a",
                               activeforeground="#cdd6f4", relief="flat")
            vip_menu.add_command(label=f"Grant VIP to {username}",
                                 command=lambda: self._vip(username, True))
            vip_menu.add_command(label=f"Remove VIP from {username}",
                                 command=lambda: self._vip(username, False))
            menu.add_cascade(label="Twitch role", menu=vip_menu)

            menu.add_separator()
            menu.add_command(label="Copy username",
                             command=lambda: self._copy(username))
            menu.add_command(label="Copy message",
                             command=lambda: self._copy(message))
            try:
                menu.tk_popup(event.x_root, event.y_root)
            finally:
                menu.grab_release()

    def _set_trust(self, username, tier):
        try:
            result = trust.set_tier(self._base_dir, self._broadcaster, username, tier)
            if result == "regular":
                self._append_system(f"{username} set to Regular (trust cleared).")
            else:
                self._append_system(f"{username} marked {result.capitalize()} "
                                    f"for #{self._broadcaster}.")
        except Exception as exc:
            self._append_system(f"Could not update trust for {username}: {exc}")

    def _set_trust_global(self, username, tier):
        try:
            result = trust.set_tier(self._base_dir, trust.GLOBAL, username, tier)
            if result == "regular":
                self._append_system(f"{username} global protection removed.")
            else:
                self._append_system(f"{username} protected on ALL channels.")
        except Exception as exc:
            self._append_system(f"Could not update global trust for {username}: {exc}")

    def _vip(self, username, grant):
        if not self._api:
            messagebox.showinfo("Not connected", "Connect to a channel first.")
            return
        verb = "Granting VIP to" if grant else "Removing VIP from"
        self._append_system(f"{verb} {username}…")
        threading.Thread(target=self._vip_thread,
                         args=(username, grant), daemon=True).start()

    def _vip_thread(self, username, grant):
        try:
            if grant:
                self._api.add_vip(self._broadcaster, username)
                self._q.put(("system", f"{username} is now a VIP."))
            else:
                self._api.remove_vip(self._broadcaster, username)
                self._q.put(("system", f"Removed VIP from {username}."))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            hint = ""
            if exc.code in (401, 403):
                hint = ("  (VIP changes need the broadcaster's own token with "
                        "channel:manage:vips — works on your channel, not ones "
                        "you only moderate.)")
            self._q.put(("system", f"VIP change failed ({exc.code}): {body[:120]}{hint}"))
        except Exception as exc:
            self._q.put(("system", f"VIP change error: {exc}"))

    def _copy(self, text):
        self._chat.clipboard_clear()
        self._chat.clipboard_append(text)

    def _action_on(self, username, action):
        self._target_var.set(username)
        if action == "ban":
            self._do_ban()
        else:
            self._do_timeout(600)

    # ── moderation ────────────────────────────────────────────────────────────

    def _protected_confirm(self, target, verb):
        """If target is on the protection list, ask before a manual action."""
        if trust.get_tier(self._base_dir, self._broadcaster, target) == "trusted":
            return messagebox.askyesno(
                "Protected user",
                f"{target} is on your protection list (never auto-banned).\n\n"
                f"{verb} them anyway?")
        return True

    def _do_ban(self):
        target = self._target_var.get().strip().lstrip("@")
        if not target:
            return
        if not self._api:
            messagebox.showinfo("Not connected", "Connect to a channel first.")
            return
        if not self._protected_confirm(target, "Ban"):
            return
        self._append_system(f"Banning {target}…")
        threading.Thread(target=self._ban_thread, args=(target,), daemon=True).start()

    def _ban_thread(self, target):
        try:
            self._api.ban_user(self._broadcaster, self._moderator, target)
            self._q.put(("system", f"Banned {target}"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            self._q.put(("system", f"Ban failed ({exc.code}): {body[:120]}"))
        except Exception as exc:
            self._q.put(("system", f"Ban error: {exc}"))

    def _do_timeout(self, seconds):
        target = self._target_var.get().strip().lstrip("@")
        if not target:
            return
        if not self._api:
            messagebox.showinfo("Not connected", "Connect to a channel first.")
            return
        if not self._protected_confirm(target, "Time out"):
            return
        self._append_system(f"Timing out {target} for {seconds // 60} m…")
        threading.Thread(target=self._timeout_thread,
                         args=(target, seconds), daemon=True).start()

    def _timeout_thread(self, target, seconds):
        try:
            self._api.timeout_user(self._broadcaster, self._moderator, target, seconds)
            self._q.put(("system", f"Timed out {target} for {seconds // 60} m"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            self._q.put(("system", f"Timeout failed ({exc.code}): {body[:120]}"))
        except Exception as exc:
            self._q.put(("system", f"Timeout error: {exc}"))

    def destroy(self):
        if self._irc:
            self._irc.stop()


# ── logs tab ─────────────────────────────────────────────────────────────────

class LogsTab:
    """Live tail of a profile's logs/<name>.log with colored flag/hold/action
    lines, so you can watch the bot's decisions in real time."""

    POLL_MS = 500
    INITIAL_TAIL_BYTES = 64 * 1024
    MAX_LINES = 2000

    def __init__(self, parent: tk.Widget, base_dir: str):
        self._base_dir = base_dir
        self._path: str | None = None
        self._pos = 0            # byte offset already displayed
        self._buf = ""           # partial trailing line not yet newline-terminated
        self._alive = True
        self._build(parent)
        self._refresh_profiles()
        self._poll()

    # ── ui ────────────────────────────────────────────────────────────────────

    def _build(self, parent: tk.Widget):
        parent.configure(bg="#1e1e2e")

        top = tk.Frame(parent, bg="#181825", pady=8)
        top.pack(fill="x")
        tk.Label(top, text="Profile:", bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(side="left", padx=(12, 4))
        self._profile_var = tk.StringVar()
        self._profile_menu = ttk.Combobox(top, textvariable=self._profile_var,
                                          state="readonly", width=20,
                                          font=("Segoe UI", 9))
        self._profile_menu.pack(side="left", padx=(0, 10))
        self._profile_menu.bind("<<ComboboxSelected>>", lambda _: self._switch())

        self._follow_var = tk.BooleanVar(value=True)
        tk.Checkbutton(top, text="Follow", variable=self._follow_var,
                       bg="#181825", fg="#cdd6f4", selectcolor="#313244",
                       activebackground="#181825", activeforeground="#cdd6f4",
                       font=("Segoe UI", 9), relief="flat", bd=0,
                       highlightthickness=0).pack(side="left", padx=(0, 8))

        bs = {"relief": "flat", "cursor": "hand2", "font": ("Segoe UI", 9),
              "padx": 10, "pady": 4}
        tk.Button(top, text="↺ Refresh", bg="#89b4fa", fg="#1e1e2e",
                  activebackground="#74a9f0", command=self._refresh_profiles,
                  **bs).pack(side="left", padx=(0, 6))
        tk.Button(top, text="Clear view", bg="#313244", fg="#cdd6f4",
                  activebackground="#45475a", command=self._clear_view,
                  **bs).pack(side="left", padx=(0, 6))
        tk.Button(top, text="Open file", bg="#313244", fg="#cdd6f4",
                  activebackground="#45475a", command=self._open_file,
                  **bs).pack(side="left")

        body = tk.Frame(parent, bg="#1e1e2e")
        body.pack(fill="both", expand=True, padx=8, pady=(6, 0))
        sb = tk.Scrollbar(body, bg="#313244", troughcolor="#1e1e2e",
                          relief="flat", width=10)
        sb.pack(side="right", fill="y")
        self._text = tk.Text(body, bg="#11111b", fg="#cdd6f4",
                             font=("Consolas", 9), relief="flat",
                             state="disabled", wrap="word",
                             yscrollcommand=sb.set,
                             insertbackground="#cdd6f4",
                             selectbackground="#313244")
        self._text.pack(side="left", fill="both", expand=True)
        sb.config(command=self._text.yview)

        self._text.tag_configure("flag",   foreground="#fab387")
        self._text.tag_configure("hold",   foreground="#f9e2af")
        self._text.tag_configure("action", foreground="#f38ba8",
                                 font=("Consolas", 9, "bold"))
        self._text.tag_configure("err",    foreground="#f38ba8",
                                 font=("Consolas", 9, "bold"))
        self._text.tag_configure("info",   foreground="#89b4fa")
        self._text.tag_configure("dim",    foreground="#6c7086")
        self._text.tag_configure("normal", foreground="#cdd6f4")

        self._status_var = tk.StringVar(value="Select a profile")
        tk.Label(parent, textvariable=self._status_var,
                 bg="#181825", fg="#7f849c", font=("Segoe UI", 9),
                 anchor="w", pady=4).pack(fill="x", padx=12)

    # ── profiles ────────────────────────────────────────────────────────────────

    def _refresh_profiles(self):
        names = scan_profiles(self._base_dir)
        self._profile_menu["values"] = names
        if names and not self._profile_var.get():
            self._profile_var.set(names[0])
        if self._profile_var.get():
            self._switch()

    def _log_path_for(self, name: str) -> str:
        return os.path.join(self._base_dir, "logs", f"{name}.log")

    def _switch(self):
        name = self._profile_var.get()
        if not name:
            return
        self._path = self._log_path_for(name)
        self._pos = 0
        self._buf = ""
        self._clear_view()
        self._load_initial()

    # ── file reading ────────────────────────────────────────────────────────────

    def _load_initial(self):
        if not self._path or not os.path.isfile(self._path):
            self._status_var.set("No log yet — start this profile's bot from the Bots tab.")
            return
        try:
            size = os.path.getsize(self._path)
            start = max(0, size - self.INITIAL_TAIL_BYTES)
            with open(self._path, "rb") as f:
                f.seek(start)
                data = f.read()
                self._pos = f.tell()
            text = data.decode("utf-8", "replace")
            if start > 0 and "\n" in text:
                text = text.split("\n", 1)[1]   # drop the partial first line
            self._append_chunk(text)
            self._status_var.set(f"Tailing {os.path.basename(self._path)}")
        except OSError as exc:
            self._status_var.set(f"Could not read log: {exc}")

    def _poll(self):
        if not self._alive:
            return
        try:
            if self._path and os.path.isfile(self._path):
                size = os.path.getsize(self._path)
                if size < self._pos:
                    # File shrank -> rotated/truncated. Restart from the top.
                    self._pos = 0
                    self._buf = ""
                    self._clear_view()
                    self._load_initial()
                elif size > self._pos:
                    with open(self._path, "rb") as f:
                        f.seek(self._pos)
                        data = f.read()
                        self._pos = f.tell()
                    self._append_chunk(data.decode("utf-8", "replace"))
        except OSError:
            pass
        self._text.after(self.POLL_MS, self._poll)

    # ── rendering ────────────────────────────────────────────────────────────────

    @staticmethod
    def _tag_for(line: str) -> str:
        if "[FLAG]" in line:
            return "flag"
        if "[HOLD]" in line:
            return "hold"
        if "Applied " in line or "[DRY RUN]" in line:
            return "action"
        low = line.lower()
        if "failed" in low or "fatal" in low or "warning" in low or "error" in low:
            return "err"
        if "[OK]" in line or "[SKIP]" in line:
            return "dim"
        if any(k in line for k in ("Subscribed", "Validated", "Connecting",
                                   "Reconnect", "Resolved", "starting up",
                                   "Refreshed")):
            return "info"
        return "normal"

    def _append_chunk(self, text: str):
        if not text:
            return
        self._buf += text
        lines = self._buf.split("\n")
        self._buf = lines.pop()   # keep trailing partial line for next read
        if not lines:
            return
        self._text.config(state="normal")
        for line in lines:
            self._text.insert("end", line + "\n", self._tag_for(line))
        # Trim to keep the widget light.
        total = int(self._text.index("end-1c").split(".")[0])
        if total > self.MAX_LINES:
            self._text.delete("1.0", f"{total - self.MAX_LINES}.0")
        self._text.config(state="disabled")
        if self._follow_var.get():
            self._text.see("end")

    # ── buttons ──────────────────────────────────────────────────────────────────

    def _clear_view(self):
        self._text.config(state="normal")
        self._text.delete("1.0", "end")
        self._text.config(state="disabled")

    def _open_file(self):
        if not self._path or not os.path.isfile(self._path):
            messagebox.showinfo("No log", "No log file exists yet for this profile.")
            return
        try:
            if hasattr(os, "startfile"):
                os.startfile(self._path)             # noqa: S606 (Windows)
            elif sys.platform == "darwin":
                subprocess.Popen(["open", self._path])
            else:
                subprocess.Popen(["xdg-open", self._path])
        except Exception as exc:
            messagebox.showinfo("Log file", f"{self._path}\n\n({exc})")

    def destroy(self):
        self._alive = False


# ── safe list tab ────────────────────────────────────────────────────────────

class SafeListTab:
    """Manage the per-channel protection list (never auto-banned) and block
    list (auto-timed-out), by name — no need to catch someone mid-chat.
    Also supports a global list that applies to every channel at once."""

    GLOBAL_LABEL = "★ All channels (global)"

    def __init__(self, parent: tk.Widget, base_dir: str):
        self._base_dir = base_dir
        self._channel = ""      # resolved broadcaster login for selected profile
        self._build(parent)
        self._refresh_profiles()

    def _build(self, parent: tk.Widget):
        parent.configure(bg="#1e1e2e")

        top = tk.Frame(parent, bg="#181825", pady=8)
        top.pack(fill="x")
        tk.Label(top, text="Channel:", bg="#181825", fg="#7f849c",
                 font=("Segoe UI", 9)).pack(side="left", padx=(12, 4))
        self._profile_var = tk.StringVar()
        self._profile_menu = ttk.Combobox(top, textvariable=self._profile_var,
                                          state="readonly", width=20,
                                          font=("Segoe UI", 9))
        self._profile_menu.pack(side="left", padx=(0, 10))
        self._profile_menu.bind("<<ComboboxSelected>>", lambda _: self._switch())
        bs = {"relief": "flat", "cursor": "hand2", "font": ("Segoe UI", 9),
              "padx": 10, "pady": 4}
        tk.Button(top, text="↺ Refresh", bg="#89b4fa", fg="#1e1e2e",
                  activebackground="#74a9f0", command=self._refresh_profiles,
                  **bs).pack(side="left")

        body = tk.Frame(parent, bg="#1e1e2e")
        body.pack(fill="both", expand=True, padx=8, pady=8)

        self._protected_list = self._make_panel(
            body, "🛡  Protected — never auto-banned or timed out",
            "#a6e3a1", "trusted", side="left")
        self._blocked_list = self._make_panel(
            body, "⛔  Blocked — auto-timed-out on sight",
            "#f38ba8", "blocked", side="right")

    def _make_panel(self, parent, title, color, tier, side):
        wrap = tk.Frame(parent, bg="#1e1e2e")
        wrap.pack(side=side, fill="both", expand=True,
                  padx=(0, 4) if side == "left" else (4, 0))
        tk.Label(wrap, text=title, bg="#1e1e2e", fg=color,
                 font=("Segoe UI", 10, "bold"), anchor="w").pack(fill="x", pady=(0, 4))

        add_row = tk.Frame(wrap, bg="#1e1e2e")
        add_row.pack(fill="x", pady=(0, 6))
        entry_var = tk.StringVar()
        entry = tk.Entry(add_row, textvariable=entry_var, bg="#313244", fg="#cdd6f4",
                         insertbackground="#cdd6f4", relief="flat",
                         font=("Segoe UI", 10))
        entry.pack(side="left", fill="x", expand=True, ipady=4, padx=(0, 6))
        entry.bind("<Return>", lambda _: self._add(tier, entry_var))
        tk.Button(add_row, text="Add", bg="#89b4fa", fg="#1e1e2e",
                  activebackground="#74a9f0", relief="flat", cursor="hand2",
                  font=("Segoe UI", 9), padx=12, pady=4,
                  command=lambda: self._add(tier, entry_var)).pack(side="left")

        listbox = tk.Listbox(wrap, bg="#11111b", fg="#cdd6f4",
                             selectbackground="#45475a", selectforeground="#cdd6f4",
                             relief="flat", font=("Consolas", 10),
                             activestyle="none", highlightthickness=0)
        listbox.pack(fill="both", expand=True)

        tk.Button(wrap, text="Remove selected", bg="#313244", fg="#cdd6f4",
                  activebackground="#45475a", relief="flat", cursor="hand2",
                  font=("Segoe UI", 9), padx=10, pady=4,
                  command=lambda: self._remove(tier, listbox)).pack(anchor="e", pady=(6, 0))
        return listbox

    def _refresh_profiles(self):
        names = scan_profiles(self._base_dir)
        self._profile_menu["values"] = [self.GLOBAL_LABEL] + names
        if names and not self._profile_var.get():
            self._profile_var.set(names[0])
        self._switch()

    def _switch(self):
        name = self._profile_var.get()
        if not name:
            return
        if name == self.GLOBAL_LABEL:
            self._channel = trust.GLOBAL
            self._reload_lists()
            return
        try:
            env = botconfig.profile_env(self._base_dir, name)
            self._channel = env.get("BROADCASTER_LOGIN", name).lower()
        except Exception:
            self._channel = name.lower()
        self._reload_lists()

    def _reload_lists(self):
        data = trust.load(self._base_dir).get(self._channel, {})
        protected = sorted(u for u, t in data.items() if t == "trusted")
        blocked = sorted(u for u, t in data.items() if t == "blocked")
        self._protected_list.delete(0, "end")
        for u in protected:
            self._protected_list.insert("end", u)
        self._blocked_list.delete(0, "end")
        for u in blocked:
            self._blocked_list.insert("end", u)

    def _add(self, tier, entry_var):
        if not self._channel:
            messagebox.showinfo("No channel", "Pick a channel first.")
            return
        name = entry_var.get().strip().lstrip("@")
        if not name:
            return
        trust.set_tier(self._base_dir, self._channel, name, tier)
        entry_var.set("")
        self._reload_lists()

    def _remove(self, tier, listbox):
        sel = listbox.curselection()
        if not sel:
            return
        name = listbox.get(sel[0])
        trust.set_tier(self._base_dir, self._channel, name, "regular")
        self._reload_lists()


# ── launcher app ─────────────────────────────────────────────────────────────

class LauncherApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Twitch Bot Launcher")
        self.root.configure(bg="#181825")
        self.root.resizable(True, True)
        self.root.minsize(480, 400)
        self.base_dir = os.path.dirname(os.path.abspath(__file__))
        self.manager = ProcessManager()
        self.python_cmd = find_python()
        self.rows: list[ProfileRow] = []
        self._apply_styles()
        self._build_ui()
        self._load_profiles()
        self._poll()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _apply_styles(self):
        style = ttk.Style(self.root)
        style.theme_use("default")
        style.configure("TNotebook", background="#181825", borderwidth=0,
                        tabmargins=[0, 0, 0, 0])
        style.configure("TNotebook.Tab", background="#313244", foreground="#cdd6f4",
                        padding=[16, 6], font=("Segoe UI", 10))
        style.map("TNotebook.Tab",
                  background=[("selected", "#1e1e2e"), ("active", "#45475a")],
                  foreground=[("selected", "#cba6f7")])
        style.configure("TFrame", background="#1e1e2e")
        style.configure("TCombobox", fieldbackground="#313244", background="#313244",
                        foreground="#cdd6f4", selectbackground="#45475a",
                        selectforeground="#cdd6f4", arrowcolor="#cdd6f4")

    def _build_ui(self):
        header = tk.Frame(self.root, bg="#181825", pady=10)
        header.pack(fill="x")
        tk.Label(header, text="Twitch Bot Launcher", bg="#181825", fg="#cba6f7",
                 font=("Segoe UI", 13, "bold")).pack(side="left", padx=16)
        if self.python_cmd is None:
            tk.Label(header, text="⚠ Python not found", bg="#181825", fg="#f38ba8",
                     font=("Segoe UI", 9)).pack(side="right", padx=16)
        notebook = ttk.Notebook(self.root)
        notebook.pack(fill="both", expand=True)
        bots_frame = tk.Frame(notebook, bg="#1e1e2e")
        notebook.add(bots_frame, text="  Bots  ")
        self._build_bots_tab(bots_frame)
        chat_frame = tk.Frame(notebook, bg="#1e1e2e")
        notebook.add(chat_frame, text="  Chat  ")
        self._chat_tab = ChatTab(chat_frame, self.base_dir)
        logs_frame = tk.Frame(notebook, bg="#1e1e2e")
        notebook.add(logs_frame, text="  Logs  ")
        self._logs_tab = LogsTab(logs_frame, self.base_dir)
        safe_frame = tk.Frame(notebook, bg="#1e1e2e")
        notebook.add(safe_frame, text="  Safe List  ")
        self._safe_tab = SafeListTab(safe_frame, self.base_dir)

    def _build_bots_tab(self, parent):
        tk.Label(parent, text="Click a profile to start or stop its bot",
                 bg="#1e1e2e", fg="#7f849c",
                 font=("Segoe UI", 9, "italic")).pack(anchor="w", padx=16, pady=(10, 2))
        self.list_frame = tk.Frame(parent, bg="#1e1e2e")
        self.list_frame.pack(fill="both", expand=True, pady=4)
        self.no_profiles_label = tk.Label(
            self.list_frame, text="No .env profiles found in configs/",
            bg="#1e1e2e", fg="#7f849c", font=("Segoe UI", 10, "italic"))
        btn_frame = tk.Frame(parent, bg="#181825", pady=10)
        btn_frame.pack(fill="x", padx=12)
        bs = {"font": ("Segoe UI", 10), "relief": "flat",
              "cursor": "hand2", "padx": 14, "pady": 6}
        tk.Button(btn_frame, text="■  Stop All", bg="#f38ba8", fg="#1e1e2e",
                  activebackground="#e07a96", command=self._stop_all,
                  **bs).pack(side="left", padx=(0, 6))
        tk.Button(btn_frame, text="↺  Refresh", bg="#89b4fa", fg="#1e1e2e",
                  activebackground="#74a9f0", command=self._load_profiles,
                  **bs).pack(side="left")
        tk.Button(btn_frame, text="🗎  Open Logs", bg="#313244", fg="#cdd6f4",
                  activebackground="#45475a", command=self._open_logs,
                  **bs).pack(side="left", padx=(6, 0))

    def _open_logs(self):
        logs_dir = os.path.join(self.base_dir, "logs")
        os.makedirs(logs_dir, exist_ok=True)
        try:
            if hasattr(os, "startfile"):          # Windows
                os.startfile(logs_dir)            # noqa: S606
            elif sys.platform == "darwin":
                subprocess.Popen(["open", logs_dir])
            else:
                subprocess.Popen(["xdg-open", logs_dir])
        except Exception as exc:
            messagebox.showinfo("Logs folder", f"Logs are in:\n{logs_dir}\n\n({exc})")

    def _load_profiles(self):
        current_running = {r.name for r in self.rows if self.manager.is_running(r.name)}
        for row in self.rows:
            row.destroy()
        self.rows.clear()
        profiles = scan_profiles(self.base_dir)
        if not profiles:
            self.no_profiles_label.pack(pady=20)
        else:
            self.no_profiles_label.pack_forget()
            for name in profiles:
                row = ProfileRow(self.list_frame, name, self._toggle_profile)
                if self.manager.is_running(name) or name in current_running:
                    row.set_running(True)
                self.rows.append(row)
        self.root.update_idletasks()

    def _toggle_profile(self, name: str, start: bool):
        if start:
            if self.python_cmd is None:
                messagebox.showerror("Python Not Found",
                                     "Could not locate a Python 3 executable.\n"
                                     "Install Python 3 and restart the launcher.")
                return
            try:
                self.manager.start(name, self.python_cmd, self.base_dir)
                for row in self.rows:
                    if row.name == name:
                        row.set_running(True)
            except Exception as exc:
                messagebox.showerror("Start Failed",
                                     f"Could not start '{name}':\n{exc}")
        else:
            self.manager.stop(name)
            for row in self.rows:
                if row.name == name:
                    row.set_running(False)

    def _stop_all(self):
        for row in self.rows:
            if row.is_running():
                self.manager.stop(row.name)
                row.set_running(False)

    def _poll(self):
        for row in self.rows:
            self.manager.is_running(row.name)
        self.root.after(POLL_INTERVAL_MS, self._poll)

    def _on_close(self):
        self.manager.stop_all()
        if hasattr(self, "_chat_tab"):
            self._chat_tab.destroy()
        if hasattr(self, "_logs_tab"):
            self._logs_tab.destroy()
        self.root.destroy()


def set_window_icon(root: tk.Tk):
    icon_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.ico")
    try:
        if os.path.isfile(icon_path):
            root.iconbitmap(icon_path)
    except Exception:
        pass


def _relaunch_windowless_if_needed():
    """On Windows, if we're running under console python.exe, re-launch under
    pythonw.exe (no console) and exit. This makes the launcher open like an app
    however it was started — double-clicked .py, .bat, or shortcut."""
    if sys.platform != "win32":
        return
    if os.environ.get("TBL_NO_RELAUNCH") == "1":
        return
    exe = os.path.basename(sys.executable).lower()
    if exe.startswith("pythonw"):
        return  # already windowless
    pythonw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    if not os.path.isfile(pythonw):
        return  # no pythonw available; carry on with a console
    try:
        env = dict(os.environ, TBL_NO_RELAUNCH="1")
        subprocess.Popen(
            [pythonw, os.path.abspath(__file__)] + sys.argv[1:],
            env=env, creationflags=_CREATE_NO_WINDOW,
        )
        sys.exit(0)
    except Exception:
        return  # if relaunch fails, just run normally


def main():
    _relaunch_windowless_if_needed()
    root = tk.Tk()
    set_window_icon(root)
    LauncherApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
