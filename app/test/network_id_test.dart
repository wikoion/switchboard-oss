import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/state/hub.dart';
import 'package:switchboard/src/ui/theme.dart';

void main() {
  test("a bridge's protocol ID is its bridge type, as rooms' m.bridge carries it", () {
    final b = Bridge.fromJson({
      'id': 'instagram',
      'network': 'Instagram',
      'reachable': true,
      'provisioning': 'api',
      'whoami': {
        'network': {'displayname': 'Instagram', 'network_id': 'instagram', 'beeper_bridge_type': 'instagramgo'},
      },
    });
    expect(b.protocolId, 'instagramgo');
    final old = Bridge.fromJson({
      'id': 'signal',
      'whoami': {'network': {'network_id': 'signal'}},
    });
    expect(old.protocolId, 'signal');
  });

  test('bridge types ending in go get their network badge', () {
    expect(canonicalNetwork('instagramgo'), 'instagram');
    expect(canonicalNetwork('slackgo'), 'slack');
    expect(canonicalNetwork('discordgo'), 'discord');
    expect(canonicalNetwork('whatsapp'), 'whatsapp');
    expect(canonicalNetwork('somethinggo'), 'somethinggo', reason: 'unknown networks stay as they are');
    expect(networkGlyph('instagramgo'), 'assets/networks/instagram.svg');
    expect(networkColor('slackgo'), networkColor('slack'));
  });
}
