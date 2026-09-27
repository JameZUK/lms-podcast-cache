#!/usr/bin/env python3
"""Does a long-lived HTTPS download from the bridge host survive going IDLE?

squeeze2upnp reads a CDN stream in bursts and then stalls while the renderer
drains its buffer, so its source socket is idle for long stretches. A steady
`curl --limit-rate` read survived 420s, but the bridge dies after 179-466s
having read only 9-17% of the file. This isolates the one difference: idle gaps.

Two modes:
  steady  - read continuously, rate-limited (the curl control case)
  bursty  - read a chunk fast, then sit idle, repeat (the bridge's pattern)

Reports the exact moment recv() returns 0 (clean close by the far end) or errors.
"""
import socket, ssl, sys, time
from urllib.parse import urlparse

URL = sys.argv[1]
MODE = sys.argv[2] if len(sys.argv) > 2 else "bursty"
IDLE = int(sys.argv[3]) if len(sys.argv) > 3 else 45
BURST = 1 << 20          # read 1 MiB fast, then idle
LIMIT_BPS = 30 * 1024    # steady mode: ~30 KB/s, matching the bridge's average
DEADLINE = 1500          # give up after 25 min

u = urlparse(URL)
host, port = u.hostname, u.port or 443
path = u.path + (("?" + u.query) if u.query else "")

t0 = time.time()
def log(msg):
    print(f"[{time.time()-t0:7.1f}s] {msg}", flush=True)

raw = socket.create_connection((host, port), timeout=30)
peer = raw.getpeername()
ctx = ssl.create_default_context()
s = ctx.wrap_socket(raw, server_hostname=host)
log(f"connected {peer[0]}:{peer[1]}  TLS={s.version()}  mode={MODE} idle={IDLE}s")

# HTTP/1.0 with no Range, exactly as squeeze2upnp does it
req = (f"GET {path} HTTP/1.0\r\nHost: {host}\r\n"
       "User-Agent: iTunes/4.7.1 (Linux; N; Ubuntu; x86_64-linux; EN; utf8)\r\n"
       "Connection: close\r\n\r\n")
s.sendall(req.encode())

total = 0
hdr_done = False
since_burst = 0
last_report = 0.0

while True:
    if time.time() - t0 > DEADLINE:
        log(f"DEADLINE reached, still alive. total={total:,} bytes")
        break
    try:
        chunk = s.recv(32768)
    except ssl.SSLError as e:
        log(f"*** SSLError after {total:,} bytes: {e}")
        break
    except (socket.timeout, TimeoutError) as e:
        log(f"*** timeout after {total:,} bytes: {e}")
        break
    except OSError as e:
        log(f"*** OSError after {total:,} bytes: {e}")
        break

    if not chunk:
        log(f"*** recv()=0 -- far end closed cleanly. total={total:,} bytes "
            f"({total/max(time.time()-t0,1)/1024:.1f} KB/s avg)")
        break

    if not hdr_done:
        head = chunk.split(b"\r\n\r\n", 1)
        log("response: " + head[0].split(b"\r\n")[0].decode(errors="replace"))
        hdr_done = True
        chunk = head[1] if len(head) > 1 else b""

    total += len(chunk)
    since_burst += len(chunk)

    if time.time() - last_report > 30:
        log(f"  {total:,} bytes ({total/max(time.time()-t0,1)/1024:.1f} KB/s avg)")
        last_report = time.time()

    if MODE == "bursty":
        if since_burst >= BURST:
            log(f"  buffer full at {total:,} bytes -> going idle {IDLE}s (not reading)")
            time.sleep(IDLE)
            since_burst = 0
    else:
        time.sleep(len(chunk) / LIMIT_BPS)

s.close()
log("done")
