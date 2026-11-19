"""Usage: python3 -I tests/pty-run.py <answer>... -- <command> [<arg>...]

Runs a command in a pseudo-terminal, as the owner's terminal or the app's driver would, and types each answer
when the command waits at a prompt (its output ends with ": " and stays quiet). Prints everything the command
wrote and exits with its exit status; 124 when it is still running after 60 seconds.
"""

import os
import pty
import select
import signal
import sys
import time


def main() -> int:
    separator = sys.argv.index("--")
    answers = [answer.encode() for answer in sys.argv[1:separator]]
    command = sys.argv[separator + 1 :]
    pid, master = pty.fork()
    if pid == 0:
        os.execvp(command[0], command)
    output = b""
    answered_at = -1
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.3)
        if ready:
            try:
                data = os.read(master, 4096)
            except OSError:  # Linux reports EIO once the command has exited and closed the terminal.
                break
            if not data:
                break
            output += data
            sys.stdout.buffer.write(data)
            sys.stdout.flush()
            continue
        if answers and output.endswith(b": ") and answered_at != len(output):
            answered_at = len(output)
            os.write(master, answers.pop(0) + b"\n")
    else:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        print("\npty-run: still running after 60 seconds", file=sys.stderr)
        return 124
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
