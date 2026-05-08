#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Original source: ACowAdonis kyber-bf2-linux tarball
#   (src/share/kyber-bf2/payload/cli/ea-auth-webview.py, V1.0.0)
# Vendored 2026-05-05 into the Kyber Linux Port. Bundled and
# distributed under GPL-3.0-or-later.
"""
EA OAuth Login WebView

Opens the EA auth URL in a GTK WebView window. When EA redirects to
qrc:// after login, the WebView intercepts the navigation, extracts
the auth code, and delivers it to Kyber's local callback server.

This avoids the problem where Linux browsers cannot handle qrc://
protocol redirects from server-side 302 responses.

Usage: ea-auth-webview.py <ea-auth-url>

Requires: gir1.2-webkit2-4.0 or 4.1, python3-gi
Install:  sudo apt install gir1.2-webkit2-4.1 python3-gi
"""

import sys
import time
import urllib.parse
import urllib.request

# Try WebKit2 4.1 first (Ubuntu 23.04+), fall back to 4.0
import gi
gi.require_version('Gtk', '3.0')
try:
    gi.require_version('WebKit2', '4.1')
except ValueError:
    gi.require_version('WebKit2', '4.0')
from gi.repository import Gtk, WebKit2

CALLBACK_URL = 'http://127.0.0.1:31033/auth'


class EAAuthWindow(Gtk.Window):
    def __init__(self, auth_url):
        super().__init__(title='Kyber - EA Login')
        self.set_default_size(900, 700)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.auth_delivered = False

        webview = WebKit2.WebView()
        webview.connect('decide-policy', self.on_decide_policy)
        webview.connect('load-failed', self.on_load_failed)
        webview.load_uri(auth_url)

        self.add(webview)
        self.show_all()

    def on_decide_policy(self, webview, decision, decision_type):
        if decision_type != WebKit2.PolicyDecisionType.NAVIGATION:
            return False

        nav = decision.get_navigation_action()
        request = nav.get_request()
        uri = request.get_uri()

        if not uri.startswith('qrc:'):
            return False

        # Intercept qrc:// navigation - extract auth code
        decision.ignore()
        self.deliver_code(uri)
        return True

    def on_load_failed(self, webview, load_event, failing_uri, error):
        if failing_uri.startswith('qrc:'):
            self.deliver_code(failing_uri)
            return True
        return False

    def deliver_code(self, uri):
        if self.auth_delivered:
            return
        self.auth_delivered = True

        # Parse code from qrc URL
        # qrc:///html/login_successful.html?code=XXXX
        # or qrc:/html/login_successful.html?code=XXXX
        code = None
        if '?' in uri:
            query_str = uri.split('?', 1)[1]
            params = urllib.parse.parse_qs(query_str)
            if 'code' in params:
                code = params['code'][0]

        if code:
            url = f'{CALLBACK_URL}?code={urllib.parse.quote(code)}'
            # Retry: the callback server may not be listening yet (open::that()
            # must return before Maxima binds port 31033)
            for attempt in range(15):
                try:
                    urllib.request.urlopen(url, timeout=5)
                    print(f'Auth code delivered successfully.')
                    break
                except (ConnectionRefusedError, urllib.error.URLError):
                    if attempt < 14:
                        time.sleep(0.5)
                    else:
                        print(f'Failed to deliver auth code after retries.')
                        print(f'Code: {code}')
                        print(f'Try manually: curl "{CALLBACK_URL}?code={code}"')
                except Exception as e:
                    print(f'Failed to deliver auth code: {e}')
                    print(f'Code: {code}')
                    print(f'Try manually: curl "{CALLBACK_URL}?code={code}"')
                    break
        else:
            print(f'Could not extract auth code from: {uri}')

        Gtk.main_quit()


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <ea-auth-url>')
        sys.exit(1)

    auth_url = sys.argv[1]
    if 'accounts.ea.com' not in auth_url:
        print(f'Warning: URL does not appear to be an EA auth URL')

    win = EAAuthWindow(auth_url)
    win.connect('destroy', Gtk.main_quit)
    Gtk.main()


if __name__ == '__main__':
    main()
