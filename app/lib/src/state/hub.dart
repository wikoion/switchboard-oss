// The Hub API: bridge health, accounts and the bridgev2 login flow.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/api/client.dart';
import '../rust/api/types.dart';
import 'session.dart';

class HubException implements Exception {
  HubException(this.message, {this.status, this.code});
  final String message;
  final int? status;

  /// The Matrix-style `errcode`, when the answer carried one.
  final String? code;
  @override
  String toString() => message;
}

class LoginFlow {
  LoginFlow({required this.id, required this.name, required this.description});
  factory LoginFlow.fromJson(Map<String, dynamic> j) => LoginFlow(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        description: j['description'] as String? ?? '',
      );
  final String id;
  final String name;
  final String description;
}

class BridgeLogin {
  BridgeLogin({
    required this.id,
    required this.name,
    required this.state,
    this.message,
    this.phone,
    this.username,
    this.email,
    this.avatar,
    this.spaceRoom,
  });

  factory BridgeLogin.fromJson(Map<String, dynamic> j) {
    final state = (j['state'] as Map?)?.cast<String, dynamic>() ?? const {};
    final profile = (j['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
    return BridgeLogin(
      id: j['id'] as String,
      name: profile['name'] as String? ?? j['name'] as String? ?? j['id'] as String,
      state: state['state_event'] as String? ?? 'UNKNOWN',
      message: state['message'] as String? ?? state['error'] as String?,
      phone: profile['phone'] as String?,
      username: profile['username'] as String?,
      email: profile['email'] as String?,
      avatar: profile['avatar'] as String?,
      spaceRoom: j['space_room'] as String?,
    );
  }

  final String id;
  final String name;

  /// A bridge state event: CONNECTED, CONNECTING, BACKFILLING,
  /// TRANSIENT_DISCONNECT, BAD_CREDENTIALS, UNKNOWN_ERROR, LOGGED_OUT.
  final String state;
  final String? message;
  final String? phone;
  final String? username;
  final String? email;
  final String? avatar;

  /// The bridge's personal space for this account, holding its chats.
  final String? spaceRoom;

  /// Number, handle or email, whichever the network gives.
  String? get handle => phone ?? (username != null ? '@$username' : null) ?? email;
}

class Bridge {
  Bridge({
    required this.id,
    required this.network,
    required this.reachable,
    required this.supportsApi,
    this.error,
    this.iconMxc,
    this.botUserId,
    this.networkId,
    this.flows = const [],
    this.logins = const [],
  });

  factory Bridge.fromJson(Map<String, dynamic> j) {
    final whoami = (j['whoami'] as Map?)?.cast<String, dynamic>() ?? const {};
    final network = (whoami['network'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Bridge(
      id: j['id'] as String,
      network: network['displayname'] as String? ?? j['network'] as String? ?? j['id'] as String,
      reachable: j['reachable'] as bool? ?? false,
      supportsApi: j['provisioning'] == 'api',
      error: j['error'] as String?,
      iconMxc: network['network_icon'] as String?,
      botUserId: whoami['bridge_bot'] as String?,
      // Rooms' m.bridge carries the bridge type (instagramgo, slackgo),
      // which isn't always the network ID (instagram, slack).
      networkId: network['beeper_bridge_type'] as String? ?? network['network_id'] as String?,
      flows: [
        for (final f in (whoami['login_flows'] as List? ?? const []))
          LoginFlow.fromJson((f as Map).cast<String, dynamic>()),
      ],
      logins: [
        for (final l in (whoami['logins'] as List? ?? const []))
          BridgeLogin.fromJson((l as Map).cast<String, dynamic>()),
      ],
    );
  }

  final String id;
  final String network;
  final bool reachable;
  final bool supportsApi;
  final String? error;
  final String? iconMxc;

  /// The bridge bot, whose DM is the bridge's management room.
  final String? botUserId;

  /// The protocol ID rooms carry in `m.bridge`, such as `whatsapp` or
  /// `instagramgo`: the bridge type.
  final String? networkId;
  String get protocolId => networkId ?? id;
  final List<LoginFlow> flows;
  final List<BridgeLogin> logins;

  /// Whether this network has channels that are bridged one by one, chosen
  /// in Settings. Their DMs always bridge.
  bool get hasChannels =>
      supportsApi && channelNetworks.any((n) => id == n || protocolId == n || protocolId == '${n}go');
}

/// Networks whose bridges take a per-channel selection. Both are built in
/// this repository (`bridges/discord`, `bridges/slack`) with the same
/// `switchboard/v1/channels` provisioning endpoints.
const channelNetworks = {'discord', 'slack'};

/// A channel a linked account can see, and whether its bridge passes it on.
class BridgeChannel {
  BridgeChannel({required this.id, required this.name, required this.selected, this.section, this.private = false});

  factory BridgeChannel.fromJson(Map<String, dynamic> j) => BridgeChannel(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        selected: j['selected'] as bool? ?? false,
        section: (j['section'] as String?)?.nullIfEmpty,
        private: j['private'] as bool? ?? false,
      );

  final String id;
  final String name;

  /// What the bridge has saved, not what was last tapped.
  final bool selected;

  /// A Discord category, when the channel is in one.
  final String? section;
  final bool private;
}

/// A Discord server or Slack workspace, with the channels the account can
/// see in it. Two servers can each have a #general; the group tells them
/// apart.
class ChannelGroup {
  ChannelGroup({required this.id, required this.name, required this.channels});

  factory ChannelGroup.fromJson(Map<String, dynamic> j) => ChannelGroup(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        channels: [
          for (final c in (j['channels'] as List? ?? const []))
            BridgeChannel.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String name;
  final List<BridgeChannel> channels;
}

class InputField {
  InputField({
    required this.type,
    required this.id,
    required this.name,
    this.description,
    this.defaultValue,
    this.optional = false,
    this.pattern,
    this.options = const [],
  });

  factory InputField.fromJson(Map<String, dynamic> j) => InputField(
        type: j['type'] as String? ?? 'token',
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        description: j['description'] as String?,
        defaultValue: j['default_value'] as String?,
        optional: j['optional'] as bool? ?? false,
        pattern: j['pattern'] as String?,
        options: [for (final o in (j['options'] as List? ?? const [])) o as String],
      );

  /// username, phone_number, email, password, 2fa_code, token, url, domain
  /// or select.
  final String type;
  final String id;
  final String name;
  final String? description;
  final String? defaultValue;
  final bool optional;
  final String? pattern;
  final List<String> options;
}

/// Where a web login finds one value: a cookie, local storage, a request
/// header or body, or the result of the bridge's extraction script
/// (`special`).
class CookieSource {
  CookieSource({required this.type, required this.name, this.requestUrlRegex, this.cookieDomain});
  factory CookieSource.fromJson(Map<String, dynamic> j) => CookieSource(
        type: j['type'] as String? ?? '',
        name: j['name'] as String? ?? '',
        requestUrlRegex: j['request_url_regex'] as String?,
        cookieDomain: j['cookie_domain'] as String?,
      );
  final String type;
  final String name;
  final String? requestUrlRegex;
  final String? cookieDomain;
}

class CookieField {
  CookieField({required this.id, required this.required, required this.sources, this.pattern});
  factory CookieField.fromJson(Map<String, dynamic> j) => CookieField(
        id: j['id'] as String,
        required: j['required'] as bool? ?? false,
        sources: [
          for (final s in (j['sources'] as List? ?? const []))
            CookieSource.fromJson((s as Map).cast<String, dynamic>()),
        ],
        pattern: j['pattern'] as String?,
      );
  final String id;
  final bool required;
  final List<CookieSource> sources;
  final String? pattern;

  /// Whether [value] is acceptable for this field.
  bool accepts(String value) {
    if (value.isEmpty) return false;
    final p = pattern;
    return p == null || RegExp(p).hasMatch(value);
  }
}

/// A cookie the web view sets before loading, to continue a login started
/// elsewhere (a captcha or checkpoint).
class InitialCookie {
  InitialCookie({required this.name, required this.value, required this.domain, this.path, this.secure = false, this.httpOnly = false});
  factory InitialCookie.fromJson(Map<String, dynamic> j) => InitialCookie(
        name: j['name'] as String,
        value: j['value'] as String? ?? '',
        domain: j['domain'] as String? ?? '',
        path: j['path'] as String?,
        secure: j['secure'] as bool? ?? false,
        httpOnly: j['http_only'] as bool? ?? false,
      );
  final String name;
  final String value;
  final String domain;
  final String? path;
  final bool secure;
  final bool httpOnly;
}

/// What a `cookies` step asks for: sign in on a web page, from which the
/// app collects the listed values.
class CookieParams {
  CookieParams({
    required this.url,
    this.userAgent,
    this.fields = const [],
    this.initialCookies = const [],
    this.extractJs,
    this.waitForUrlPattern,
    this.hidden = false,
  });
  factory CookieParams.fromJson(Map<String, dynamic> j) => CookieParams(
        url: j['url'] as String? ?? '',
        userAgent: (j['user_agent'] as String?)?.nullIfEmpty,
        fields: [
          for (final f in (j['fields'] as List? ?? const []))
            CookieField.fromJson((f as Map).cast<String, dynamic>()),
        ],
        initialCookies: [
          for (final c in (j['initial_cookies'] as List? ?? const []))
            InitialCookie.fromJson((c as Map).cast<String, dynamic>()),
        ],
        extractJs: (j['extract_js'] as String?)?.nullIfEmpty,
        waitForUrlPattern: (j['wait_for_url_pattern'] as String?)?.nullIfEmpty,
        hidden: j['hidden'] as bool? ?? false,
      );
  final String url;
  final String? userAgent;
  final List<CookieField> fields;
  final List<InitialCookie> initialCookies;
  final String? extractJs;
  final String? waitForUrlPattern;
  final bool hidden;
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// One step of a bridgev2 login process.
class LoginStep {
  LoginStep({
    required this.loginId,
    required this.type,
    required this.stepId,
    required this.instructions,
    this.displayType,
    this.displayData,
    this.displayImageUrl,
    this.canCancel = true,
    this.fields = const [],
    this.cookies,
    this.userLoginId,
  });

  factory LoginStep.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String;
    final display = (j['display_and_wait'] as Map?)?.cast<String, dynamic>();
    final input = (j['user_input'] as Map?)?.cast<String, dynamic>();
    final complete = (j['complete'] as Map?)?.cast<String, dynamic>();
    final cookies = (j['cookies'] as Map?)?.cast<String, dynamic>();
    return LoginStep(
      loginId: j['login_id'] as String? ?? '',
      type: type,
      stepId: j['step_id'] as String? ?? '',
      instructions: j['instructions'] as String? ?? '',
      displayType: display?['type'] as String?,
      displayData: display?['data'] as String?,
      displayImageUrl: display?['image_url'] as String?,
      canCancel: (display ?? input)?['can_cancel'] as bool? ?? true,
      fields: [
        for (final f in (input?['fields'] as List? ?? const []))
          InputField.fromJson((f as Map).cast<String, dynamic>()),
      ],
      cookies: cookies == null ? null : CookieParams.fromJson(cookies),
      userLoginId: complete?['user_login_id'] as String?,
    );
  }

  final String loginId;

  /// display_and_wait, user_input, cookies, client_http, webauthn or
  /// complete.
  final String type;
  final String stepId;
  final String instructions;

  /// For display_and_wait: qr, emoji, code or nothing.
  final String? displayType;
  final String? displayData;
  final String? displayImageUrl;
  final bool canCancel;
  final List<InputField> fields;

  /// For a cookies step: the page to sign in on and what to collect.
  final CookieParams? cookies;
  final String? userLoginId;
}

/// Sends one request to the Hub: method, path under /_switchboard/v1, and
/// an optional JSON body.
typedef HubSend = Future<HubResponse> Function(String method, String path, String? body);

class HubApi {
  HubApi(this._send);

  /// Calls through the core, which holds the access token.
  HubApi.core(SwitchboardCore core)
      : _send = ((method, path, body) => core.hub(method: method, path: path, body: body));

  final HubSend _send;

  Future<dynamic> _call(String method, String path, [Object? body]) async {
    final resp = await _send(method, path, body == null ? null : jsonEncode(body));
    final decoded = resp.body.isEmpty ? null : _tryDecode(resp.body);
    if (resp.status >= 400) {
      final msg = decoded is Map ? (decoded['error'] ?? decoded['errcode']) : null;
      final code = decoded is Map ? decoded['errcode'] : null;
      throw HubException(msg?.toString() ?? 'HTTP ${resp.status}', status: resp.status, code: code?.toString());
    }
    return decoded;
  }

  static dynamic _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } on FormatException {
      return s;
    }
  }

  String _p(String bridge, String rest) => '/bridges/${Uri.encodeComponent(bridge)}/provision/v3/$rest';

  Future<List<Bridge>> bridges() async {
    final j = await _call('GET', '/bridges') as Map;
    return [
      for (final b in (j['bridges'] as List? ?? const []))
        Bridge.fromJson((b as Map).cast<String, dynamic>()),
    ];
  }

  /// Starts a login. Pass [loginId] to relink an existing account.
  Future<LoginStep> start(String bridge, String flowId, {String? loginId}) async {
    final q = loginId == null ? '' : '?login_id=${Uri.encodeQueryComponent(loginId)}';
    final j = await _call('POST', _p(bridge, 'login/start/${Uri.encodeComponent(flowId)}$q'), {});
    return LoginStep.fromJson((j as Map).cast<String, dynamic>());
  }

  /// Waits for the phone to act on a display_and_wait step. A long poll.
  Future<LoginStep> wait(String bridge, LoginStep step) => _step(bridge, step, 'display_and_wait', {});

  Future<LoginStep> submitInput(String bridge, LoginStep step, Map<String, String> values) =>
      _step(bridge, step, 'user_input', values);

  /// Sends what a web login collected, keyed by field ID.
  Future<LoginStep> submitCookies(String bridge, LoginStep step, Map<String, String> values) =>
      _step(bridge, step, 'cookies', values);

  Future<LoginStep> _step(String bridge, LoginStep step, String kind, Map<String, Object?> body) async {
    final path = _p(bridge,
        'login/step/${Uri.encodeComponent(step.loginId)}/${Uri.encodeComponent(step.stepId)}/$kind');
    final j = await _call('POST', path, body);
    return LoginStep.fromJson((j as Map).cast<String, dynamic>());
  }

  /// Asks the bridge to fetch media it only sent a stand-in for (an
  /// Instagram reel's still, say). The bridge replaces the message with the
  /// real media; this returns once it has. [unresolved] is the message's
  /// `com.beeper.unresolved_media` JSON.
  Future<void> resolveMedia(String bridge, String eventId, String unresolved, {String? loginId}) async {
    final q = loginId == null ? '' : '?login_id=${Uri.encodeQueryComponent(loginId)}';
    await _call('POST', _p(bridge, 'resolve_media/${Uri.encodeComponent(eventId)}$q'), {
      'com.beeper.unresolved_media': jsonDecode(unresolved),
    });
  }

  Future<void> cancel(String bridge, String loginId) async {
    await _call('POST', _p(bridge, 'login/cancel/${Uri.encodeComponent(loginId)}'), {});
  }

  Future<void> logout(String bridge, String loginId) async {
    await _call('POST', _p(bridge, 'logout/${Uri.encodeComponent(loginId)}'), {});
  }

  String _channels(String bridge, String loginId, [String rest = '']) =>
      '/bridges/${Uri.encodeComponent(bridge)}/provision/switchboard/v1/channels$rest'
      '?login_id=${Uri.encodeQueryComponent(loginId)}';

  /// The channels an account can see, by server or workspace, each with
  /// whether the bridge has it selected.
  Future<List<ChannelGroup>> channels(String bridge, String loginId) async {
    final j = await _call('GET', _channels(bridge, loginId));
    if (j is! Map) throw HubException("The bridge didn't list its channels");
    return [
      for (final g in (j['groups'] as List? ?? const []))
        ChannelGroup.fromJson((g as Map).cast<String, dynamic>()),
    ];
  }

  /// Starts or stops bridging one channel, and returns what the bridge
  /// saved. Stopping keeps the chat and its history.
  Future<bool> setChannelBridged(
    String bridge,
    String loginId,
    String groupId,
    String channelId, {
    required bool bridged,
  }) async {
    final path = _channels(bridge, loginId, '/${Uri.encodeComponent(groupId)}/${Uri.encodeComponent(channelId)}');
    final j = await _call(bridged ? 'PUT' : 'DELETE', path);
    final saved = j is Map ? j['selected'] : null;
    if (saved is! bool) throw HubException("The bridge didn't confirm the change");
    return saved;
  }
}

final hubProvider = Provider<HubApi>((ref) => HubApi.core(ref.watch(coreProvider)));

/// The Hub's live events, as decoded JSON. A `connected` event follows each
/// (re)connection.
final hubEventsProvider = StreamProvider<Map<String, dynamic>>((ref) {
  return ref
      .watch(coreProvider)
      .subscribeHubEvents()
      .map((s) => (jsonDecode(s) as Map).cast<String, dynamic>());
});

/// Every enabled bridge with its logins, refetched whenever the Hub reports
/// a change.
final bridgesProvider = FutureProvider<List<Bridge>>((ref) {
  ref.listen(hubEventsProvider, (_, _) => ref.invalidateSelf());
  return ref.watch(hubProvider).bridges();
});

/// One linked account, as the channel settings key it.
typedef ChannelAccount = ({String bridge, String login});

/// The channels one account can see and which of them are bridged. Fetched
/// from the bridge each time Settings opens: the bridge holds the
/// selection, so it is the same after a relaunch and on every device.
final channelsProvider = FutureProvider.autoDispose.family<List<ChannelGroup>, ChannelAccount>(
  (ref, account) => ref.watch(hubProvider).channels(account.bridge, account.login),
  // A failure stays on screen with its own "Try again", instead of
  // flickering back to loading while Riverpod retries behind it.
  retry: (_, _) => null,
);

/// Something wrong with an account or bridge, for the inbox.
class AccountProblem {
  const AccountProblem(this.bridge, this.message, {this.login});
  final Bridge bridge;
  final BridgeLogin? login;
  final String message;
}

/// Logins that need relinking or have failed, and bridges that aren't
/// answering. Brief reconnects (TRANSIENT_DISCONNECT) don't count.
List<AccountProblem> accountProblems(List<Bridge> bridges) => [
      for (final b in bridges) ...[
        if (b.supportsApi && !b.reachable) AccountProblem(b, "${b.network} isn't responding"),
        for (final l in b.logins)
          if (l.state == 'BAD_CREDENTIALS' || l.state == 'LOGGED_OUT')
            AccountProblem(b, '${b.network} needs relinking', login: l)
          else if (l.state == 'UNKNOWN_ERROR')
            AccountProblem(b, '${b.network} has a problem', login: l),
      ],
    ];

/// A sidebar status dot: green connected, amber reconnecting, red needs
/// relinking or isn't answering. Ordered best to worst.
enum Health { connected, reconnecting, broken }

Health? loginHealth(BridgeLogin l) => switch (l.state) {
      'CONNECTED' || 'BACKFILLING' => Health.connected,
      'CONNECTING' || 'TRANSIENT_DISCONNECT' => Health.reconnecting,
      'BAD_CREDENTIALS' || 'LOGGED_OUT' || 'UNKNOWN_ERROR' => Health.broken,
      _ => null,
    };

/// The worst state across a network's bridges and logins, or null when
/// there is nothing to report.
Health? networkHealth(List<Bridge> bridges, String networkId) {
  Health? worst;
  for (final b in bridges) {
    if (b.protocolId != networkId) continue;
    if (b.supportsApi && !b.reachable) return Health.broken;
    for (final l in b.logins) {
      final h = loginHealth(l);
      if (h != null && (worst == null || h.index > worst.index)) worst = h;
    }
  }
  return worst;
}
