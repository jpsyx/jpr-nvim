//! A file's content as the diff sees it: missing, binary, or text.

/// How many leading bytes are searched for a NUL, as git does, to call a
/// file binary.
const BINARY_PROBE_BYTES: usize = 8000;

/// One side of a file's diff: the file at the base, or on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileText {
    /// The file does not exist on this side: it was added or deleted.
    Missing,
    /// The file holds bytes that are not text, so it has no line diff.
    Binary,
    /// The file's text. Invalid UTF-8 is replaced, not refused.
    Text(String),
}

impl FileText {
    /// Reads a file's bytes, or `None` when the file does not exist, as a
    /// workspace returns them.
    #[must_use]
    pub fn from_bytes(bytes: Option<Vec<u8>>) -> Self {
        match bytes {
            None => Self::Missing,
            Some(bytes) if bytes.iter().take(BINARY_PROBE_BYTES).any(|byte| *byte == 0) => {
                Self::Binary
            }
            Some(bytes) => Self::Text(
                String::from_utf8(bytes)
                    .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned()),
            ),
        }
    }

    /// Whether this side is binary.
    #[must_use]
    pub const fn is_binary(&self) -> bool {
        matches!(self, Self::Binary)
    }

    /// The text, for a side that has some.
    #[must_use]
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            Self::Missing | Self::Binary => None,
        }
    }

    /// The lines without their endings (`\n` or `\r\n`); none for a missing
    /// or binary side.
    #[must_use]
    pub fn lines(&self) -> Vec<&str> {
        self.as_text()
            .map(|text| text.lines().collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_bytes_are_a_missing_file() {
        assert_eq!(FileText::from_bytes(None), FileText::Missing);
    }

    #[test]
    fn a_nul_byte_makes_a_file_binary() {
        assert!(FileText::from_bytes(Some(b"PNG\0\x01".to_vec())).is_binary());
    }

    #[test]
    fn text_keeps_its_content_and_splits_into_lines() {
        let text = FileText::from_bytes(Some(b"one\r\ntwo\nthree".to_vec()));
        assert_eq!(text.lines(), ["one", "two", "three"]);
        assert_eq!(text.as_text(), Some("one\r\ntwo\nthree"));
    }

    #[test]
    fn invalid_utf8_is_replaced_not_refused() {
        let text = FileText::from_bytes(Some(vec![b'a', 0xff, b'b']));
        assert_eq!(text.as_text(), Some("a\u{fffd}b"));
    }

    #[test]
    fn a_missing_or_binary_side_has_no_lines() {
        assert_eq!(FileText::Missing.lines(), Vec::<&str>::new());
        assert_eq!(FileText::Binary.lines(), Vec::<&str>::new());
        assert_eq!(FileText::Binary.as_text(), None);
    }
}
