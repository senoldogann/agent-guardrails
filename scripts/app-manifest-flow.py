"""Registers a GitHub App from a manifest through the browser and prints the one-time code GitHub returns.

Usage: python3 -I scripts/app-manifest-flow.py <manifest-json> <registration-url>

The registration URL is https://github.com/settings/apps/new for a personal account or
https://github.com/organizations/<org>/settings/apps/new for an organization. The script listens on a free
port on 127.0.0.1, opens a local page that posts the manifest (with that port as the redirect URL) to GitHub,
and waits up to ten minutes for GitHub to redirect back with ?code=...&state=.... The code is printed on
stdout; everything else goes to stderr. Only the standard library is used.
"""

import html
import http.server
import json
import secrets
import sys
import urllib.parse
import webbrowser
from dataclasses import dataclass


@dataclass(frozen=True)
class FlowResult:
    code: str


class ManifestFlowError(Exception):
    """The registration did not complete: timeout, wrong state, or GitHub reported an error."""


def form_page(manifest: str, registration_url: str, state: str) -> str:
    action = f"{registration_url}?state={urllib.parse.quote(state)}"
    return (
        "<!doctype html><meta charset=utf-8><title>Register the agent App</title>"
        "<body onload='document.forms[0].submit()'>"
        f"<form method=post action='{html.escape(action, quote=True)}'>"
        f"<input type=hidden name=manifest value='{html.escape(manifest, quote=True)}'>"
        "<noscript><button>Continue to GitHub</button></noscript></form>"
    )


def run_flow(manifest_template: str, registration_url: str) -> FlowResult:
    state = secrets.token_urlsafe(24)
    received: list[str] = []
    errors: list[str] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (name required by BaseHTTPRequestHandler)
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path == "/":
                self.respond(200, form_page(manifest, registration_url, state))
                return
            if url.path != "/callback":
                self.respond(404, "Not found")
                return
            if query.get("state", [""])[0] != state:
                errors.append("the callback carried a different state; ignoring it")
                self.respond(400, "State mismatch. Close this tab and run the command again.")
                return
            code = query.get("code", [""])[0]
            if not code:
                errors.append(f"GitHub returned no code: {url.query}")
                self.respond(400, "GitHub returned no code. Close this tab and run the command again.")
                return
            received.append(code)
            self.respond(200, "The agent App is registered. You can close this tab and return to the terminal.")

        def respond(self, status: int, text: str) -> None:
            body = text.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 (signature of the base class)
            return

    class Server(http.server.HTTPServer):
        def handle_timeout(self) -> None:
            errors.append("timed out after ten minutes waiting for GitHub")

    server = Server(("127.0.0.1", 0), Handler)
    server.timeout = 600
    port = server.server_address[1]
    manifest_object = json.loads(manifest_template)
    manifest_object["redirect_url"] = f"http://127.0.0.1:{port}/callback"
    manifest = json.dumps(manifest_object)
    start = f"http://127.0.0.1:{port}/"
    print(f"Opening {start} in your browser; it continues to GitHub to create the App.", file=sys.stderr)
    webbrowser.open(start)
    try:
        while not received:
            server.handle_request()
            if errors:
                raise ManifestFlowError(errors[-1])
    finally:
        server.server_close()
    return FlowResult(code=received[0])


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("usage: app-manifest-flow.py <manifest-json> <registration-url>", file=sys.stderr)
        return 2
    try:
        result = run_flow(arguments[0], arguments[1])
    except ManifestFlowError as error:
        print(f"error: the App registration did not complete: {error}", file=sys.stderr)
        return 1
    print(result.code)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
