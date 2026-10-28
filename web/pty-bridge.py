#!/usr/bin/env python3
# pty-bridge.py: run one command on a pseudo-terminal and relay it over plain pipes, for the web terminal.
# web/lib/term.mjs (T5) spawns it as `python3 web/pty-bridge.py --cols C --rows R -- agent attach <name>` with
# stdio [pipe, pipe, pipe, pipe]. It exists because node-pty ships no prebuilt Linux binaries and the host has no
# compiler, so this is standard library only (Python 3.10 or later) and needs nothing installed.
#
#   stdin  -> pty      raw bytes, unbuffered (what the browser types)
#   pty    -> stdout   raw bytes, unbuffered (what xterm.js draws)
#   fd 3   -> resize   "<cols> <rows>\n" lines; TIOCSWINSZ on the pty, and the kernel sends SIGWINCH to its
#                      foreground process group. fd 3 may be absent or closed; then the size never changes
#   stderr             the bridge's own errors only; the command's stderr is the pty, so it goes to stdout
#
# The command runs as session leader of a fresh pty of the given size with TERM=xterm-256color, so it is its own
# process group and the pty is its controlling terminal.
# On stdin EOF, SIGTERM, SIGHUP, SIGINT or a closed stdout the bridge sends SIGHUP to that process group (a tmux
# client detaches, and `destroy-unattached` removes the web view), waits up to 2 s, then SIGKILLs the group.
# The exit code is the command's: its status, or 128+signal when a signal killed it.
#
# Backpressure, not loss: a slow reader of stdout makes the bridge stop reading the pty once 64 KiB are queued, so
# the command blocks on its own writes. stdin and the pty work the same way the other way round. Writes to stdout
# go out in chunks of at most PIPE_BUF after select() says it is writable, so a write to a pipe (or the socketpair
# Node uses for one) never blocks and the bridge stays responsive to signals and resizes while the reader is slow. stdin and stdout are left in blocking
# mode because their file descriptions are shared with the parent.
import argparse
import errno
import fcntl
import os
import select
import signal
import struct
import sys
import termios
import time

HIGH_WATER = 64 * 1024
CHUNK = select.PIPE_BUF
GRACE = 2.0          # seconds between SIGHUP and SIGKILL
FLUSH_ON_STOP = 2.0  # seconds to hand remaining output to a reader that is going away


def die(msg):
    sys.stderr.write(f"pty-bridge: {msg}\n")
    sys.exit(2)


def parse_args(argv):
    if "--" not in argv:
        die("usage: pty-bridge.py --cols C --rows R -- <cmd...>")
    i = argv.index("--")
    p = argparse.ArgumentParser(prog="pty-bridge.py")
    p.add_argument("--cols", type=int, default=80)
    p.add_argument("--rows", type=int, default=24)
    opts = p.parse_args(argv[:i])
    cmd = argv[i + 1:]
    if not cmd:
        die("no command after --")
    return clamp(opts.cols, opts.rows), cmd


def clamp(cols, rows):
    return max(1, min(cols, 1000)), max(1, min(rows, 1000))


def winsize(cols, rows):
    return struct.pack("HHHH", rows, cols, 0, 0)


def fd_open(fd):
    try:
        os.fstat(fd)
        return True
    except OSError:
        return False


def spawn(cmd, cols, rows):
    # Size the pty before the fork, so a resize from fd 3 can never be overtaken by the initial size.
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize(cols, rows))
    pid = os.fork()
    if pid == 0:
        # Child: Python ignores SIGPIPE and SIGXFSZ, and ignored signals survive exec, so put them back the way a
        # shell would leave them.
        try:
            os.close(master)
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            for fd in (0, 1, 2):
                os.dup2(slave, fd)
            if slave > 2:
                os.close(slave)
            for sig in (signal.SIGPIPE, signal.SIGXFSZ):
                signal.signal(sig, signal.SIG_DFL)
            env = dict(os.environ, TERM="xterm-256color")
            os.execvpe(cmd[0], cmd, env)
        except OSError as e:
            os.write(2, f"pty-bridge: {cmd[0]}: {e.strerror}\n".encode())
            os._exit(127 if e.errno == errno.ENOENT else 126)
        except BaseException:
            os._exit(126)
    os.close(slave)
    return pid, master


def exit_code(status):
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


