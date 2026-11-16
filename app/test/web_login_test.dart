import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/web_login.dart';

// Shapes copied from the bridges' own cookie steps (mautrix-slack's token
// flow, mautrix-instagram's cookie flow, the Discord browser flow).
LoginStep slackStep() => LoginStep.fromJson({
      'login_id': 'L1',
      'type': 'cookies',
      'step_id': 'fi.mau.slack.login.enter_auth_token',
      'instructions': 'Enter a JSON object…',
      'cookies': {
        'url': 'https://slack.com/signin',
        'fields': [
          {
            'id': 'auth_token',
            'required': true,
            'sources': [
              {'type': 'special', 'name': 'fi.mau.slack.auth_token'},
              {
                'type': 'request_body',
                'name': 'token',
                'request_url_regex': r'^https://.+?\.slack\.com/api/(client|experiments|api|users|teams|conversations)\..+$',
              },
            ],
            'pattern': r'^xoxc-.+$',
          },
          {
            'id': 'cookie_token',
            'required': true,
            'sources': [
              {'type': 'cookie', 'name': 'd', 'cookie_domain': 'slack.com'},
            ],
            'pattern': r'^xoxd-[a-zA-Z0-9/+=]+$',
          },
        ],
        'extract_js': 'new Promise(r => r({}))',
      },
    });

LoginStep instagramStep() => LoginStep.fromJson({
      'login_id': 'L2',
      'type': 'cookies',
      'step_id': 'fi.mau.instagram.cookies',
      'cookies': {
        'url': 'https://www.instagram.com/accounts/login/',
        'wait_for_url_pattern': r'^https://www\.instagram\.com/(?:\?.*)?$',
        'fields': [
          {'id': 'sessionid', 'required': true, 'sources': [{'type': 'cookie', 'name': 'sessionid', 'cookie_domain': 'instagram.com'}]},
          {'id': 'csrftoken', 'required': true, 'sources': [{'type': 'cookie', 'name': 'csrftoken', 'cookie_domain': 'instagram.com'}]},
          {'id': 'mid', 'required': false, 'sources': [{'type': 'cookie', 'name': 'mid', 'cookie_domain': 'instagram.com'}]},
        ],
        'initial_cookies': [
          {'name': 'ig_did', 'value': 'abc', 'domain': '.instagram.com', 'secure': true, 'http_only': true},
        ],
      },
    });

void main() {
  test('parses a cookies step', () {
    final step = instagramStep();
    final p = step.cookies!;
    expect(p.url, 'https://www.instagram.com/accounts/login/');
    expect(p.userAgent, isNull);
    expect(p.fields.map((f) => f.id), ['sessionid', 'csrftoken', 'mid']);
    expect(p.fields.first.sources.single.cookieDomain, 'instagram.com');
    expect(p.initialCookies.single.httpOnly, isTrue);
    expect(p.hidden, isFalse);
  });

  test('cookie values fill fields on the right domain only', () {
    final c = CookieCollector(instagramStep().cookies!);
    expect(c.cookieNames, {'instagram.com': {'sessionid', 'csrftoken', 'mid'}});
    expect(c.offer('cookie', 'sessionid', 'S', domain: '.facebook.com'), isFalse);
    expect(c.offer('cookie', 'sessionid', 'S', domain: '.instagram.com'), isTrue);
    expect(c.offer('cookie', 'sessionid', 'S', domain: 'www.instagram.com'), isFalse, reason: 'unchanged');
    expect(c.hasRequired, isFalse);
    c.offer('cookie', 'csrftoken', 'T', domain: 'instagram.com');
    expect(c.hasRequired, isTrue);
    expect(c.values, {'sessionid': 'S', 'csrftoken': 'T'});
  });

  test('waits for the URL the bridge names before submitting by itself', () {
    final c = CookieCollector(instagramStep().cookies!);
    c.offer('cookie', 'sessionid', 'S', domain: 'instagram.com');
    c.offer('cookie', 'csrftoken', 'T', domain: 'instagram.com');
    expect(c.readyAt('https://www.instagram.com/accounts/login/two_factor'), isFalse);
    expect(c.readyAt('https://www.instagram.com/'), isTrue);
  });

  test('request values must match the URL pattern and the field pattern', () {
    final c = CookieCollector(slackStep().cookies!);
    expect(c.requestSources.single.name, 'token');
    expect(c.offer('request_body', 'token', 'xoxc-1', url: 'https://evil.example/api/client.boot'), isFalse);
    expect(c.offer('request_body', 'token', 'nope', url: 'https://acme.slack.com/api/client.boot'), isFalse);
    expect(c.offer('request_body', 'token', 'xoxc-1', url: 'https://acme.slack.com/api/client.boot'), isTrue);
    expect(c.offer('cookie', 'd', 'xoxd-abc%2B', domain: '.slack.com'), isFalse, reason: 'pattern rejects %');
    expect(c.offer('cookie', 'd', 'xoxd-abc+', domain: '.slack.com'), isTrue);
    expect(c.readyAt('https://acme.slack.com/'), isTrue, reason: 'no URL to wait for');
  });

  test("the extraction script's result fills fields by ID", () {
    final c = CookieCollector(slackStep().cookies!);
    expect(c.offerExtracted({'auth_token': 'xoxc-2', 'other': 'x'}), isTrue);
    expect(c.values, {'auth_token': 'xoxc-2'});
    expect(c.offerExtracted({'auth_token': 'bad'}), isFalse);
  });

  test('the request hook names what it looks for', () {
    final js = requestHookScript(CookieCollector(slackStep().cookies!).requestSources);
    expect(js, contains('"name":"token"'));
    expect(js, contains('sbFound'));
  });
}
