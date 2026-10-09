#!/usr/bin/env python3
"""Announce a published BerryDB release on a Telegram channel and a Facebook Page.

Run by .github/workflows/announce-release.yml, in two modes:

  --preview   Read the release and print the exact message each channel would
              receive, as Markdown. Posts nothing, needs no channel secrets, and
              with --summary-file also appends the same Markdown to the Actions
              job summary.
  (default)   Read the release again and post to every configured channel.

The release is read from the GitHub API at the moment of use, so an edit to the
release notes between the preview and the post changes what is posted.

A channel is configured when BOTH of its variables are set: TELEGRAM_BOT_TOKEN
with TELEGRAM_CHAT_ID, and FACEBOOK_PAGE_ID with FACEBOOK_PAGE_ACCESS_TOKEN.
One of a pair without the other is a misconfiguration and fails the run before
anything is posted. No channel configured is a notice and a clean exit.

Every secret arrives through the environment and never through argv, which
`ps` would show. Telegram's Bot API puts the bot token in the request path, so
no URL is ever printed and every error text is scrubbed of the secrets in play.
Standard library only; the HTTP opener is injectable so the tests never touch a
network.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Callable, Mapping, NamedTuple, Optional, Sequence, TextIO

GITHUB_API = "https://api.github.com"
TELEGRAM_API = "https://api.telegram.org"
GRAPH_API = "https://graph.facebook.com"

# One place to change when Meta retires a Graph API version. The Pages API
# documentation's own examples post to this version:
# https://developers.facebook.com/docs/pages-api/posts
GRAPH_API_VERSION = "v25.0"

# sendMessage's `text` is "1-4096 characters after entities parsing":
# https://core.telegram.org/bots/api#sendmessage
TELEGRAM_MAX_CHARS = 4096

# The channels an announcement can go to, in the order they are shown and posted.
CHANNELS = ("telegram", "facebook")

ELLIPSIS = "…"
REQUEST_TIMEOUT = 30  # seconds, per request

Opener = Callable[..., object]


class Release(NamedTuple):
    name: str
    body: str  # already plain text
    url: str


class ConfigError(Exception):
    """The environment or arguments are unusable. Never carries a secret value."""


class RequestError(Exception):
    """An HTTP call failed. The text is already scrubbed of secrets."""


# ---------------------------------------------------------------------------
# Message building
# ---------------------------------------------------------------------------

_FENCE = re.compile(r"^\s*(?:`{3,}|~{3,})")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)(?:\s+#+)?\s*$")
_RULE = re.compile(r"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$")
_BULLET = re.compile(r"^(\s*)[*+-]\s+")
_LINK = re.compile(r'!?\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
_BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
_CODE_SPAN = re.compile(r"(`[^`]*`)")


def _link_text(match: re.Match) -> str:
    text, target = match.group(1), match.group(2)
    return target if not text or text == target else f"{text} ({target})"


def _inline(line: str) -> str:
    # Code spans are split out first so that `snake_case` or `**x**` inside
    # one is shown as written, not interpreted.
    parts = _CODE_SPAN.split(line)
    for i, part in enumerate(parts):
        if i % 2:
            parts[i] = part[1:-1]
        else:
            parts[i] = _BOLD.sub(r"\1", _LINK.sub(_link_text, part))
    return "".join(parts)


def markdown_to_text(markdown: str) -> str:
    """Release notes as plain text for channels that do not render Markdown.

    Headings lose their `#`, list items become bullets, `**bold**` loses its
    markers, links become `text (url)`, fences and inline-code backticks go,
    and every URL survives. Only `**` is treated as bold: `_` and a lone `*`
    appear in identifiers and arithmetic and are left alone.
    """
    lines: list[str] = []
    in_fence = False
    for raw in markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw.rstrip()
        if _FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            lines.append(line)
        elif _RULE.match(line):
            lines.append("")
        else:
            heading = _HEADING.match(line)
            if heading:
                line = heading.group(1)
            else:
                line = _BULLET.sub(lambda m: m.group(1) + "• ", line)
            lines.append(_inline(line))
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


# The lines GitHub's note generator adds. Observed in this repository's releases
# v1.0.3, v1.0.4, v1.0.7 and v1.0.8; GitHub documents only that generated notes
# list merged pull requests, contributors and a link to the full changelog:
# https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes
#   * <pull request title> by @<author> in https://github.com/<owner>/<repo>/pull/<n>
#   * @<author> made their first contribution in https://github.com/<owner>/<repo>/pull/<n>
#   **Full Changelog**: https://github.com/<owner>/<repo>/compare/<tag>...<tag>
# plus the "## New Contributors" heading over the second kind. Each pattern is
# anchored to the whole line and to this repository's own URLs, so a hand-written
# sentence that merely mentions "by @someone", or a link to another repository's
# pull request, is left alone.
_NEW_CONTRIBUTORS_HEADING = re.compile(r"^## New Contributors\s*$")


def strip_generated_boilerplate(markdown: str, repo: str) -> str:
    """Release notes without GitHub's generated bookkeeping, which reads badly in
    an announcement: the attribution suffix of each entry (its title is kept),
    the first-contribution bullets, the "New Contributors" heading once nothing
    is left under it, and the changelog line."""
    slug = re.escape(repo)
    attribution = re.compile(rf"^(\s*[*+-]\s+.+?)\s+by @[\w-]+(?:\[bot\])? in https://github\.com/{slug}/pull/\d+\s*$")
    contribution = re.compile(rf"^\s*[*+-]\s+@[\w-]+(?:\[bot\])? made their first contribution in https://github\.com/{slug}/pull/\d+\s*$")
    changelog = re.compile(rf"^\*\*Full Changelog\*\*: https://github\.com/{slug}/compare/\S+\s*$")
    # A body edited in the web UI comes back with CRLF line ends.
    lines = [
        attribution.sub(r"\1", line)
        for line in markdown.replace("\r\n", "\n").split("\n")
        if not (changelog.match(line) or contribution.match(line))
    ]
    kept, i = [], 0
    while i < len(lines):
        if _NEW_CONTRIBUTORS_HEADING.match(lines[i]):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("#")), len(lines))
            if not any(line.strip() for line in lines[i + 1 : end]):
                i = end
                continue
        kept.append(lines[i])
        i += 1
    return "\n".join(kept)


def utf16_length(text: str) -> int:
    """Length in UTF-16 code units, the unit the Bot API uses for message entity
    offsets. The documentation says "characters" for the 4096 limit without
    naming a unit, so the limit is applied in the stricter one: an astral
    character such as an emoji counts twice, and a message can only come out a
    little shorter than the limit allows, never over it."""
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def _prefix(text: str, units: int) -> str:
    used = 0
    for index, char in enumerate(text):
        used += 2 if ord(char) > 0xFFFF else 1
        if used > units:
            return text[:index]
    return text


def _truncate(text: str, units: int) -> str:
    """`text` cut to at most `units` UTF-16 units including a trailing ellipsis,
    ending on a word boundary so a URL is dropped whole rather than cut."""
    if utf16_length(text) <= units:
        return text
    cut = _prefix(text, units - utf16_length(ELLIPSIS))
    if not text[len(cut)].isspace():
        boundary = max(cut.rfind(" "), cut.rfind("\n"))
        if boundary > 0:
            cut = cut[:boundary]
    return cut.rstrip() + ELLIPSIS


def _full_message(name: str, body: str, url: str) -> str:
    return f"{name}\n\n{body}\n\n{url}" if body else f"{name}\n\n{url}"


def build_message(name: str, body: str, url: str, limit: int) -> str:
    """name, blank line, body, blank line, release page URL. Over `limit` UTF-16
    units, the body is shortened; the URL is last and is never touched. Only a
    name too long to leave room for the URL is shortened as well."""
    full = _full_message(name, body, url)
    if utf16_length(full) <= limit:
        return full
    head = f"{name}\n\n"
    tail = f"\n\n{url}"
    room = limit - utf16_length(head) - utf16_length(tail)
    if body and room > utf16_length(ELLIPSIS):
        return head + _truncate(body, room) + tail
    return _truncate(name, limit - utf16_length(tail)) + tail


def telegram_text(release: Release) -> str:
    return build_message(release.name, release.body, release.url, TELEGRAM_MAX_CHARS)


def facebook_message(release: Release) -> str:
    """No URL in the text: the post's `link` field attaches the release page."""
    return f"{release.name}\n\n{release.body}" if release.body else release.name


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _pair(env: Mapping[str, str], first: str, second: str) -> Optional[tuple[str, str]]:
    # Actions exposes a secret that does not exist as an empty string, and a
    # pasted secret often carries a trailing newline, which would put a control
    # character into a request URL.
    a, b = env.get(first, "").strip(), env.get(second, "").strip()
    if a and b:
        return a, b
    if a or b:
        missing = second if a else first
        raise ConfigError(f"{first} and {second} must be set together, but {missing} is empty or missing")
    return None


