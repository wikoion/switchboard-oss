//! A small server-sent events reader for the Hub's `/events` stream.

/// Collects the `data:` lines of server-sent events across chunks.
#[derive(Default)]
pub(crate) struct SseParser {
    line: Vec<u8>,
    data: Vec<String>,
}

impl SseParser {
    /// Feeds bytes in; returns the data of each event they complete.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        let mut out = Vec::new();
        for &b in bytes {
            if b != b'\n' {
                self.line.push(b);
                continue;
            }
            let line = String::from_utf8_lossy(&self.line).trim_end_matches('\r').to_owned();
            self.line.clear();
            if line.is_empty() {
                if !self.data.is_empty() {
                    out.push(self.data.join("\n"));
                    self.data.clear();
                }
            } else if let Some(d) = line.strip_prefix("data:") {
                self.data.push(d.strip_prefix(' ').unwrap_or(d).to_owned());
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_events_across_chunks() {
        let mut p = SseParser::default();
        assert!(p.feed(b": connected\n\nevent: bridge_state\nda").is_empty());
        assert_eq!(p.feed(b"ta: {\"a\":1}\n\n: keep-alive\n\ndata: x\r\ndata: y\n\n"), vec![r#"{"a":1}"#, "x\ny"]);
    }
}
