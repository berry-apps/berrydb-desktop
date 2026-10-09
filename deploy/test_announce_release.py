#!/usr/bin/env python3
"""Tests for deploy/announce-release.py. Standard library only: no network, no
real credentials. Every HTTP call goes through an injected opener (FakeOpener),
so nothing here can post anywhere.

Run: python3 -m unittest deploy/test_announce_release.py

The hyphen in the script's file name makes it unimportable by name, so it is
loaded by path, the same way test_upload_release.py loads upload-release.py.
"""
import argparse
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
import urllib.request
from http.client import InvalidURL
from urllib.parse import parse_qs, quote, urlsplit

HERE = pathlib.Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location("announce_release", HERE / "announce-release.py")
announce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(announce)

REPO = "berry-apps/berrydb-desktop"
TAG = "v1.0.8"
RELEASE_URL = f"https://github.com/{REPO}/releases/tag/{TAG}"

# The body GitHub generated for v1.0.8, byte for byte as the API returned it.
GENERATED_BODY = (
    "## What's Changed\n"
    "* feat: preserve schema qualifiers and add adaptive tree view for multi-schema "
    "databases by @quangtaned in https://github.com/berry-apps/berrydb-desktop/pull/23\n"
    "\n"
    "\n"
    "**Full Changelog**: https://github.com/berry-apps/berrydb-desktop/compare/v1.0.7...v1.0.8"
)
# What a reader should see of it once GitHub's generated boilerplate is gone.
ANNOUNCED_BODY = (
    "What's Changed\n"
    "• feat: preserve schema qualifiers and add adaptive tree view for multi-schema databases"
)
RELEASE_JSON = {
    "name": "BerryDB 1.0.8",
    "tag_name": TAG,
    "html_url": RELEASE_URL,
    "body": GENERATED_BODY,
    "draft": False,
    "prerelease": False,
}

# Deliberately distinctive, and containing characters that urlencode changes, so
# a leak shows up whichever form it takes.
BOT_TOKEN = "123456789:AAH-secret_telegram+token/xyz"
CHAT_ID = "@berrydb_updates"
PAGE_ID = "104500000000001"
PAGE_TOKEN = "EAAB-secret-page-token-0123456789"
GH_TOKEN = "ghs_secret_github_token_0123456789"

BASE_ENV = {"GH_TOKEN": GH_TOKEN, "GITHUB_REPOSITORY": REPO}
TELEGRAM_ENV = {"TELEGRAM_BOT_TOKEN": BOT_TOKEN, "TELEGRAM_CHAT_ID": CHAT_ID}
FACEBOOK_ENV = {"FACEBOOK_PAGE_ID": PAGE_ID, "FACEBOOK_PAGE_ACCESS_TOKEN": PAGE_TOKEN}
SECRETS = (BOT_TOKEN, PAGE_TOKEN, GH_TOKEN)


class FakeResponse:
    """What urllib's opener returns: a context manager with read()."""

    def __init__(self, body, status=200):
        self._body = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.status = status

    def read(self, *_):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


class Sent:
    def __init__(self, request):
        self.method = request.get_method()
        self.url = request.full_url
        self.headers = {k.lower(): v for k, v in request.header_items()}
        self.data = request.data
        self.host = urlsplit(self.url).netloc

    def form(self):
        return {k: v[0] for k, v in parse_qs(self.data.decode(), keep_blank_values=True).items()}


class FakeOpener:
    """Routes by host. A route is a response body (dict), a FakeResponse, an
    exception to raise, or a callable taking the Sent request."""

    def __init__(self, release=None, telegram=None, facebook=None):
        self.requests = []
        self.routes = {
            "api.github.com": release if release is not None else RELEASE_JSON,
            "api.telegram.org": telegram if telegram is not None else {"ok": True, "result": {"message_id": 77}},
            "graph.facebook.com": facebook if facebook is not None else {"id": f"{PAGE_ID}_5550001"},
        }

    def __call__(self, request, timeout=None):
        sent = Sent(request)
        self.requests.append(sent)
        route = self.routes[sent.host]
        if callable(route):
            route = route(sent)
        if isinstance(route, Exception):
            raise route
        return route if isinstance(route, FakeResponse) else FakeResponse(route)

    def to(self, host):
        return [r for r in self.requests if r.host == host]

    def posts(self):
        return [r for r in self.requests if r.method == "POST"]


def http_error(url, code, body):
    return urllib.error.HTTPError(url, code, "error", {}, io.BytesIO(body if isinstance(body, bytes) else json.dumps(body).encode()))


def units(text):
    """UTF-16 code units, measured here independently of the code under test."""
    return len(text.encode("utf-16-le")) // 2


