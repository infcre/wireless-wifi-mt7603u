#!/usr/bin/env python3
"""Tiny fixed-length TCP throughput peer.

Used to measure the MT7603U STA link without iperf3.

The listener always runs on the Debian side, bound to the STA address, so the
Windows peer only ever makes *outbound* connections (no Windows firewall rule
needed):

    serve --mode sink    <- client sends  -> measures STA receive (RX)
    serve --mode source  <- server sends  -> measures STA transmit (TX)

Usage:
    netpeer.py serve  --bind IP --port P --mode sink|source [--bytes N] [--seconds S]
    netpeer.py client --target IP --port P --mode send|recv [--bytes N] [--seconds S] [--bind IP]
"""

import argparse
import socket
import sys
import time

CHUNK = 1 << 20


def setup(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    for opt in (socket.SO_SNDBUF, socket.SO_RCVBUF):
        try:
            sock.setsockopt(socket.SOL_SOCKET, opt, 4 << 20)
        except OSError:
            pass
    return sock


def report(role, mode, nbytes, seconds):
    mbps = nbytes * 8 / seconds / 1e6 if seconds > 0 else 0.0
    print(
        "RESULT role=%s mode=%s bytes=%d seconds=%.3f mbps=%.1f"
        % (role, mode, nbytes, seconds, mbps),
        flush=True,
    )


def drain(sock, nbytes, seconds):
    """Receive until nbytes (if given) or seconds (if given) is reached."""
    total = 0
    t0 = time.time()
    while True:
        if nbytes and total >= nbytes:
            break
        if seconds and time.time() - t0 >= seconds:
            break
        data = sock.recv(CHUNK)
        if not data:
            break
        total += len(data)
    return total, time.time() - t0


def pump(sock, nbytes, seconds):
    """Send until nbytes (if given) or seconds (if given) is reached."""
    buf = b"\xa5" * CHUNK
    total = 0
    t0 = time.time()
    try:
        while True:
            if nbytes and total >= nbytes:
                break
            if seconds and time.time() - t0 >= seconds:
                break
            want = CHUNK
            if nbytes:
                want = min(CHUNK, nbytes - total)
            sock.sendall(buf[:want])
            total += want
        sock.shutdown(socket.SHUT_WR)
    except (BrokenPipeError, ConnectionResetError):
        pass
    return total, time.time() - t0


def do_serve(a):
    srv = setup(socket.socket())
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port))
    srv.listen(1)
    print("listening %s:%d mode=%s" % (a.bind, a.port, a.mode), flush=True)
    conn, peer = srv.accept()
    print("accepted %s:%d" % peer, flush=True)
    setup(conn)
    if a.mode == "sink":
        total, dt = drain(conn, a.bytes, a.seconds)
    else:
        total, dt = pump(conn, a.bytes, a.seconds)
    report("server", a.mode, total, dt)
    conn.close()
    srv.close()


def do_client(a):
    sock = setup(socket.socket())
    if a.bind:
        sock.bind((a.bind, 0))
    t0 = time.time()
    sock.connect((a.target, a.port))
    print("connected in %.3fs" % (time.time() - t0), flush=True)
    if a.mode == "send":
        total, dt = pump(sock, a.bytes, a.seconds)
    else:
        total, dt = drain(sock, a.bytes, a.seconds)
    report("client", a.mode, total, dt)
    sock.close()


def do_udp_serve(a):
    """UDP sink/source: shows the raw one-way radio capability, without TCP
    retransmission masking a lossy link."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    except OSError:
        pass
    srv.bind((a.bind, a.port))
    print("udp listening %s:%d mode=%s" % (a.bind, a.port, a.mode), flush=True)

    if a.mode == "sink":
        total = 0
        t0 = time.time()
        srv.settimeout(2.0)
        while time.time() - t0 < a.seconds:
            try:
                data, _ = srv.recvfrom(65535)
            except socket.timeout:
                continue
            total += len(data)
        report("udp-server", "sink", total, time.time() - t0)
    else:
        # learn the client address from a hello datagram, then blast
        srv.settimeout(30.0)
        _, peer = srv.recvfrom(2048)
        print("udp peer %s:%d" % peer, flush=True)
        buf = b"\xa5" * 1400
        total = 0
        t0 = time.time()
        while time.time() - t0 < a.seconds:
            srv.sendto(buf, peer)
            total += len(buf)
        report("udp-server", "source", total, time.time() - t0)
    srv.close()


def do_udp_client(a):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
    except OSError:
        pass
    if a.bind:
        sock.bind((a.bind, 0))
    if a.mode == "send":
        sock.sendto(b"hello", (a.target, a.port))
        buf = b"\xa5" * 1400
        total = 0
        t0 = time.time()
        while time.time() - t0 < a.seconds:
            sock.sendto(buf, (a.target, a.port))
            total += len(buf)
        report("udp-client", "send", total, time.time() - t0)
    else:
        sock.sendto(b"hello", (a.target, a.port))
        sock.settimeout(3.0)
        total = 0
        t0 = time.time()
        while time.time() - t0 < a.seconds:
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            total += len(data)
        report("udp-client", "recv", total, time.time() - t0)
    sock.close()


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="role", required=True)

    s = sub.add_parser("serve")
    s.add_argument("--bind", default="0.0.0.0")
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--mode", choices=["sink", "source"], required=True)
    s.add_argument("--bytes", type=int, default=0)
    s.add_argument("--seconds", type=float, default=0)
    s.add_argument("--udp", action="store_true")
    s.set_defaults(func=do_serve)

    c = sub.add_parser("client")
    c.add_argument("--target", required=True)
    c.add_argument("--port", type=int, required=True)
    c.add_argument("--mode", choices=["send", "recv"], required=True)
    c.add_argument("--bytes", type=int, default=0)
    c.add_argument("--seconds", type=float, default=0)
    c.add_argument("--bind", default=None)
    c.add_argument("--udp", action="store_true")
    c.set_defaults(func=do_client)

    a = p.parse_args()
    if a.udp:
        a.func = do_udp_serve if a.role == "serve" else do_udp_client
    if not a.bytes and not a.seconds:
        a.bytes = 100 * 1000 * 1000
    a.func(a)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)