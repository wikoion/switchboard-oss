package connector

import (
	"testing"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func TestMapUserLinks(t *testing.T) {
	m := func(u id.UserID) (id.UserID, bool) {
		if u == "@alice:matrix.org" {
			return "@matrix_alice:switchboard.internal", true
		}
		return "", false
	}
	in := `<a href="https://matrix.to/#/@alice:matrix.org">Alice</a> and <a href="https://matrix.to/#/%40alice%3Amatrix.org">again</a>, not <a href="https://matrix.to/#/@bob:x.org">Bob</a> or <a href="https://matrix.to/#/#room:x.org">a room</a>`
	want := `<a href="https://matrix.to/#/@matrix_alice:switchboard.internal">Alice</a> and <a href="https://matrix.to/#/@matrix_alice:switchboard.internal">again</a>, not <a href="https://matrix.to/#/@bob:x.org">Bob</a> or <a href="https://matrix.to/#/#room:x.org">a room</a>`
	if got := mapUserLinks(in, m); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestMapMentionsDropsUnknownUsers(t *testing.T) {
	c := &event.MessageEventContent{Mentions: &event.Mentions{UserIDs: []id.UserID{"@a:x", "@b:x"}}}
	mapMentions(c, func(u id.UserID) (id.UserID, bool) { return u + "!", u == "@a:x" })
	if len(c.Mentions.UserIDs) != 1 || c.Mentions.UserIDs[0] != "@a:x!" {
		t.Fatalf("got %v", c.Mentions.UserIDs)
	}
}

func TestCloneContentLeavesOriginal(t *testing.T) {
	evt := &event.Event{Type: event.EventMessage, Content: event.Content{Parsed: &event.MessageEventContent{
		MsgType: event.MsgImage, Body: "x", Info: &event.FileInfo{MimeType: "image/png", ThumbnailURL: "mxc://a/b"},
	}}}
	c, err := cloneContent(evt)
	if err != nil {
		t.Fatal(err)
	}
	c.Info.ThumbnailURL = ""
	if evt.Content.AsMessage().Info.ThumbnailURL != "mxc://a/b" {
		t.Fatal("clone shares Info with the original")
	}
}

func TestHeroName(t *testing.T) {
	cases := map[string][]string{
		"":                     nil,
		"Ann":                  {"Ann"},
		"Ann, Bo, Cy":          {"Ann", "Bo", "Cy"},
		"Ann, Bo and 2 others": {"Ann", "Bo", "Cy", "Di"},
	}
	for want, in := range cases {
		if got := heroName(in); got != want {
			t.Errorf("heroName(%v) = %q, want %q", in, got, want)
		}
	}
}
