// Package yamlmerge overlays one YAML document onto another while keeping the
// base document's comments, so upstream example configs stay readable.
package yamlmerge

import (
	"fmt"
	"strings"

	"gopkg.in/yaml.v3"
)

// ReplaceTag marks an overlay value that replaces the base value wholesale
// instead of being merged key by key. Use it for free-form maps such as
// bridge permissions, whose keys never exist in the upstream example.
const ReplaceTag = "!replace"

// UnknownKeyError reports an overlay key that the base document lacks. It
// usually means upstream renamed or removed a setting.
type UnknownKeyError struct{ Path string }

func (e *UnknownKeyError) Error() string {
	return fmt.Sprintf("overlay key %q does not exist in the base config", e.Path)
}

// Merge applies overlay onto base in place.
func Merge(base, overlay *yaml.Node) error {
	return merge(unwrap(base), unwrap(overlay), "")
}

func unwrap(n *yaml.Node) *yaml.Node {
	if n.Kind == yaml.DocumentNode && len(n.Content) > 0 {
		return n.Content[0]
	}
	return n
}

func merge(base, overlay *yaml.Node, path string) error {
	if base.Kind != yaml.MappingNode || overlay.Kind != yaml.MappingNode {
		return fmt.Errorf("%s: both sides must be mappings", displayPath(path))
	}
	for i := 0; i+1 < len(overlay.Content); i += 2 {
		key, val := overlay.Content[i], overlay.Content[i+1]
		p := joinPath(path, key.Value)
		target := Lookup(base, key.Value)
		if target == nil {
			return &UnknownKeyError{Path: p}
		}
		switch {
		case val.Tag == ReplaceTag:
			replace(target, val)
		case val.Kind == yaml.MappingNode && target.Kind == yaml.MappingNode:
			if err := merge(target, val, p); err != nil {
				return err
			}
		default:
			replace(target, val)
		}
	}
	return nil
}

// replace overwrites target with val but keeps target's comments.
func replace(target, val *yaml.Node) {
	head, line, foot := target.HeadComment, target.LineComment, target.FootComment
	*target = *val
	if target.Tag == ReplaceTag {
		target.Tag = ""
	}
	target.Style &^= yaml.FlowStyle
	target.HeadComment, target.LineComment, target.FootComment = head, line, foot
}

// Lookup returns the value node for key in a mapping, or nil.
func Lookup(m *yaml.Node, key string) *yaml.Node {
	m = unwrap(m)
	if m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// LookupPath follows a dotted path such as "appservice.port".
func LookupPath(n *yaml.Node, path string) *yaml.Node {
	for _, part := range strings.Split(path, ".") {
		if n = Lookup(n, part); n == nil {
			return nil
		}
	}
	return n
}

func joinPath(parent, key string) string {
	if parent == "" {
		return key
	}
	return parent + "." + key
}

func displayPath(p string) string {
	if p == "" {
		return "(root)"
	}
	return p
}