def run_main(argv, env, opener):
    out, err = io.StringIO(), io.StringIO()
    code = announce.main(argv, environ=env, opener=opener, stdout=out, stderr=err)
    return code, out.getvalue(), err.getvalue()


class MarkdownToTextTests(unittest.TestCase):
    def test_heading_loses_its_hashes(self):
        self.assertEqual(announce.markdown_to_text("## What's Changed"), "What's Changed")
        self.assertEqual(announce.markdown_to_text("# One\n###### Six ##"), "One\nSix")

    def test_list_markers_become_bullets(self):
        text = announce.markdown_to_text("* star\n- dash\n+ plus\n  * nested")
        self.assertEqual(text, "• star\n• dash\n• plus\n  • nested")

    def test_numbered_lists_and_arithmetic_are_left_alone(self):
        text = announce.markdown_to_text("1. first\n2. second\nuses 2 * 3 = 6")
        self.assertEqual(text, "1. first\n2. second\nuses 2 * 3 = 6")

    def test_bold_markers_are_removed(self):
        text = announce.markdown_to_text("**Full Changelog**: done, and **two** words")
        self.assertEqual(text, "Full Changelog: done, and two words")

    def test_bare_urls_survive_untouched(self):
        url = "https://github.com/berry-apps/berrydb-desktop/compare/v1.0.7...v1.0.8?a=b_c*d"
        self.assertEqual(announce.markdown_to_text(f"see {url}"), f"see {url}")

    def test_link_keeps_its_target(self):
        text = announce.markdown_to_text("read [the notes](https://example.com/notes) first")
        self.assertEqual(text, "read the notes (https://example.com/notes) first")

    def test_link_whose_text_is_the_url_is_not_doubled(self):
        text = announce.markdown_to_text("[https://example.com/x](https://example.com/x)")
        self.assertEqual(text, "https://example.com/x")

    def test_fenced_code_keeps_its_content_verbatim(self):
        md = "Run:\n```sh\n# a comment, not a heading\n* not a bullet\n**not bold**\n```\nDone"
        self.assertEqual(
            announce.markdown_to_text(md),
            "Run:\n# a comment, not a heading\n* not a bullet\n**not bold**\nDone",
        )

    def test_inline_code_loses_backticks_and_keeps_content(self):
        text = announce.markdown_to_text("set `snake_case_name` and `**x**`")
        self.assertEqual(text, "set snake_case_name and **x**")

    def test_horizontal_rules_are_dropped(self):
        # A rule is a paragraph break in plain text.
        self.assertEqual(announce.markdown_to_text("a\n\n---\n\nb\n***\nc"), "a\n\nb\n\nc")

    def test_crlf_and_blank_runs_are_normalised(self):
        self.assertEqual(announce.markdown_to_text("a\r\n\r\n\r\n\r\nb  \r\n"), "a\n\nb")

    def test_generated_release_notes_end_to_end(self):
        self.assertEqual(
            announce.markdown_to_text(GENERATED_BODY),
            "What's Changed\n"
            "• feat: preserve schema qualifiers and add adaptive tree view for multi-schema "
            "databases by @quangtaned in https://github.com/berry-apps/berrydb-desktop/pull/23\n"
            "\n"
            "Full Changelog: https://github.com/berry-apps/berrydb-desktop/compare/v1.0.7...v1.0.8",
        )

    def test_empty_body(self):
        self.assertEqual(announce.markdown_to_text(""), "")


