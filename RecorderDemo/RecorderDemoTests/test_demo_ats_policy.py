"""Spec for RecorderDemo's App Transport Security configuration.

The tests encode the secure behavior of the demo browser. They fail while
NSAllowsArbitraryLoads (or an equally broad web-view exception) is shipped,
and they pass once arbitrary hosts are no longer exempted.

The platform decision is the one documented by Apple for the iOS 9 SDK this
project links (RecorderDemo.xcodeproj, CreatedOnToolsVersion = 7.0). The
evaluator below follows those documents:

- NSAllowsArbitraryLoads disables ATS restrictions for every domain that is
  not listed under NSExceptionDomains. Unsecured HTTP is then allowed.
  Extended checks (TLS 1.2+, forward secrecy, certificate key and hash
  requirements) are disabled. Default server trust evaluation is not.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads
- On iOS 10 and later, NSAllowsArbitraryLoads is ignored when
  NSAllowsArbitraryLoadsForMedia, NSAllowsArbitraryLoadsInWebContent, or
  NSAllowsLocalNetworking is present. On iOS 9 those other keys are ignored.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity
- NSAllowsArbitraryLoadsInWebContent disables ATS for web-view loads. This
  demo's browser is a UIWebView (Main.storyboard, ViewController.swift).
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent
- NSExceptionAllowsInsecureHTTPLoads allows insecure HTTP for that domain
  only. It does not, by itself, change TLS or forward-secrecy requirements.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsexceptionallowsinsecurehttploads
- NSIncludesSubdomains defaults to NO and, when YES, adds only one extra
  DNS label.
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsincludessubdomains
- NSExceptionMinimumTLSVersion defaults to TLSv1.2.
  NSExceptionRequiresForwardSecrecy defaults to YES.
- Global exceptions do not apply to domains listed in NSExceptionDomains.
  An empty domain dictionary keeps full ATS for that domain.

Recording behavior is the app's own code: AppDelegate starts the shared
recorder with no recordingTestBlock, SWRecordingProtocol accepts every http
and https request, and connectionDidFinishLoading writes the response body.
A load ATS refuses never reaches that write.
"""

from __future__ import annotations

import plistlib
import re
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlsplit


REPO_ROOT = Path(__file__).resolve().parents[2]
DEMO_PLIST = REPO_ROOT / "RecorderDemo" / "RecorderDemo" / "Info.plist"
VIEW_CONTROLLER = REPO_ROOT / "RecorderDemo" / "RecorderDemo" / "ViewController.swift"
APP_DELEGATE = REPO_ROOT / "RecorderDemo" / "RecorderDemo" / "AppDelegate.swift"

INJECTED_BODY = b"<html><script>injected-by-network</script></html>"

