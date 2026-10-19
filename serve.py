#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
局域网浏览图片/动图 —— 可同时挂载多个文件夹。

用法：
    python serve.py "D:\\pics"
    python serve.py "D:\\pics" "E:\\anime" "C:\\Users\\你\\Desktop\\qqqq" --port 8765

每个文件夹在网页里显示为一个"目录"，文件按 目录名/子路径 展示。
只读取文件，不写入、不修改原图；Ctrl+C 即停止。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import mimetypes
import multiprocessing as mp
import os
import socket
import sys
import threading
import time
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

mimetypes.add_type("image/webp", ".webp")
mimetypes.add_type("image/heic", ".heic")
mimetypes.add_type("image/heif", ".heif")
mimetypes.add_type("image/avif", ".avif")
mimetypes.add_type("image/tiff", ".tif")
mimetypes.add_type("image/tiff", ".tiff")
mimetypes.add_type("image/bmp", ".bmp")
mimetypes.add_type("text/html", ".html")

WEBP_EXT = ".webp"
IMAGE_EXTS = {".webp", ".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".ico", ".avif"}

CACHE_VERSION = 6

THUMB_WIDTH = 320
THUMB_QUALITY = 70

LITE_WIDTH = 400
LITE_FRAMES = 48
LITE_QUALITY = 45

try:
    from PIL import Image, ImageOps

    HAS_PIL = True
except Exception:
    HAS_PIL = False
try:
    import pillow_avif  # noqa: F401  注册 AVIF 解码
except Exception:
    pass

HAS_HEIF = False
try:
    import pillow_heif
    pillow_heif.register_heif_opener()
    HAS_HEIF = True
except Exception:
    HAS_HEIF = False


# ---------------- 缩略图 / 轻量版 ----------------

_LOCKS: dict[str, threading.Lock] = {}
_LOCK_GUARD = threading.Lock()
_SEM_THUMB = threading.Semaphore(3)
_SEM_LITE = threading.Semaphore(1)


def _lock_for(key: str) -> threading.Lock:
    with _LOCK_GUARD:
        return _LOCKS.setdefault(key, threading.Lock())


def _has_alpha(im) -> bool:
    try:
        if "A" in im.mode:
            return im.getchannel("A").getextrema()[0] < 250
        return False
    except Exception:
        return False


def build_thumb(src: Path, dst: Path, width: int = THUMB_WIDTH):
    with Image.open(src) as im:
        im.seek(0)
        try:
            im = ImageOps.exif_transpose(im)
        except Exception:
            pass
        alpha = _has_alpha(im)
        fr = im.convert("RGBA" if alpha else "RGB")
        w, h = fr.size
        tw = max(2, min(width, w))
        th = max(2, round(h * tw / w))
        fr.resize((tw, th), Image.Resampling.BOX).save(
            dst, format="WEBP", quality=THUMB_QUALITY, method=2
        )


def build_lite(src: Path, dst: Path, width: int, max_frames: int, quality: int):
    with Image.open(src) as im:
        n = getattr(im, "n_frames", 1) or 1
        im.seek(0)
        if n == 1:
            try:
                im = ImageOps.exif_transpose(im)
            except Exception:
                pass
        alpha = _has_alpha(im)
        mode = "RGBA" if alpha else "RGB"

        w, h = im.size
        tw = max(2, min(width, w))
        th = max(2, round(h * tw / w))
        step = max(1, math.ceil(n / max_frames))

        frames, durs = [], []
        for i in range(0, n, step):
            im.seek(i)
            d = im.info.get("duration") or 60
            frames.append(im.resize((tw, th), Image.Resampling.BOX).convert(mode))
            durs.append(max(20, int(d) * step))

        if len(frames) == 1:
            frames[0].save(dst, format="WEBP", quality=quality, method=0)
        else:
            frames[0].save(
                dst, format="WEBP", save_all=True, append_images=frames[1:],
                duration=durs, loop=0, quality=quality, method=0,
            )


def build_conv(src: Path, dst: Path):
    with Image.open(src) as im:
        im.seek(0)
        try:
            im = ImageOps.exif_transpose(im)
        except Exception:
            pass
        im.convert("RGB").save(dst, format="JPEG", quality=90, optimize=True)


def ensure(src: Path, dst: Path, builder, sem: threading.Semaphore):
    if dst.is_file():
        return dst
    with _lock_for(str(dst)):
        if dst.is_file():
            return dst
        with sem:
            dst.parent.mkdir(parents=True, exist_ok=True)
            tmp = dst.with_name(f"{dst.stem}.{threading.get_ident()}.tmp")
            try:
                builder(src, tmp)
                tmp.replace(dst)
            finally:
                if tmp.exists():
                    try:
                        tmp.unlink()
                    except OSError:
                        pass
    return dst


class Cache:
    """每个挂载目录一个 Cache，tag 用来区分同名文件。"""

    def __init__(self, root: Path, media_root: Path, tag: str):
        self.root = root
        self.media_root = media_root
        self.tag = tag

    def _rel(self, src: Path) -> str:
        try:
            return src.resolve().relative_to(self.media_root).as_posix().lower()
        except (ValueError, OSError):
            return src.name.lower()

    def slug(self, src: Path) -> str:
        return hashlib.md5(f"{self.tag}|{self._rel(src)}".encode("utf-8")).hexdigest()[:16]

    def _sig(self, src: Path, extra: str) -> str:
        try:
            st = src.stat()
            raw = f"{int(st.st_mtime)}-{st.st_size}-{extra}"
        except OSError:
            raw = "0-0"
        return hashlib.md5(raw.encode("utf-8")).hexdigest()[:10]

    def name(self, kind: str, src: Path, extra: str = "") -> str:
        return f"{self.slug(src)}-{self._sig(src, extra)}.webp"

    def path(self, kind: str, src: Path, extra: str = "") -> Path:
        return self.root / kind / self.name(kind, src, extra)

    def thumb(self, src: Path) -> Path:
        dst = self.path("thumb", src, str(THUMB_WIDTH))
        return ensure(src, dst, lambda s, d: build_thumb(s, d, THUMB_WIDTH), _SEM_THUMB)

    def lite(self, src: Path) -> Path:
        extra = f"{LITE_WIDTH}-{LITE_FRAMES}-{LITE_QUALITY}"
        dst = self.path("lite", src, extra)
        return ensure(
            src, dst,
            lambda s, d: build_lite(s, d, LITE_WIDTH, LITE_FRAMES, LITE_QUALITY),
            _SEM_LITE,
        )

    def conv(self, src: Path) -> Path:
        name = self.name("conv", src, "jpg90").replace(".webp", ".jpg")
        dst = self.root / "conv" / name
        return ensure(src, dst, build_conv, _SEM_LITE)

    def sweep(self, files) -> int:
        valid = {
            "thumb": {self.name("thumb", f, str(THUMB_WIDTH)) for f in files},
            "lite": {
                self.name("lite", f, f"{LITE_WIDTH}-{LITE_FRAMES}-{LITE_QUALITY}")
                for f in files
            },
        }
        removed = 0
        for kind, names in valid.items():
            d = self.root / kind
            if not d.is_dir():
                continue
            for p in d.iterdir():
                if (p.is_file() and p.suffix.lower() == ".webp"
                        and p.name not in names and not p.name.endswith(".tmp")):
                    try:
                        p.unlink()
                        removed += 1
                    except OSError:
                        pass
        return removed


def _set_priority(flag: int):
    try:
        import ctypes

        k = ctypes.windll.kernel32
        k.GetCurrentProcess.restype = ctypes.c_void_p
        k.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        k.SetPriorityClass(k.GetCurrentProcess(), flag)
    except Exception:
        pass


def _run_job(job):
    src, dst, kind, width, frames, quality = job
    tmp = f"{dst}.{os.getpid()}.tmp"
    try:
        Path(dst).parent.mkdir(parents=True, exist_ok=True)
        if kind == "thumb":
            build_thumb(Path(src), Path(tmp), width)
        else:
            build_lite(Path(src), Path(tmp), width, frames, quality)
        os.replace(tmp, dst)
        return True
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def _run_job_safe(job):
    _set_priority(0x00004000)
    return _run_job(job)


def sweep_all(caches, per_root, cache_root=None):
    """统一清理：只有不属于任何一个挂载目录的缓存才删。"""
    valid = {"thumb": set(), "lite": set(), "conv": set()}
    for i, files in enumerate(per_root):
        c = caches[i]
        extra = f"{LITE_WIDTH}-{LITE_FRAMES}-{LITE_QUALITY}"
        for p in files:
            valid["thumb"].add(c.name("thumb", p, str(THUMB_WIDTH)))
            valid["lite"].add(c.name("lite", p, extra))
            valid["conv"].add(c.name("conv", p, "jpg90").replace(".webp", ".jpg"))

    base = cache_root if cache_root else (caches[0].root if caches else None)
    if base is None:
        return 0
    removed = 0
    for kind in ("thumb", "lite", "conv"):
        d = base / kind
        if not d.is_dir():
            continue
        for p in d.iterdir():
            if (p.is_file() and p.suffix.lower() == ".webp"
                    and p.name not in valid[kind] and not p.name.endswith(".tmp")):
                try:
                    p.unlink()
                    removed += 1
                except OSError:
                    pass
    return removed


class Watcher(threading.Thread):
    """盯着所有挂载目录：新增/改动就补缓存，删除就清缓存。"""

    def __init__(self, roots, caches, interval=5, workers=2,
                 use_lite=True, use_thumb=True, cache_root=None):
        super().__init__(daemon=True)
        self.roots = roots
        self.caches = caches
        self.interval = max(2, interval)
        self.workers = max(1, workers)
        self.use_lite = use_lite
        self.use_thumb = use_thumb
        self.cache_root = cache_root
        self.procs = []
        self.done = 0

    def _scan(self, i):
        out = []
        try:
            for p in self.roots[i].rglob("*"):
                if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
                    out.append((i, p))
        except OSError:
            pass
        return out

    def _jobs_for(self, items):
        jobs = []
        for i, p in items:
            c = self.caches[i]
            if self.use_thumb:
                dst = c.path("thumb", p, str(THUMB_WIDTH))
                if not dst.is_file():
                    jobs.append((str(p), str(dst), "thumb", THUMB_WIDTH, 0, 0))
            if self.use_lite and p.suffix.lower() in IMAGE_EXTS:
                dst = c.path("lite", p, f"{LITE_WIDTH}-{LITE_FRAMES}-{LITE_QUALITY}")
                if not dst.is_file():
                    jobs.append((str(p), str(dst), "lite",
                                 LITE_WIDTH, LITE_FRAMES, LITE_QUALITY))
        return jobs

    def _reap(self):
        alive = []
        for proc, key in self.procs:
            if proc.is_alive():
                alive.append((proc, key))
            else:
                proc.join(timeout=0)
                if proc.exitcode == 0:
                    self.done += 1
        self.procs = alive

    def _submit(self, jobs):
        self._reap()
        inflight = {k for _p, k in self.procs}
        for job in jobs:
            key = job[1]
            if key in inflight:
                continue
            if len(self.procs) >= self.workers:
                break
            proc = mp.Process(target=_run_job_safe, args=(job,), daemon=True)
            proc.start()
            self.procs.append((proc, key))
            inflight.add(key)

    def tick(self):
        total = 0
        per_root = []
        for i in range(len(self.roots)):
            items = self._scan(i)
            per_root.append([p for _j, p in items])
            jobs = self._jobs_for(items)
            self._submit(jobs)
            total += len(jobs)
        sweep_all(self.caches, per_root, self.cache_root)
        return total

    def run(self):
        last = 0
        while True:
            try:
                left = self.tick()
                now = time.time()
                if self.done and now - last >= 30:
                    print(f"  [缓存] 已生成 {self.done} 个，剩余 {left} 个待处理", flush=True)
                    last = now
            except Exception:
                pass
            time.sleep(self.interval)


class RootWatcher(threading.Thread):
    """每 3 秒看一眼 配置.json，目录变了就热切换，不用重启服务。"""

    def __init__(self, script_dir: Path, file_watcher=None, interval: float = 3.0):
        super().__init__(daemon=True)
        self.script_dir = script_dir
        self.file_watcher = file_watcher
        self.interval = interval
        self.cfg = script_dir / "配置.json"

    def _load(self):
        try:
            obj = json.loads(self.cfg.read_text(encoding="utf-8"))
        except Exception:
            return None
        dirs = []
        for d in obj.get("dirs", []):
            if not d:
                continue
            p = Path(str(d))
            if not p.is_absolute():
                p = self.script_dir / p
            try:
                if p.is_dir():
                    dirs.append(p.resolve())
            except OSError:
                pass
        return dirs

    def run(self):
        last = tuple(Handler.roots)
        while True:
            try:
                dirs = self._load()
                if (dirs is not None) and tuple(dirs) != last:
                    Handler.roots = dirs
                    Handler.caches = [Cache(Handler.cache_dir, r, str(i))
                                      for i, r in enumerate(dirs)]
                    Handler._prog = {"t": 0.0, "data": None}
                    if self.file_watcher is not None:
                        self.file_watcher.roots = dirs
                        self.file_watcher.caches = Handler.caches
                    last = tuple(dirs)
                    print(f"  [热加载] 目录已更新，共 {len(dirs)} 个", flush=True)
            except Exception:
                pass
            time.sleep(self.interval)


# ---------------- 网络 ----------------

def find_viewer() -> Path | None:
    here = Path(__file__).resolve().parent
    for cand in (here / "webp-viewer.html", here.parent / "webp-viewer.html"):
        if cand.is_file():
            return cand
    return None


def lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("223.5.5.5", 80))
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return "127.0.0.1"