class GeneratedBoilerplateTests(unittest.TestCase):
    PR = "https://github.com/berry-apps/berrydb-desktop/pull/23"

    def test_a_generated_bullet_loses_its_attribution_suffix_and_keeps_its_title(self):
        md = f"* feat: add a tree view by @quangtaned in {self.PR}"
        self.assertEqual(announce.strip_generated_boilerplate(md), "* feat: add a tree view")

    def test_a_bot_author_is_stripped_too(self):
        md = f"* Bump swift-nio from 2.1 to 2.2 by @dependabot[bot] in {self.PR}"
        self.assertEqual(announce.strip_generated_boilerplate(md), "* Bump swift-nio from 2.1 to 2.2")

    def test_only_the_trailing_attribution_goes_when_the_title_has_one_too(self):
        md = f"* Fix lookup by @alias in tables by @bob in {self.PR}"
        self.assertEqual(announce.strip_generated_boilerplate(md), "* Fix lookup by @alias in tables")

    def test_the_full_changelog_line_is_dropped(self):
        md = "* a\n\n**Full Changelog**: https://github.com/berry-apps/berrydb-desktop/compare/v1.0.7...v1.0.8"
        self.assertEqual(announce.strip_generated_boilerplate(md).strip(), "* a")

    def test_hand_written_by_at_someone_text_is_kept(self):
        for line in (
            "* Reviewed by @alice before merging",
            "* Reported by @alice in the sidebar thread",
            "* Reported by @alice in https://github.com/berry-apps/berrydb-desktop/issues/12",
            "Thanks to everyone, especially work by @alice.",
            "by @alice in https://example.com/pull/9",
        ):
            self.assertEqual(announce.strip_generated_boilerplate(line), line)

    def test_a_line_that_is_not_a_bullet_is_kept_even_if_it_ends_like_one(self):
        line = f"Merged by @alice in {self.PR}"
        self.assertEqual(announce.strip_generated_boilerplate(line), line)

    def test_a_hand_written_changelog_mention_is_kept(self):
        for line in (
            "**Full Changelog** lives on the wiki",
            "Full Changelog: https://github.com/berry-apps/berrydb-desktop/compare/v1.0.7...v1.0.8",
            "See the **Full Changelog**: https://example.com/changes",
        ):
            self.assertEqual(announce.strip_generated_boilerplate(line), line)

    def test_the_new_contributors_line_is_left_alone(self):
        line = f"* @alice made their first contribution in {self.PR}"
        self.assertEqual(announce.strip_generated_boilerplate(line), line)

    def test_a_whole_generated_body_reads_as_an_announcement(self):
        text = announce.markdown_to_text(announce.strip_generated_boilerplate(GENERATED_BODY))
        self.assertEqual(text, ANNOUNCED_BODY)

    def test_crlf_line_ends_do_not_hide_the_generated_lines(self):
        md = f"* a by @x in {self.PR}\r\n\r\n**Full Changelog**: https://github.com/o/r/compare/v1...v2\r\n"
        self.assertEqual(announce.markdown_to_text(announce.strip_generated_boilerplate(md)), "• a")

    def test_nothing_to_strip_is_returned_unchanged(self):
        md = "## Highlights\n* faster grids\n* a new tree view"
        self.assertEqual(announce.strip_generated_boilerplate(md), md)


class BuildMessageTests(unittest.TestCase):
    def test_layout_is_name_then_body_then_url(self):
        msg = announce.build_message("BerryDB 1.0.8", "Notes here", RELEASE_URL, limit=4096)
        self.assertEqual(msg, f"BerryDB 1.0.8\n\nNotes here\n\n{RELEASE_URL}")

    def test_empty_body_leaves_no_blank_block(self):
        msg = announce.build_message("BerryDB 1.0.8", "", RELEASE_URL, limit=4096)
        self.assertEqual(msg, f"BerryDB 1.0.8\n\n{RELEASE_URL}")

    def test_message_that_fits_is_not_touched(self):
        body = "x " * 100
        msg = announce.build_message("n", body.strip(), RELEASE_URL, limit=4096)
        self.assertNotIn("…", msg)

    def test_truncation_keeps_the_whole_url_and_fits_the_limit(self):
        body = "\n".join(f"• line {i} " + "word " * 20 for i in range(400))
        msg = announce.build_message("BerryDB 1.0.8", body, RELEASE_URL, limit=4096)
        self.assertLessEqual(units(msg), 4096)
        self.assertTrue(msg.endswith(RELEASE_URL), msg[-120:])
        self.assertTrue(msg.startswith("BerryDB 1.0.8\n\n"))
        self.assertIn("…\n\n" + RELEASE_URL, msg)

    def test_truncation_never_cuts_a_url_in_half(self):
        urls = [f"https://github.com/berry-apps/berrydb-desktop/pull/{n}" for n in range(1, 400)]
        body = "\n".join(f"* change in {u}" for u in urls)
        msg = announce.build_message("BerryDB 9.9.9", body, RELEASE_URL, limit=4096)
        for token in msg.split():
            if token.startswith("https://"):
                self.assertIn(token, urls + [RELEASE_URL])

    def test_limit_is_counted_in_utf16_units(self):
        # Each astral character is two UTF-16 code units but one Python character.
        body = "\U0001F353" * 3000
        msg = announce.build_message("n", body, RELEASE_URL, limit=4096)
        self.assertLessEqual(units(msg), 4096)
        self.assertTrue(msg.endswith(RELEASE_URL))

    def test_absurdly_long_name_still_keeps_the_url(self):
        msg = announce.build_message("N" * 6000, "body", RELEASE_URL, limit=4096)
        self.assertLessEqual(units(msg), 4096)
        self.assertTrue(msg.endswith(RELEASE_URL))

    def test_telegram_limit_constant_matches_the_documented_one(self):
        self.assertEqual(announce.TELEGRAM_MAX_CHARS, 4096)

    def test_facebook_message_carries_no_url_because_link_attaches_it(self):
        release = announce.Release("BerryDB 1.0.8", "Notes", RELEASE_URL)
        self.assertEqual(announce.facebook_message(release), "BerryDB 1.0.8\n\nNotes")
        self.assertEqual(announce.facebook_message(announce.Release("BerryDB 1.0.8", "", RELEASE_URL)), "BerryDB 1.0.8")