_OTHER_GLOBAL_KEYS = (
    "NSAllowsArbitraryLoadsForMedia",
    "NSAllowsArbitraryLoadsInWebContent",
    "NSAllowsLocalNetworking",
)


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def browse_button_url(source: str) -> str:
    """Return the URL literal browseButtonTapped writes into the field."""
    match = re.search(
        r"func browseButtonTapped\b.*?urlTextField\.text\s*=\s*\"([^\"]+)\"",
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError(
            "browseButtonTapped no longer assigns a URL string literal to urlTextField.text"
        )
    return match.group(1)


def permitted_cleartext_host(view_controller_source: str) -> str | None:
    """The only host that may stay on cleartext: the built-in browse URL, if it is http."""
    parsed = urlsplit(browse_button_url(view_controller_source))
    if parsed.scheme != "http" or not parsed.hostname:
        return None
    return parsed.hostname.rstrip(".").lower()


def normalize_host(host: str) -> str:
    return host.rstrip(".").lower()


class AtsPolicy:
    """ATS allow/deny for the URL loading system, from the shipped Info.plist."""

    def __init__(self, ats: dict | None):
        self.ats = ats or {}

    @classmethod
    def from_info_plist(cls, info: dict) -> "AtsPolicy":
        return cls(info.get("NSAppTransportSecurity"))

    def _exception_config(self, host: str) -> dict | None:
        domains = self.ats.get("NSExceptionDomains") or {}
        host = normalize_host(host)
        exact = None
        subdomain = None
        for raw_domain, config in domains.items():
            domain = normalize_host(str(raw_domain))
            config = config or {}
            if host == domain:
                exact = config
                break
            if config.get("NSIncludesSubdomains") is True and host.endswith("." + domain):
                extra = host[: -(len(domain) + 1)]
                if extra and "." not in extra:
                    subdomain = config
        if exact is not None:
            return exact
        return subdomain

    def _arbitrary_loads_effective(self, ios_major: int) -> bool:
        """Whether NSAllowsArbitraryLoads disables ATS on this OS version."""
        if ios_major >= 10 and any(key in self.ats for key in _OTHER_GLOBAL_KEYS):
            return False
        return self.ats.get("NSAllowsArbitraryLoads") is True

    def _webview_ats_disabled(self, ios_major: int) -> bool:
        """Whether web-view loads skip ATS. The key is ignored on iOS 9."""
        if ios_major < 10:
            return False
        return self.ats.get("NSAllowsArbitraryLoadsInWebContent") is True

    def insecure_http_allowed(self, host: str, ios_major: int, *, webview: bool) -> bool:
        exception = self._exception_config(host)
        if exception is not None:
            return exception.get("NSExceptionAllowsInsecureHTTPLoads") is True
        if webview and self._webview_ats_disabled(ios_major):
            return True
        return self._arbitrary_loads_effective(ios_major)

    def extended_checks_enabled(self, host: str, ios_major: int, *, webview: bool) -> bool:
        """TLS 1.2+ and forward secrecy still required for this host.

        NSExceptionAllowsInsecureHTTPLoads does not itself remove those checks.
        NSAllowsArbitraryLoads and NSAllowsArbitraryLoadsInWebContent do.
        """
        exception = self._exception_config(host)
        if exception is not None:
            if exception.get("NSExceptionRequiresForwardSecrecy") is False:
                return False
            minimum = exception.get("NSExceptionMinimumTLSVersion", "TLSv1.2")
            return minimum in ("TLSv1.2", "TLSv1.3")
        if webview and self._webview_ats_disabled(ios_major):
            return False
        if self._arbitrary_loads_effective(ios_major):
            return False
        return True

    def weakening_exception_domains(self) -> list[str]:
        weakened = []
        for raw_domain, config in (self.ats.get("NSExceptionDomains") or {}).items():
            config = config or {}
            minimum = config.get("NSExceptionMinimumTLSVersion", "TLSv1.2")
            if (
                config.get("NSExceptionAllowsInsecureHTTPLoads") is True
                or config.get("NSExceptionRequiresForwardSecrecy") is False
                or minimum not in ("TLSv1.2", "TLSv1.3")
                or config.get("NSIncludesSubdomains") is True
            ):
                weakened.append(normalize_host(str(raw_domain)))
        return weakened


def go_button_request(url_text: str) -> str | None:
    """ViewController.goButtonTapped passes the field text to NSURL unchanged.

    NSURL(string:) yields a URL for an absolute http(s) string and loadRequest
    is called with that URL. There is no host allowlist in between.
    """
    parsed = urlsplit(url_text.strip())
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    return url_text.strip()


def record_mocktail(recording_dir: Path, url: str, body: bytes) -> Path:
    """What SWRecordingProtocol writes after a load finishes.

    Mirrors createMocktailFileWithRequest (default GET, no base64 for
    text/html) and createFileAt. AppDelegate selects the Mocktail format and
    never installs a recordingTestBlock, and canInitWithRequest returns YES
    for every http and https URL.
    """
    parsed = urlsplit(url)
    path = parsed.path or "/"
    if parsed.query:
        parts = []
        for part in parsed.query.split("&"):
            if "=" in part:
                key, _value = part.split("=", 1)
                parts.append(f"{key}=.*")
            else:
                parts.append(part)
        pattern = path + r"\?" + "&".join(parts) + "$"
    else:
        pattern = path + "$"
    tail = "GET\n{pattern}\n200\ntext/html\n\n".format(pattern=pattern).encode("utf-8") + body
    recording_dir.mkdir(parents=True, exist_ok=True)
    destination = recording_dir / "page_0_0.tail"
    destination.write_bytes(tail)
    return destination


def webview_load(policy: AtsPolicy, url_text: str, ios_major: int, body: bytes, recording_dir: Path) -> Path | None:
    """Cleartext launch path: ATS first, then the recorder.

    For an http URL, the URL loading system applies Info.plist before the
    response is delivered. SWRecordingProtocol writes the body only from
    connectionDidFinishLoading, so a refused cleartext load produces no file.
    An https URL is not modeled here: disabling ATS extended checks does not
    disable default server trust evaluation, and this demo never accepts a
    server-trust challenge on its own.
    """
    url = go_button_request(url_text)
    if url is None:
        return None
    parsed = urlsplit(url)
    if parsed.scheme != "http":
        return None
    host = parsed.hostname or ""
    if not policy.insecure_http_allowed(host, ios_major, webview=True):
        return None
    return record_mocktail(recording_dir, url, body)


class AtsEvaluatorTests(unittest.TestCase):
    """Lock the evaluator to Apple's rules so an inverted check cannot hide the bug."""

    def test_defaults_block_cleartext_and_keep_extended_checks(self):
        policy = AtsPolicy({})
        for ios_major in (9, 10):
            self.assertFalse(policy.insecure_http_allowed("other.example", ios_major, webview=True))
            self.assertTrue(policy.extended_checks_enabled("bank.example", ios_major, webview=True))

    def test_single_host_exception_does_not_cover_neighbors(self):
        policy = AtsPolicy(
            {
                "NSExceptionDomains": {
                    "jsonplaceholder.typicode.com": {
                        "NSExceptionAllowsInsecureHTTPLoads": True,
                    }
                }
            }
        )
        for ios_major in (9, 10):
            self.assertTrue(
                policy.insecure_http_allowed("jsonplaceholder.typicode.com", ios_major, webview=True)
            )
            self.assertTrue(
                policy.insecure_http_allowed("JSONPLACEHOLDER.TYPICODE.COM.", ios_major, webview=True)
            )
            for host in (
                "www.jsonplaceholder.typicode.com",
                "jsonplaceholder.typicode.com.evil.example",
                "notjsonplaceholder.typicode.com",
                "typicode.com",
                "other.example",
            ):
                self.assertFalse(policy.insecure_http_allowed(host, ios_major, webview=True), host)
            self.assertTrue(policy.extended_checks_enabled("bank.example", ios_major, webview=True))
            # The insecure-HTTP exception does not remove TLS or forward-secrecy checks.
            self.assertTrue(
                policy.extended_checks_enabled("jsonplaceholder.typicode.com", ios_major, webview=True)
            )

    def test_includes_subdomains_adds_only_one_label(self):
        policy = AtsPolicy(
            {
                "NSExceptionDomains": {
                    "typicode.com": {
                        "NSIncludesSubdomains": True,
                        "NSExceptionAllowsInsecureHTTPLoads": True,
                    }
                }
            }
        )
        self.assertTrue(policy.insecure_http_allowed("jsonplaceholder.typicode.com", 10, webview=True))
        self.assertFalse(
            policy.insecure_http_allowed("a.jsonplaceholder.typicode.com", 10, webview=True)
        )

    def test_web_content_exception_is_ios10_webview_only(self):
        policy = AtsPolicy(
            {
                "NSAllowsArbitraryLoads": False,
                "NSAllowsArbitraryLoadsInWebContent": True,
            }
        )
        self.assertFalse(policy.insecure_http_allowed("other.example", 9, webview=True))
        self.assertTrue(policy.insecure_http_allowed("other.example", 10, webview=True))
        self.assertFalse(policy.extended_checks_enabled("bank.example", 10, webview=True))

    def test_ios9_honors_arbitrary_loads_when_a_later_key_is_present(self):
        policy = AtsPolicy(
            {
                "NSAllowsArbitraryLoads": True,
                "NSAllowsArbitraryLoadsInWebContent": False,
            }
        )
        self.assertTrue(policy.insecure_http_allowed("other.example", 9, webview=True))
        self.assertFalse(policy.extended_checks_enabled("bank.example", 9, webview=True))
        self.assertFalse(policy.insecure_http_allowed("other.example", 10, webview=True))
        self.assertTrue(policy.extended_checks_enabled("bank.example", 10, webview=True))

    def test_exception_domain_opts_out_of_a_global_allow(self):
        policy = AtsPolicy(
            {
                "NSAllowsArbitraryLoads": True,
                "NSExceptionDomains": {"bank.example": {}},
            }
        )
        self.assertFalse(policy.insecure_http_allowed("bank.example", 9, webview=True))
        self.assertTrue(policy.extended_checks_enabled("bank.example", 9, webview=True))
        self.assertTrue(policy.insecure_http_allowed("other.example", 9, webview=True))

    def test_recorder_writes_the_response_body_it_is_given(self):
        with tempfile.TemporaryDirectory() as directory:
            path = record_mocktail(Path(directory), "http://other.example/page", INJECTED_BODY)
            text = path.read_bytes()
        self.assertIn(b"GET\n", text)
        self.assertIn(b"/page$\n", text)
        self.assertTrue(text.endswith(INJECTED_BODY))


class DemoAtsPolicyTests(unittest.TestCase):
    """These fail on the shipped demo until the global ATS exemption is removed."""

    @classmethod
    def setUpClass(cls):
        cls.info = load_plist(DEMO_PLIST)
        cls.policy = AtsPolicy.from_info_plist(cls.info)
        cls.view_source = VIEW_CONTROLLER.read_text(encoding="utf-8")
        cls.app_delegate = APP_DELEGATE.read_text(encoding="utf-8")
        cls.cleartext_host = permitted_cleartext_host(cls.view_source)

    def test_shipped_plist_does_not_disable_ats_for_every_host(self):
        ats = self.info.get("NSAppTransportSecurity") or {}
        # iOS 9 applies this key even when later, narrower keys are also present.
        self.assertIsNot(
            ats.get("NSAllowsArbitraryLoads"),
            True,
            "NSAllowsArbitraryLoads disables ATS for every host that is not listed "
            "in NSExceptionDomains, including user-entered URLs",
        )
        # iOS 10 applies this key to the UIWebView this demo loads.
        self.assertIsNot(
            ats.get("NSAllowsArbitraryLoadsInWebContent"),
            True,
            "NSAllowsArbitraryLoadsInWebContent disables ATS for every web-view host",
        )

    def test_only_the_browse_host_may_weaken_ats(self):
        weakened = self.policy.weakening_exception_domains()
        if self.cleartext_host is None:
            self.assertEqual(weakened, [])
        else:
            self.assertTrue(
                set(weakened) <= {self.cleartext_host},
                f"ATS exceptions weaken hosts other than {self.cleartext_host}: {weakened}",
            )

    def test_go_button_cleartext_to_other_hosts_is_not_loaded_or_recorded(self):
        """User text is loaded as-is. Cleartext to any other host must be refused
        before SWRecordingProtocol writes the attacker-controlled body.
        """
        self.assertNotIn("recordingTestBlock", self.app_delegate)
        user_urls = (
            "http://other.example/page",
            "http://other.example:8080/page",
            "HTTP://Other.Example/page",
            "http://jsonplaceholder.typicode.com.evil.example/page",
            "http://notjsonplaceholder.typicode.com/page",
            "http://www.jsonplaceholder.typicode.com/page",
            "http://typicode.com/page",
        )
        for ios_major in (9, 10):
            for url_text in user_urls:
                with tempfile.TemporaryDirectory() as directory:
                    recorded = webview_load(
                        self.policy,
                        url_text,
                        ios_major,
                        INJECTED_BODY,
                        Path(directory),
                    )
                    self.assertIsNone(
                        recorded,
                        f"iOS {ios_major} allowed {url_text} and recorded {recorded}",
                    )
                    self.assertEqual(list(Path(directory).iterdir()), [])

    def test_user_https_urls_keep_extended_ats_checks(self):
        """A user-entered https URL must still be subject to ATS extended checks.

        NSAllowsArbitraryLoads turns TLS version, forward secrecy, and the
        extra certificate checks off for every host. It does not replace
        default server trust evaluation, so this test does not treat a forged
        certificate as accepted. It fails while those extended checks are off.
        """
        host = "bank.example"
        for ios_major in (9, 10):
            self.assertTrue(
                self.policy.extended_checks_enabled(host, ios_major, webview=True),
                f"iOS {ios_major} disables ATS extended checks for {host}",
            )

    def test_browse_button_http_url_is_not_a_pattern_for_other_hosts(self):
        browse_url = browse_button_url(self.view_source)
        self.assertEqual(urlsplit(browse_url).scheme, "http")
        sample = permitted_cleartext_host(self.view_source)
        self.assertIsNotNone(sample)
        for ios_major in (9, 10):
            self.assertFalse(
                self.policy.insecure_http_allowed("evil." + sample, ios_major, webview=True)
            )
            self.assertFalse(
                self.policy.insecure_http_allowed(sample + ".evil.example", ios_major, webview=True)
            )


if __name__ == "__main__":
    unittest.main()