def default_cache_dir() -> Path:
    return Path(__file__).resolve().parent / "缓存"


class Handler(SimpleHTTPRequestHandler):
    roots: list[Path] = []
    caches: list[Cache] = []
    viewer: Path | None = None
    cache_dir: Path = Path(".")
    use_thumb: bool = True
    use_lite: bool = True
    convert_heic: bool = True
    protocol_version = "HTTP/1.1"
    server_version = "WebPViewer/3.1"
    _prog = {"t": 0.0, "data": None}

    def log_message(self, fmt, *args):
        pass

    # ---------- 路由 ----------
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        if path in ("/", "/index.html"):
            if not self.viewer:
                return self.send_error(500, "viewer missing")
            return self._send_file(self.viewer, "text/html; charset=utf-8", cache="no-store")

        if path == "/api/list":
            return self._send_list()

        if path == "/api/progress":
            return self._send_progress()

        if path == "/api/purge":
            try:
                per = []
                for r in self.roots:
                    per.append([p for p in r.rglob("*")
                                if p.is_file() and p.suffix.lower() in IMAGE_EXTS])
                n = sweep_all(self.caches, per, self.cache_dir)
            except Exception:
                n = -1
            Handler._prog = {"t": 0.0, "data": None}
            return self._send_json({"removed": n})

        if path == "/speed":
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            try:
                n = int(qs.get("bytes", ["524288"])[0])
            except ValueError:
                n = 524288
            n = max(64 * 1024, min(8 * 1024 * 1024, n))
            return self._send(b"\0" * n, "application/octet-stream", cache="no-store")

        for prefix, kind in (("/thumb/", "thumb"), ("/lite/", "lite"), ("/conv/", "conv"), ("/files/", "file")):
            if path.startswith(prefix):
                rest = urllib.parse.unquote(path[len(prefix):])
                idx_s, _, rel = rest.partition("/")
                try:
                    idx = int(idx_s)
                except ValueError:
                    return self.send_error(404, "bad root")
                if idx < 0 or idx >= len(self.roots):
                    return self.send_error(404, "bad root")
                if kind == "file":
                    target = self._safe(idx, rel)
                    if target is None:
                        return self.send_error(404, "not found")
                    return self._send_file(target)
                return self._send_derived(idx, rel, kind)

        self.send_error(404, "not found")

    # ---------- 工具 ----------
    def _safe(self, idx: int, rel: str) -> Path | None:
        try:
            root = self.roots[idx].resolve()
            p = (root / rel).resolve()
            p.relative_to(root)
        except (ValueError, OSError, IndexError):
            return None
        return p if p.is_file() else None

    def _send(self, data: bytes, ctype: str, cache: str = "no-cache",
              etag: str | None = None, lastmod: float | None = None):
        try:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", cache)
            if etag:
                self.send_header("ETag", etag)
            if lastmod:
                self.send_header("Last-Modified", self.date_time_string(lastmod))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_file(self, p: Path, ctype: str | None = None,
                   cache: str = "public, max-age=86400"):
        try:
            st = p.stat()
        except OSError:
            return self.send_error(404, "not found")

        etag = f'"{int(st.st_mtime)}-{st.st_size}"'
        if self.headers.get("If-None-Match") == etag:
            try:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        try:
            data = p.read_bytes()
        except OSError:
            return self.send_error(404, "not found")
        if ctype is None:
            ctype = mimetypes.guess_type(str(p))[0] or "application/octet-stream"
        self._send(data, ctype, cache=cache, etag=etag, lastmod=st.st_mtime)

    def _redirect(self, location: str):
        try:
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_derived(self, idx: int, rel: str, kind: str):
        src = self._safe(idx, rel)
        if src is None:
            return self.send_error(404, "not found")

        if kind == "conv":
            if src.suffix.lower() in (".heic", ".heif", ".avif", ".tif", ".tiff") and HAS_PIL and getattr(self, "convert_heic", True):
                try:
                    dst = self.caches[idx].conv(src)
                    return self._send(dst.read_bytes(), "image/jpeg", cache="public, max-age=31536000, immutable")
                except Exception:
                    pass
            return self._redirect(f"/files/{idx}/" + urllib.parse.quote(rel))

        full = f"/files/{idx}/" + urllib.parse.quote(rel)
        if not HAS_PIL or src.suffix.lower() not in IMAGE_EXTS:
            return self._redirect(full)
        if kind == "lite" and not self.use_lite:
            return self._redirect(full)
        if kind == "thumb" and not self.use_thumb:
            return self._redirect(full)

        try:
            c = self.caches[idx]
            dst = c.thumb(src) if kind == "thumb" else c.lite(src)
            data = dst.read_bytes()
        except Exception:
            return self._redirect(full)

        self._send(data, "image/webp", cache="public, max-age=31536000, immutable")

    def _send_progress(self):
        now = time.time()
        cache = Handler._prog
        if cache["data"] is not None and now - cache["t"] < 2.0:
            return self._send_json(cache["data"])

        total = done = 0
        roots_out = []
        for i, root in enumerate(self.roots):
            c = self.caches[i]
            n = d = 0
            try:
                for p in root.rglob("*"):
                    if not (p.is_file() and p.suffix.lower() in IMAGE_EXTS):
                        continue
                    n += 1
                    if c.path("lite", p, f"{LITE_WIDTH}-{LITE_FRAMES}-{LITE_QUALITY}").is_file():
                        d += 1
            except OSError:
                pass
            total += n
            done += d
            roots_out.append({"i": i, "name": root.name, "total": n, "done": d})

        data = {"total": total, "done": done, "roots": roots_out}
        Handler._prog = {"t": now, "data": data}
        self._send_json(data)

    def _send_json(self, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_list(self):
        files = []
        for i, root in enumerate(self.roots):
            ref = root.name
            used = {f["rootName"] for f in files}
            if ref in used:
                ref = f"{ref} #{i + 1}"
            try:
                for p in root.rglob("*"):
                    if not (p.is_file() and p.suffix.lower() in IMAGE_EXTS):
                        continue
                    rel = p.relative_to(root).as_posix()
                    try:
                        size = p.stat().st_size
                    except OSError:
                        size = 0
                    q = urllib.parse.quote(rel)
                    base = f"/files/{i}/{q}"
                    files.append({
                        "name": f"{ref}/{rel}",
                        "root": i,
                        "rootName": ref,
                        "rel": rel,
                        "size": size,
                        "url": (f"/conv/{i}/{q}" if (p.suffix.lower() in (".heic", ".heif", ".avif", ".tif", ".tiff") and HAS_PIL and getattr(self, "convert_heic", True)) else base),
                        "thumb": f"/thumb/{i}/{q}" if (self.use_thumb and HAS_PIL) else base,
                        "lite": f"/lite/{i}/{q}" if (self.use_lite and HAS_PIL) else base,
                    })
            except OSError:
                continue

        files.sort(key=lambda x: x["name"])
        body = json.dumps(
            {"roots": [{"index": i, "name": r.name, "path": str(r)}
                       for i, r in enumerate(self.roots)],
             "count": len(files), "files": files},
            ensure_ascii=False,
        ).encode("utf-8")

        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main(argv=None) -> int:
    global LITE_WIDTH, LITE_FRAMES, LITE_QUALITY

    ap = argparse.ArgumentParser(description="局域网浏览图片/动图（多目录）")
    ap.add_argument("folders", nargs="+", help="一个或多个图片文件夹")
    ap.add_argument("-p", "--port", type=int, default=8765, help="端口，默认 8765")
    ap.add_argument("--viewer", help="webp-viewer.html 的路径")
    ap.add_argument("--lite-width", type=int, default=LITE_WIDTH, help="轻量版宽度，默认 400")
    ap.add_argument("--lite-frames", type=int, default=LITE_FRAMES, help="轻量版最多帧数，默认 48")
    ap.add_argument("--lite-quality", type=int, default=LITE_QUALITY, help="轻量版质量，默认 45")
    ap.add_argument("--no-lite", action="store_true", help="不生成轻量版")
    ap.add_argument("--no-convert-heic", action="store_true", help="不把 HEIC 转成 JPG")
    ap.add_argument("--no-thumb", action="store_true", help="不生成缩略图")
    ap.add_argument("--no-watch", action="store_true", help="不监听目录变化")
    ap.add_argument("--watch-interval", type=int, default=5, help="扫描间隔秒，默认 5")
    ap.add_argument("--workers", type=int, default=2, help="并行转码进程数，默认 2")
    ap.add_argument("--cache", help="缓存目录")
    args = ap.parse_args(argv)

    LITE_WIDTH = max(120, args.lite_width)
    LITE_FRAMES = max(5, args.lite_frames)
    LITE_QUALITY = max(20, min(95, args.lite_quality))

    roots = []
    for f in args.folders:
        p = Path(f).expanduser()
        if not p.is_dir():
            print(f"文件夹不存在：{p}", file=sys.stderr)
            return 2
        roots.append(p.resolve())
    if not roots:
        print("至少要给一个文件夹。", file=sys.stderr)
        return 2

    viewer = Path(args.viewer).resolve() if args.viewer else find_viewer()
    if not viewer or not viewer.is_file():
        print("找不到 webp-viewer.html，请让它和 serve.py 放在同一目录。", file=sys.stderr)
        return 2

    cache_dir = Path(args.cache).expanduser() if args.cache else default_cache_dir()
    Handler.roots = roots
    Handler.caches = [Cache(cache_dir, r, str(i)) for i, r in enumerate(roots)]
    Handler.viewer = viewer
    Handler.cache_dir = cache_dir
    Handler.use_thumb = not args.no_thumb
    Handler.use_lite = not args.no_lite
    Handler.convert_heic = not args.no_convert_heic

    httpd = None
    port = args.port
    for p in range(args.port, args.port + 12):
        try:
            httpd = ThreadingHTTPServer(("0.0.0.0", p), Handler)
            port = p
            break
        except OSError:
            continue
    if httpd is None:
        print(f"端口 {args.port}~{args.port + 11} 都被占用了。", file=sys.stderr)
        return 1

    httpd.daemon_threads = True
    ip = lan_ip()

    try:
        (Path(__file__).resolve().parent / "serve.pid").write_text(
            str(os.getpid()), encoding="utf-8"
        )
    except Exception:
        pass

    file_watcher = None
    if not args.no_watch and HAS_PIL:
        _set_priority(0x00008000)
        file_watcher = Watcher(roots, Handler.caches, args.watch_interval,
                               args.workers, Handler.use_lite, Handler.use_thumb, cache_dir)
        file_watcher.start()
        RootWatcher(Path(__file__).resolve().parent, file_watcher).start()

    total = 0
    for i, r in enumerate(roots):
        try:
            n = sum(1 for p in r.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
        except OSError:
            n = 0
        total += n
        print(f"  目录{i + 1}：{r}    （{n} 个文件）")

    print()
    print("  图片查看器 · 局域网")
    print("  " + "-" * 46)
    print(f"  共 {len(roots)} 个目录，{total} 个文件")
    if HAS_PIL:
        state = "开" if Handler.use_lite else "关"
        print(f"  轻量版：{state}（宽 {LITE_WIDTH}px、最多 {LITE_FRAMES} 帧、质量 {LITE_QUALITY}）")
    else:
        print("  提示：没装 Pillow，缩略图/轻量版不可用")
    print(f"  缓存目录：{cache_dir}")
    print()
    print(f"  手机打开：  http://{ip}:{port}/")
    print(f"  本机打开：  http://127.0.0.1:{port}/")
    print()
    print("  手机和电脑连同一个 Wi-Fi；打不开多半是防火墙拦截。")
    print("  按 Ctrl+C 停止服务。")
    print(flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n  已停止。")
    except Exception:
        import traceback

        try:
            Path(__file__).with_name("crash.log").write_text(
                traceback.format_exc(), encoding="utf-8"
            )
        except Exception:
            pass
        raise
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