class ConfigurationTests(unittest.TestCase):
    def test_a_complete_pair_is_configured(self):
        self.assertEqual(announce.telegram_config(TELEGRAM_ENV), (BOT_TOKEN, CHAT_ID))
        self.assertEqual(announce.facebook_config(FACEBOOK_ENV), (PAGE_ID, PAGE_TOKEN))

    def test_an_absent_pair_is_not_configured(self):
        self.assertIsNone(announce.telegram_config({}))
        self.assertIsNone(announce.facebook_config({}))

    def test_empty_strings_count_as_unset(self):
        # Actions exposes a secret that does not exist as an empty string.
        env = {"TELEGRAM_BOT_TOKEN": "", "TELEGRAM_CHAT_ID": "  ", "FACEBOOK_PAGE_ID": "", "FACEBOOK_PAGE_ACCESS_TOKEN": ""}
        self.assertIsNone(announce.telegram_config(env))
        self.assertIsNone(announce.facebook_config(env))

    def test_half_a_telegram_pair_is_a_misconfiguration_naming_the_missing_variable(self):
        with self.assertRaises(announce.ConfigError) as ctx:
            announce.telegram_config({"TELEGRAM_BOT_TOKEN": BOT_TOKEN})
        self.assertIn("TELEGRAM_CHAT_ID", str(ctx.exception))
        self.assertNotIn(BOT_TOKEN, str(ctx.exception))
        with self.assertRaises(announce.ConfigError) as ctx:
            announce.telegram_config({"TELEGRAM_CHAT_ID": CHAT_ID})
        self.assertIn("TELEGRAM_BOT_TOKEN", str(ctx.exception))

    def test_half_a_facebook_pair_is_a_misconfiguration_naming_the_missing_variable(self):
        with self.assertRaises(announce.ConfigError) as ctx:
            announce.facebook_config({"FACEBOOK_PAGE_ID": PAGE_ID})
        self.assertIn("FACEBOOK_PAGE_ACCESS_TOKEN", str(ctx.exception))
        self.assertNotIn(PAGE_ID, str(ctx.exception))
        with self.assertRaises(announce.ConfigError) as ctx:
            announce.facebook_config({"FACEBOOK_PAGE_ACCESS_TOKEN": PAGE_TOKEN})
        self.assertIn("FACEBOOK_PAGE_ID", str(ctx.exception))

    def test_surrounding_whitespace_is_stripped(self):
        # A pasted secret with a trailing newline would otherwise put a control
        # character into the request URL.
        env = {"TELEGRAM_BOT_TOKEN": BOT_TOKEN + "\n", "TELEGRAM_CHAT_ID": " " + CHAT_ID + " "}
        self.assertEqual(announce.telegram_config(env), (BOT_TOKEN, CHAT_ID))