class Bridge:
    def __init__(self, cmd, cols, rows):
        # fd 3 belongs to the bridge; the command must not inherit it and keep the server's pipe open.
        self.ctl = 3 if fd_open(3) else None
        if self.ctl is not None:
            os.set_inheritable(3, False)
        self.pid, self.master = spawn(cmd, cols, rows)
        os.set_blocking(self.master, False)
        self.status = None
        self.stdin_open = True
        self.stdout_ok = True
        self.out = bytearray()
        self.to_pty = bytearray()
        self.ctl_buf = b""
        self.stop_at = None     # monotonic deadline for SIGKILL once stopping
        self.stopping_by_request = False
        self.signalled = False
        # Signals only set a flag; the wakeup pipe makes select() return so the loop acts on it.
        self.wake_r, wake_w = os.pipe()
        for fd in (self.wake_r, wake_w):
            os.set_blocking(fd, False)
        signal.set_wakeup_fd(wake_w, warn_on_full_buffer=False)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, self.on_signal)
        signal.signal(signal.SIGCHLD, lambda *_: None)

    def on_signal(self, *_):
        self.signalled = True

    def stop(self):
        if self.stop_at is not None or self.status is not None:
            return
        self.stopping_by_request = True
        self.stop_at = time.monotonic() + GRACE
        self.killpg(signal.SIGHUP)

    def killpg(self, sig):
        try:
            os.killpg(self.pid, sig)
        except ProcessLookupError:
            pass

    def reap(self, block=False):
        if self.status is not None:
            return
        pid, status = os.waitpid(self.pid, 0 if block else os.WNOHANG)
        if pid == self.pid:
            self.status = status

    def close_master(self):
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def read_master(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return False
        except OSError as e:
            # EIO: every slave fd is closed, the command and anything it left on the pty are gone.
            if e.errno != errno.EIO:
                raise
            data = b""
        if not data:
            self.close_master()
            return False
        if self.stdout_ok:
            self.out += data
        return True

    def write_stdout(self):
        try:
            n = os.write(1, self.out[:CHUNK])
        except BrokenPipeError:
            self.stdout_ok = False
            self.out.clear()
            self.stop()
            return
        del self.out[:n]

    def read_stdin(self):
        data = os.read(0, 65536)
        if not data:
            self.stdin_open = False
            self.stop()
        else:
            self.to_pty += data

    def write_master(self):
        try:
            n = os.write(self.master, self.to_pty)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno != errno.EIO:
                raise
            self.to_pty.clear()
            return
        del self.to_pty[:n]

    def read_ctl(self):
        data = os.read(self.ctl, 4096)
        if not data:
            os.close(self.ctl)
            self.ctl = None
            return
        *lines, self.ctl_buf = (self.ctl_buf + data).split(b"\n")
        for line in lines:
            parts = line.split()
            if len(parts) != 2 or not all(p.isdigit() for p in parts):
                continue
            cols, rows = clamp(int(parts[0]), int(parts[1]))
            if self.master is not None:
                fcntl.ioctl(self.master, termios.TIOCSWINSZ, winsize(cols, rows))
        self.ctl_buf = self.ctl_buf[-256:]

    def run(self):
        while True:
            if self.signalled:
                self.signalled = False
                self.stop()
            self.reap()
            if self.status is not None:
                break
            if self.stop_at is not None and time.monotonic() >= self.stop_at:
                self.killpg(signal.SIGKILL)
                self.reap(block=True)
                break

            rl, wl = [self.wake_r], []
            if self.master is not None and len(self.out) < HIGH_WATER:
                rl.append(self.master)
            if self.stdin_open and self.stop_at is None and len(self.to_pty) < HIGH_WATER:
                rl.append(0)
            if self.ctl is not None:
                rl.append(self.ctl)
            if self.out and self.stdout_ok:
                wl.append(1)
            if self.to_pty and self.master is not None:
                wl.append(self.master)
            timeout = 0.1 if self.stop_at is not None or self.master is None else 1.0
            r, w, _ = select.select(rl, wl, [], timeout)

            if self.wake_r in r:
                try:
                    os.read(self.wake_r, 512)
                except BlockingIOError:
                    pass
            if 1 in w:
                self.write_stdout()
            if self.master is not None and self.master in w:
                self.write_master()
            if self.master is not None and self.master in r:
                self.read_master()
            if 0 in r:
                self.read_stdin()
            if self.ctl is not None and self.ctl in r:
                self.read_ctl()

        # The command is gone; what it wrote is still in the pty, readable without blocking.
        while self.master is not None and self.read_master():
            pass
        self.close_master()
        self.flush()
        return exit_code(self.status)

    def flush(self):
        # A reader that asked us to stop gets a bounded flush; one waiting for the command's last screen gets it all,
        # unless a signal says it has stopped waiting.
        deadline = time.monotonic() + FLUSH_ON_STOP if self.stopping_by_request else None
        while self.out and self.stdout_ok and not self.signalled:
            left = None if deadline is None else deadline - time.monotonic()
            if left is not None and left <= 0:
                return
            r, w, _ = select.select([self.wake_r], [1], [], left)
            if 1 in w:
                self.write_stdout()


def main():
    (cols, rows), cmd = parse_args(sys.argv[1:])
    sys.exit(Bridge(cmd, cols, rows).run())


if __name__ == "__main__":
    main()
