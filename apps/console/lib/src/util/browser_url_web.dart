// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

/// Removes the one-time authorization code from the address bar and browser
/// history as soon as the magic-link callback has been handled.
void clearBrowserAuthFragment() {
  final location = html.window.location;
  html.window.history.replaceState(
    null,
    html.document.title,
    location.pathname,
  );
}