class ChannelSelectionTests(unittest.TestCase):
    BOTH = {**BASE_ENV, **TELEGRAM_ENV, **FACEBOOK_ENV}

    def test_a_single_channel_is_selected(self):
        self.assertEqual(announce.parse_channels("telegram"), ("telegram",))
        self.assertEqual(announce.parse_channels("facebook"), ("facebook",))

    def test_selection_is_normalised_to_canonical_order_without_duplicates(self):
        self.assertEqual(announce.parse_channels("facebook,telegram"), ("telegram", "facebook"))
        self.assertEqual(announce.parse_channels(" Facebook , TELEGRAM, telegram,"), ("telegram", "facebook"))

    def test_an_unknown_or_empty_selection_is_rejected(self):
        for bad in ("x", "telegram,x", "", ",", "twitter"):
            with self.assertRaises(argparse.ArgumentTypeError, msg=bad) as ctx:
                announce.parse_channels(bad)
            self.assertIn("telegram", str(ctx.exception))
            self.assertIn("facebook", str(ctx.exception))

    def test_a_bad_only_value_is_a_usage_error(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
            announce.main(["--tag", TAG, "--only", "twitter"], environ=dict(BASE_ENV), opener=FakeOpener())
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("twitter", err.getvalue())

    def test_only_facebook_leaves_telegram_alone_even_though_it_is_configured(self):
        opener = FakeOpener()
        code, _, err = run_main(["--tag", TAG, "--only", "facebook"], dict(self.BOTH), opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.to("api.telegram.org"), [])
        self.assertEqual(len(opener.to("graph.facebook.com")), 1)

    def test_only_telegram_leaves_facebook_alone_even_though_it_is_configured(self):
        opener = FakeOpener()
        code, _, err = run_main(["--tag", TAG, "--only", "telegram"], dict(self.BOTH), opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.to("graph.facebook.com"), [])
        self.assertEqual(len(opener.to("api.telegram.org")), 1)

    def test_without_only_every_configured_channel_posts(self):
        opener = FakeOpener()
        code, _, err = run_main(["--tag", TAG], dict(self.BOTH), opener)
        self.assertEqual(code, 0, err)
        self.assertEqual((len(opener.to("api.telegram.org")), len(opener.to("graph.facebook.com"))), (1, 1))

    def test_a_half_set_pair_of_an_unselected_channel_is_not_an_error(self):
        # Retrying only Telegram must not be blocked by Facebook's configuration.
        opener = FakeOpener()
        env = {**BASE_ENV, **TELEGRAM_ENV, "FACEBOOK_PAGE_ID": PAGE_ID}
        code, _, err = run_main(["--tag", TAG, "--only", "telegram"], env, opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(opener.to("api.telegram.org")), 1)

    def test_a_half_set_pair_of_a_selected_channel_still_fails(self):
        opener = FakeOpener()
        env = {**BASE_ENV, **TELEGRAM_ENV, "FACEBOOK_PAGE_ID": PAGE_ID}
        code, out, err = run_main(["--tag", TAG, "--only", "facebook"], env, opener)
        self.assertEqual(code, 1)
        self.assertEqual(opener.requests, [])
        self.assertIn("FACEBOOK_PAGE_ACCESS_TOKEN", out + err)

    def test_a_selected_channel_without_secrets_is_a_notice_naming_it_and_posts_nothing(self):
        opener = FakeOpener()
        code, out, err = run_main(["--tag", TAG, "--only", "facebook"], {**BASE_ENV, **TELEGRAM_ENV}, opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.requests, [])
        self.assertIn("No announcement channel is configured for facebook", out)

    def test_preview_shows_only_the_selected_channel(self):
        _, out, _ = run_main(["--tag", TAG, "--preview", "--only", "telegram"], dict(BASE_ENV), FakeOpener())
        self.assertIn("== Telegram", out)
        self.assertNotIn("Facebook", out)
        _, out, _ = run_main(["--tag", TAG, "--preview", "--only", "facebook"], dict(BASE_ENV), FakeOpener())
        self.assertIn("== Facebook Page", out)
        self.assertNotIn("Telegram", out)

    def test_summary_shows_only_the_selected_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = pathlib.Path(tmp) / "summary.md"
            run_main(["--tag", TAG, "--preview", "--only", "facebook", "--summary-file", str(summary)],
                     dict(BASE_ENV), FakeOpener())
            text = summary.read_text()
        self.assertIn("### Facebook Page", text)
        self.assertNotIn("Telegram", text)


class FetchReleaseTests(unittest.TestCase):
    def test_reads_the_release_by_tag_with_a_bearer_token(self):
        opener = FakeOpener()
        release = announce.fetch_release(REPO, TAG, GH_TOKEN, opener)
        (sent,) = opener.requests
        self.assertEqual(sent.method, "GET")
        self.assertEqual(sent.url, f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}")
        self.assertEqual(sent.headers["authorization"], f"Bearer {GH_TOKEN}")
        self.assertEqual(release, announce.Release("BerryDB 1.0.8", ANNOUNCED_BODY, RELEASE_URL))

    def test_untitled_release_falls_back_to_the_tag(self):
        opener = FakeOpener(release={**RELEASE_JSON, "name": None, "body": None})
        release = announce.fetch_release(REPO, TAG, GH_TOKEN, opener)
        self.assertEqual((release.name, release.body), (TAG, ""))

    def test_tag_is_percent_encoded_into_the_path(self):
        opener = FakeOpener()
        announce.fetch_release(REPO, "v1/../../x?y", GH_TOKEN, opener)
        self.assertEqual(urlsplit(opener.requests[0].url).path, f"/repos/{REPO}/releases/tags/v1%2F..%2F..%2Fx%3Fy")

    def test_a_missing_release_is_an_error_that_leaks_no_token(self):
        url = f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}"
        opener = FakeOpener(release=http_error(url, 404, {"message": "Not Found"}))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.fetch_release(REPO, TAG, GH_TOKEN, opener)
        self.assertIn("404", str(ctx.exception))
        self.assertNotIn(GH_TOKEN, str(ctx.exception))

    def test_repository_must_look_like_owner_slash_name(self):
        for bad in ("", "no-slash", "a/b/c", "../x", "a b/c"):
            with self.assertRaises(announce.ConfigError, msg=bad):
                announce.fetch_release(bad, TAG, GH_TOKEN, FakeOpener())


