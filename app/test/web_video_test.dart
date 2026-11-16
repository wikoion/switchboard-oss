import 'package:flutter_test/flutter_test.dart';
import 'package:switchboard/src/ui/web_video.dart';

void main() {
  test('Reddit links are recognised, other sites are not', () {
    expect(isRedditLink('https://www.reddit.com/r/videos/s/Kq4TzR8mWb'), isTrue);
    expect(isRedditLink('https://v.redd.it/7hk2m9qpz4wd1'), isTrue);
    expect(isRedditLink('https://old.reddit.com/r/x/comments/1/y/'), isTrue);
    expect(isRedditLink('https://notreddit.com/x'), isFalse);
    expect(isRedditLink('https://www.instagram.com/reel/X/'), isFalse);
  });

  test("on Linux the DASH manifest replaces HLS, keeping only the access token", () {
    expect(
      redditDashFor('https://v.redd.it/7hk2m9qpz4wd1/HLSPlaylist.m3u8?f=sd%2CsubsAll&v=1&a=1700000000%2CQWJj'),
      'https://v.redd.it/7hk2m9qpz4wd1/DASHPlaylist.mpd?a=1700000000%2CQWJj',
    );
    expect(redditDashFor('https://example.com/x.mp4'), 'https://example.com/x.mp4');
  });
}