def telegram_config(env: Mapping[str, str]) -> Optional[tuple[str, str]]:
    """(bot token, chat id), or None when the channel is not configured."""
    return _pair(env, "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID")


def facebook_config(env: Mapping[str, str]) -> Optional[tuple[str, str]]:
    """(page id, page access token), or None when the channel is not configured."""
    return _pair(env, "FACEBOOK_PAGE_ID", "FACEBOOK_PAGE_ACCESS_TOKEN")


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """urllib re-sends the request headers, Authorization included, to a redirect
    target (observed with CPython 3.14 against a loopback server), and a Telegram
    URL carries the bot token in its path. Every endpoint used here answers
    directly, so a redirect is an error, never something to follow."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def default_opener() -> Opener:
    return urllib.request.build_opener(_NoRedirect).open


def _scrub(text: str, secrets: Sequence[str]) -> str:
    for secret in sorted(filter(None, secrets), key=len, reverse=True):
        for form in (secret, urllib.parse.quote(secret, safe="")):
            text = text.replace(form, "***")
    return text


def _error_detail(raw: bytes) -> str:
    """The error text a service put in a failure body: Telegram's `description`,
    Graph's `error.message` or GitHub's `message`, else the body itself."""
    text = raw.decode("utf-8", "replace").strip()
    try:
        data = json.loads(text)
    except ValueError:
        return text
    if isinstance(data, dict):
        error = data.get("error")
        for candidate in (data.get("description"), error.get("message") if isinstance(error, dict) else None, data.get("message")):
            if isinstance(candidate, str) and candidate:
                return candidate
    return text


def _send(opener: Opener, request: urllib.request.Request, secrets: Sequence[str]) -> dict:
    """Perform a request and return its JSON object. Any failure becomes a
    RequestError whose text has had every secret removed: an exception raised
    inside urllib or http.client can quote the full request URL, which holds the
    Telegram token, and `from None` drops the chained original for the same
    reason."""
    try:
        with opener(request, timeout=REQUEST_TIMEOUT) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        with exc:  # closes the response; the script would otherwise hold its socket until exit
            raw_body = exc.read(2000)
        # Scrub before shortening, or a secret straddling the cut would survive.
        detail = _scrub(_error_detail(raw_body), secrets)[:300]
        raise RequestError(f"HTTP {exc.code}: {detail}") from None
    except Exception as exc:  # noqa: BLE001 - any failure must be scrubbed, not raised raw
        raise RequestError(_scrub(f"{type(exc).__name__}: {exc}", secrets)) from None
    try:
        data = json.loads(raw)
    except ValueError:
        raise RequestError("the response was not JSON") from None
    if not isinstance(data, dict):
        raise RequestError("the response was not a JSON object")
    return data


def _form_post(url: str, fields: Mapping[str, str]) -> urllib.request.Request:
    return urllib.request.Request(
        url,
        data=urllib.parse.urlencode(fields).encode(),
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )


def fetch_release(repo: str, tag: str, token: str, opener: Opener) -> Release:
    # The tag endpoint returns published releases only, so a draft is never
    # announced: https://docs.github.com/en/rest/releases/releases#get-a-release-by-tag-name
    request = urllib.request.Request(
        f"{GITHUB_API}/repos/{urllib.parse.quote(repo, safe='/')}/releases/tags/{urllib.parse.quote(tag, safe='')}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "berrydb-announce-release",
        },
    )
    data = _send(opener, request, [token])
    url = data.get("html_url")
    if not isinstance(url, str) or not url:
        raise RequestError("the release has no html_url")
    return Release(
        name=data.get("name") or data.get("tag_name") or tag,
        body=markdown_to_text(strip_generated_boilerplate(data.get("body") or "", repo)),
        url=url,
    )


def post_telegram(opener: Opener, token: str, chat_id: str, text: str, preview_url: str) -> str:
    """No `parse_mode`: release text goes out as plain text, so a stray `_` or
    `*` in the notes can never make Telegram's Markdown parser reject it.

    `link_preview_options` is a JSON-serialized LinkPreviewOptions object. Its
    `url` is "URL to use for the link preview. If empty, then the first URL found
    in the message text will be used", and the first URL in hand-written notes is
    rarely the release page: https://core.telegram.org/bots/api#linkpreviewoptions
    """
    fields = {
        "chat_id": chat_id,
        "text": text,
        "link_preview_options": json.dumps({"url": preview_url}, separators=(",", ":")),
    }
    request = _form_post(f"{TELEGRAM_API}/bot{token}/sendMessage", fields)
    data = _send(opener, request, [token])
    if data.get("ok") is not True:
        raise RequestError(_scrub(f"Telegram refused the message: {data.get('description', 'no description')}", [token]))
    result = data.get("result")
    message_id = result.get("message_id") if isinstance(result, dict) else None
    return f"message {message_id} sent" if message_id is not None else "message sent"


def post_facebook(opener: Opener, page_id: str, access_token: str, message: str, link: str) -> str:
    """POST /{page-id}/feed with `message` and `link`, as the Pages API
    documents (https://developers.facebook.com/docs/pages-api/posts). The access
    token is a form field in the body, so it never appears in a URL."""
    url = f"{GRAPH_API}/{GRAPH_API_VERSION}/{urllib.parse.quote(page_id, safe='')}/feed"
    request = _form_post(url, {"message": message, "link": link, "access_token": access_token})
    data = _send(opener, request, [access_token])
    post_id = data.get("id")
    if not post_id:
        raise RequestError("Facebook answered without a post id")
    return f"post {post_id} published"


# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------


def _fence(text: str) -> str:
    """`text` in a Markdown code fence longer than any run of backticks inside it."""
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    ticks = "`" * max(3, longest + 1)
    return f"{ticks}\n{text}\n{ticks}"


def _telegram_note(release: Release) -> str:
    text = telegram_text(release)
    over = utf16_length(_full_message(release.name, release.body, release.url)) > TELEGRAM_MAX_CHARS
    return f"{utf16_length(text)} of {TELEGRAM_MAX_CHARS} characters, {'body truncated to fit' if over else 'fits'}"


def render_summary(release: Release, channels: Sequence[str] = CHANNELS) -> str:
    parts = [
        f"## Release announcement preview\n\n"
        f"**{release.name}**: {release.url}\n\n"
        f"Nothing has been posted. In the workflow, the post job waits for approval in the "
        f"`release-announcement` environment and reads the release notes again, so an "
        f"edit made before approving is what gets posted.\n"
    ]
    if "telegram" in channels:
        parts.append(
            f"### Telegram\n\n{_telegram_note(release)}\n\n{_fence(telegram_text(release))}\n\n"
            f"link preview: {release.url}\n"
        )
    if "facebook" in channels:
        parts.append(
            f"### Facebook Page\n\nThe release page is attached as the post's link.\n\n"
            f"link: {release.url}\n\n{_fence(facebook_message(release))}\n"
        )
    return "\n".join(parts)


def _inert(text: str) -> str:
    """`text` between stop-commands markers. The Actions runner executes a
    workflow command (`::warning::`, `::add-mask::`, ...) found at the start of
    a stdout line, and release notes are free text. GitHub requires the end
    token to be random and unique to each run:
    https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#stopping-and-starting-workflow-commands
    """
    token = uuid.uuid4().hex
    return f"::stop-commands::{token}\n{text.rstrip()}\n::{token}::"


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_channels(value: str) -> tuple[str, ...]:
    """A comma-separated channel list, as the --only option and the manual
    workflow input take it, in canonical order without duplicates."""
    names = [name.strip().lower() for name in value.split(",") if name.strip()]
    unknown = [name for name in names if name not in CHANNELS]
    if not names or unknown:
        shown = ", ".join(unknown) if unknown else repr(value)
        raise argparse.ArgumentTypeError(f"unknown or empty channel selection {shown}; choose from {', '.join(CHANNELS)}")
    return tuple(channel for channel in CHANNELS if channel in names)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Announce a published release on Telegram and a Facebook Page.")
    parser.add_argument("--tag", required=True, help="release tag including the leading v, e.g. v1.0.8")
    parser.add_argument("--preview", action="store_true", help="print the messages and post nothing")
    parser.add_argument(
        "--only",
        type=parse_channels,
        default=CHANNELS,
        help="comma-separated channels to preview or post to (default: telegram,facebook); a retry after a "
        "partial failure names the channel that failed",
    )
    parser.add_argument("--summary-file", help="with --preview, append a Markdown version here (the Actions job summary)")
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    environ: Optional[Mapping[str, str]] = None,
    opener: Optional[Opener] = None,
    stdout: Optional[TextIO] = None,
    stderr: Optional[TextIO] = None,
) -> int:
    args = _parser().parse_args(argv)
    env = os.environ if environ is None else environ
    opener = opener or default_opener()
    out, err = stdout or sys.stdout, stderr or sys.stderr

    token, repo = env.get("GH_TOKEN", "").strip(), env.get("GITHUB_REPOSITORY", "").strip()
    absent = [name for name, value in (("GH_TOKEN", token), ("GITHUB_REPOSITORY", repo)) if not value]
    if absent:
        print(f"✗ Missing required env: {', '.join(absent)}", file=err)
        return 2

    if args.preview:
        try:
            release = fetch_release(repo, args.tag, token, opener)
        except (ConfigError, RequestError) as exc:
            print(f"✗ {exc}", file=err)
            return 1
        print(_inert(render_summary(release, args.only)), file=out)
        if args.summary_file:
            with open(args.summary_file, "a", encoding="utf-8") as summary:
                summary.write(render_summary(release, args.only))
        return 0

    # Configuration of the selected channels is checked in full before anything
    # is posted: a retry after fixing a half-set pair must not repost the channel
    # that was fine. A channel that was not selected is not looked at, so a retry
    # of one channel is never blocked by another's configuration.
    try:
        telegram = telegram_config(env) if "telegram" in args.only else None
        facebook = facebook_config(env) if "facebook" in args.only else None
    except ConfigError as exc:
        print(f"✗ {exc}", file=err)
        return 1
    if not telegram and not facebook:
        print(f"• No announcement channel is configured for {', '.join(args.only)} (no complete secret pair); nothing to post.", file=out)
        return 0

    try:
        release = fetch_release(repo, args.tag, token, opener)
    except (ConfigError, RequestError) as exc:
        print(f"✗ {exc}", file=err)
        return 1

    failed = 0
    if telegram:
        print("▸ Posting to Telegram", file=out)
        try:
            print(f"✓ Telegram: {post_telegram(opener, *telegram, telegram_text(release), release.url)}", file=out)
        except RequestError as exc:
            print(f"✗ Telegram: {exc}", file=err)
            failed += 1
    if facebook:
        print("▸ Posting to the Facebook Page", file=out)
        try:
            print(f"✓ Facebook: {post_facebook(opener, *facebook, facebook_message(release), release.url)}", file=out)
        except RequestError as exc:
            print(f"✗ Facebook: {exc}", file=err)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