class PostTests(unittest.TestCase):
    def test_telegram_request_shape(self):
        opener = FakeOpener()
        result = announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "hello\n\nhttps://example.com", RELEASE_URL)
        (sent,) = opener.requests
        self.assertEqual(sent.method, "POST")
        self.assertEqual(sent.url, f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage")
        self.assertEqual(sent.form()["chat_id"], CHAT_ID)
        self.assertEqual(sent.form()["text"], "hello\n\nhttps://example.com")
        self.assertNotIn("parse_mode", sent.form())
        self.assertEqual(set(sent.form()), {"chat_id", "text", "link_preview_options"})
        self.assertEqual(sent.headers["content-type"], "application/x-www-form-urlencoded")
        self.assertIn("77", result)

    def test_telegram_link_preview_points_at_the_release_page_not_the_first_url_in_the_text(self):
        # Without link_preview_options Telegram previews the first URL in the
        # text, which in hand-written notes is rarely the release page.
        opener = FakeOpener()
        announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "see https://example.com/first\n\n" + RELEASE_URL, RELEASE_URL)
        options = json.loads(opener.requests[0].form()["link_preview_options"])
        self.assertEqual(options, {"url": RELEASE_URL})

    def test_facebook_request_shape_keeps_the_token_out_of_the_url(self):
        opener = FakeOpener()
        result = announce.post_facebook(opener, PAGE_ID, PAGE_TOKEN, "msg", RELEASE_URL)
        (sent,) = opener.requests
        self.assertEqual(sent.method, "POST")
        self.assertEqual(sent.url, f"https://graph.facebook.com/{announce.GRAPH_API_VERSION}/{PAGE_ID}/feed")
        self.assertNotIn("?", sent.url)
        self.assertNotIn(PAGE_TOKEN, sent.url)
        self.assertEqual(sent.form(), {"message": "msg", "link": RELEASE_URL, "access_token": PAGE_TOKEN})
        self.assertEqual(sent.headers["content-type"], "application/x-www-form-urlencoded")
        self.assertIn("5550001", result)

    def test_graph_api_version_is_pinned_in_one_constant(self):
        self.assertRegex(announce.GRAPH_API_VERSION, r"^v\d+\.\d+$")

    def test_telegram_ok_false_is_a_failure_even_on_http_200(self):
        opener = FakeOpener(telegram={"ok": False, "description": "Bad Request: chat not found"})
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertIn("chat not found", str(ctx.exception))

    def test_facebook_response_without_an_id_is_a_failure(self):
        opener = FakeOpener(facebook={"success": True})
        with self.assertRaises(announce.RequestError):
            announce.post_facebook(opener, PAGE_ID, PAGE_TOKEN, "x", RELEASE_URL)

    def test_http_error_carries_the_description_but_not_the_token(self):
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        body = {"ok": False, "error_code": 401, "description": f"Unauthorized (token {BOT_TOKEN})"}
        opener = FakeOpener(telegram=http_error(url, 401, body))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertIn("401", str(ctx.exception))
        self.assertIn("Unauthorized", str(ctx.exception))
        self.assertNotIn(BOT_TOKEN, str(ctx.exception))

    def test_the_error_response_is_closed_after_its_body_is_read(self):
        body = io.BytesIO(b'{"ok": false, "description": "Bad Request: chat not found"}')
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        opener = FakeOpener(telegram=urllib.error.HTTPError(url, 400, "error", {}, body))
        with self.assertRaises(announce.RequestError):
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertTrue(body.closed)

    def test_facebook_graph_error_message_is_surfaced_and_scrubbed(self):
        url = f"https://graph.facebook.com/{announce.GRAPH_API_VERSION}/{PAGE_ID}/feed"
        body = {"error": {"message": f"Invalid OAuth access token {PAGE_TOKEN}", "code": 190}}
        opener = FakeOpener(facebook=http_error(url, 400, body))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_facebook(opener, PAGE_ID, PAGE_TOKEN, "x", RELEASE_URL)
        self.assertIn("Invalid OAuth access token", str(ctx.exception))
        self.assertNotIn(PAGE_TOKEN, str(ctx.exception))

    def test_a_network_error_that_quotes_the_url_is_scrubbed(self):
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        opener = FakeOpener(telegram=urllib.error.URLError(f"cannot reach {url}"))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertNotIn(BOT_TOKEN, str(ctx.exception))
        self.assertNotIn(BOT_TOKEN.split(":")[0], str(ctx.exception))

    def test_a_non_urllib_exception_that_quotes_the_url_is_scrubbed(self):
        # http.client rejects a URL with control characters and quotes it whole.
        quoted = f"/bot{BOT_TOKEN}/sendMessage"
        opener = FakeOpener(telegram=InvalidURL(f"URL can't contain control characters. {quoted!r}"))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertNotIn(BOT_TOKEN, str(ctx.exception))

    def test_percent_encoded_token_is_scrubbed_too(self):
        quoted = quote(BOT_TOKEN, safe="")
        opener = FakeOpener(telegram=urllib.error.URLError(f"bad /bot{quoted}/sendMessage"))
        with self.assertRaises(announce.RequestError) as ctx:
            announce.post_telegram(opener, BOT_TOKEN, CHAT_ID, "x", RELEASE_URL)
        self.assertNotIn(quoted, str(ctx.exception))

    def test_redirects_are_not_followed(self):
        # urllib forwards request headers to a redirect target, which would
        # carry a bearer token or a token-bearing URL to another host.
        handler = announce._NoRedirect()
        request = urllib.request.Request("https://api.telegram.org/x", data=b"a=b")
        self.assertIsNone(handler.redirect_request(request, None, 302, "Found", {}, "https://evil.example/"))


