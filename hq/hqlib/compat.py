"""What hq needs that Windows spells differently (the pet's Windows shell runs hq there).

On macOS and Linux every name here is the standard one, unchanged: `fcntl` is the fcntl module.
On Windows:
  fcntl.flock   msvcrt's byte lock on the first byte of the file. hq locks only its own .lock
                files, which hold nothing, so the byte stops no reader. A blocking lock waits as
                flock does (msvcrt's own blocking lock gives up after ten seconds); LOCK_NB raises
                BlockingIOError, an OSError, as flock does.
  win_pid_alive asks the process by handle: os.kill(pid, 0) there sends CTRL_C_EVENT (0) to the
                process group, and could interrupt the very session it asks about.
"""
import os

if os.name == "nt":
    import errno
    import msvcrt
    import time

    class _Fcntl:
        LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8

        @staticmethod
        def flock(f, op):
            fd = f if isinstance(f, int) else f.fileno()
            at = os.lseek(fd, 0, os.SEEK_CUR)
            os.lseek(fd, 0, os.SEEK_SET)
            try:
                if op & _Fcntl.LOCK_UN:
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                    return
                while True:
                    try:
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                        return
                    except OSError as e:
                        # Held by another handle; anything else (a bad handle) is raised as is.
                        if e.errno not in (errno.EACCES, errno.EDEADLOCK):
                            raise
                        if op & _Fcntl.LOCK_NB:
                            raise BlockingIOError(errno.EAGAIN, "the lock is held") from None
                        time.sleep(0.01)
            finally:
                os.lseek(fd, at, os.SEEK_SET)

    fcntl = _Fcntl()

    def win_pid_alive(pid):
        try:
            pid = int(pid)
        except (TypeError, ValueError):
            return False
        if pid <= 0:
            return False
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)
        h = k32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            # Access denied: it exists (another user's, or elevated). Anything else: it is gone.
            return ctypes.get_last_error() == 5
        try:
            code = wintypes.DWORD()
            return bool(k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259   # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
else:
    import fcntl  # noqa: F401  (re-exported)
    win_pid_alive = None   # sessions.pid_alive uses os.kill