class MainTests(unittest.TestCase):
    def test_preview_posts_nothing_and_needs_no_channel_secrets(self):
        opener = FakeOpener()
        code, out, err = run_main(["--tag", TAG, "--preview"], dict(BASE_ENV), opener)
        self.assertEqual(code, 0, err)
        self.assertEqual([r.method for r in opener.requests], ["GET"])
        self.assertEqual(opener.requests[0].host, "api.github.com")
        self.assertIn("Telegram", out)
        self.assertIn("Facebook", out)

    def test_preview_never_posts_even_when_every_channel_is_configured(self):
        opener = FakeOpener()
        env = {**BASE_ENV, **TELEGRAM_ENV, **FACEBOOK_ENV}
        code, out, err = run_main(["--tag", TAG, "--preview"], env, opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.posts(), [])
        for secret in SECRETS:
            self.assertNotIn(secret, out + err)

    def test_preview_shows_exactly_what_will_be_posted(self):
        opener = FakeOpener()
        _, out, _ = run_main(["--tag", TAG, "--preview"], dict(BASE_ENV), opener)
        release = announce.fetch_release(REPO, TAG, GH_TOKEN, FakeOpener())
        self.assertIn(announce.telegram_text(release), out)
        self.assertIn(f"link preview: {RELEASE_URL}", out)
        self.assertIn(announce.facebook_message(release), out)
        self.assertIn(f"link: {RELEASE_URL}", out)

    def test_preview_reports_telegram_length_against_the_limit(self):
        long_body = "\n".join(f"* item {i} " + "word " * 30 for i in range(300))
        opener = FakeOpener(release={**RELEASE_JSON, "body": long_body})
        _, out, _ = run_main(["--tag", TAG, "--preview"], dict(BASE_ENV), opener)
        self.assertIn("of 4096 characters, body truncated to fit", out)

    def test_preview_says_so_when_nothing_was_truncated(self):
        _, out, _ = run_main(["--tag", TAG, "--preview"], dict(BASE_ENV), FakeOpener())
        self.assertIn("of 4096 characters, fits", out)
        self.assertNotIn("truncated", out)

    def test_summary_file_gets_a_fenced_markdown_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = pathlib.Path(tmp) / "summary.md"
            summary.write_text("earlier step output\n")
            code, _, err = run_main(
                ["--tag", TAG, "--preview", "--summary-file", str(summary)], dict(BASE_ENV), FakeOpener())
            self.assertEqual(code, 0, err)
            text = summary.read_text()
        self.assertTrue(text.startswith("earlier step output\n"), "the summary file is appended to, not replaced")
        self.assertIn("```", text)
        self.assertIn("What's Changed", text)
        self.assertIn(RELEASE_URL, text)
        self.assertIn("approv", text.lower())

    def test_summary_fence_is_longer_than_any_backtick_run_in_the_message(self):
        release = announce.Release("BerryDB 1.0.8", "before ```` after", RELEASE_URL)
        text = announce.render_summary(release)
        self.assertIn("`````\nBerryDB 1.0.8\n\nbefore ```` after\n`````", text)

    def test_no_channel_configured_is_a_notice_and_exit_zero_without_any_request(self):
        opener = FakeOpener()
        code, out, err = run_main(["--tag", TAG], dict(BASE_ENV), opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.requests, [])
        self.assertIn("No announcement channel is configured", out)

    def test_both_channels_configured_both_post_and_exit_zero(self):
        opener = FakeOpener()
        env = {**BASE_ENV, **TELEGRAM_ENV, **FACEBOOK_ENV}
        code, out, err = run_main(["--tag", TAG], env, opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(opener.to("api.telegram.org")), 1)
        self.assertEqual(len(opener.to("graph.facebook.com")), 1)
        telegram = opener.to("api.telegram.org")[0].form()
        self.assertTrue(telegram["text"].endswith(RELEASE_URL))
        self.assertEqual(json.loads(telegram["link_preview_options"]), {"url": RELEASE_URL})
        facebook = opener.to("graph.facebook.com")[0].form()
        self.assertEqual(facebook["link"], RELEASE_URL)
        self.assertNotIn(RELEASE_URL, facebook["message"])
        for secret in SECRETS:
            self.assertNotIn(secret, out + err)

    def test_only_the_configured_channel_posts(self):
        opener = FakeOpener()
        code, _, err = run_main(["--tag", TAG], {**BASE_ENV, **FACEBOOK_ENV}, opener)
        self.assertEqual(code, 0, err)
        self.assertEqual(opener.to("api.telegram.org"), [])
        self.assertEqual(len(opener.to("graph.facebook.com")), 1)

    def test_a_failed_channel_does_not_stop_the_other_but_the_run_fails(self):
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        opener = FakeOpener(telegram=http_error(url, 400, {"ok": False, "description": "Bad Request: chat not found"}))
        env = {**BASE_ENV, **TELEGRAM_ENV, **FACEBOOK_ENV}
        code, out, err = run_main(["--tag", TAG], env, opener)
        self.assertEqual(code, 1)
        self.assertEqual(len(opener.to("graph.facebook.com")), 1, "Facebook is still attempted")
        self.assertIn("chat not found", out + err)
        for secret in SECRETS:
            self.assertNotIn(secret, out + err)

    def test_a_failed_facebook_post_after_telegram_succeeded_still_fails_the_run(self):
        url = f"https://graph.facebook.com/{announce.GRAPH_API_VERSION}/{PAGE_ID}/feed"
        opener = FakeOpener(facebook=http_error(url, 400, {"error": {"message": "Invalid OAuth access token", "code": 190}}))
        env = {**BASE_ENV, **TELEGRAM_ENV, **FACEBOOK_ENV}
        code, out, err = run_main(["--tag", TAG], env, opener)
        self.assertEqual(code, 1)
        self.assertEqual(len(opener.to("api.telegram.org")), 1)
        self.assertIn("Invalid OAuth access token", out + err)

    def test_half_configured_channel_fails_before_anything_is_posted(self):
        # A retry after fixing the configuration must not double-post the
        # channel that was fine.
        opener = FakeOpener()
        env = {**BASE_ENV, "TELEGRAM_BOT_TOKEN": BOT_TOKEN, **FACEBOOK_ENV}
        code, out, err = run_main(["--tag", TAG], env, opener)
        self.assertEqual(code, 1)
        self.assertEqual(opener.requests, [])
        self.assertIn("TELEGRAM_CHAT_ID", out + err)
        for secret in SECRETS:
            self.assertNotIn(secret, out + err)

    def test_missing_release_fails_without_posting(self):
        url = f"https://api.github.com/repos/{REPO}/releases/tags/{TAG}"
        opener = FakeOpener(release=http_error(url, 404, {"message": "Not Found"}))
        code, out, err = run_main(["--tag", TAG], {**BASE_ENV, **TELEGRAM_ENV}, opener)
        self.assertEqual(code, 1)
        self.assertEqual(opener.posts(), [])
        self.assertIn("404", out + err)
        self.assertNotIn(GH_TOKEN, out + err)

    def test_missing_github_credentials_are_reported(self):
        for env in ({}, {"GH_TOKEN": GH_TOKEN}, {"GITHUB_REPOSITORY": REPO}):
            code, out, err = run_main(["--tag", TAG, "--preview"], env, FakeOpener())
            self.assertNotEqual(code, 0)
            self.assertTrue(("GH_TOKEN" in err) or ("GITHUB_REPOSITORY" in err), err)

    def test_posted_text_matches_what_preview_showed(self):
        preview_opener, post_opener = FakeOpener(), FakeOpener()
        _, preview_out, _ = run_main(["--tag", TAG, "--preview"], dict(BASE_ENV), preview_opener)
        run_main(["--tag", TAG], {**BASE_ENV, **TELEGRAM_ENV}, post_opener)
        posted = post_opener.to("api.telegram.org")[0].form()["text"]
        self.assertIn(posted, preview_out)


if __name__ == "__main__":
    unittest.main()
