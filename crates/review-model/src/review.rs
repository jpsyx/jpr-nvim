//! Review-level types: reactions, review submission events, mention
//! candidates, and the submit preview read model.

use serde::{Deserialize, Serialize};

use crate::Anchor;

/// One of GitHub's eight comment reactions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReactionContent {
    /// `+1` thumbs up.
    ThumbsUp,
    /// `-1` thumbs down.
    ThumbsDown,
    /// Laugh face.
    Laugh,
    /// Celebration hooray.
    Hooray,
    /// Confused face.
    Confused,
    /// Heart.
    Heart,
    /// Rocket.
    Rocket,
    /// Eyes.
    Eyes,
}

impl ReactionContent {
    /// Every reaction GitHub supports, in picker order.
    pub const ALL: [Self; 8] = [
        Self::ThumbsUp,
        Self::ThumbsDown,
        Self::Laugh,
        Self::Hooray,
        Self::Confused,
        Self::Heart,
        Self::Rocket,
        Self::Eyes,
    ];

    /// Parses GitHub's `ReactionContent` spelling, returning `None` for
    /// unknown strings, for example when decoding GraphQL or RPC reactions.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "THUMBS_UP" => Some(Self::ThumbsUp),
            "THUMBS_DOWN" => Some(Self::ThumbsDown),
            "LAUGH" => Some(Self::Laugh),
            "HOORAY" => Some(Self::Hooray),
            "CONFUSED" => Some(Self::Confused),
            "HEART" => Some(Self::Heart),
            "ROCKET" => Some(Self::Rocket),
            "EYES" => Some(Self::Eyes),
            _ => None,
        }
    }

    /// Returns GitHub's GraphQL `ReactionContent` spelling, for example when
    /// building reaction mutation variables.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ThumbsUp => "THUMBS_UP",
            Self::ThumbsDown => "THUMBS_DOWN",
            Self::Laugh => "LAUGH",
            Self::Hooray => "HOORAY",
            Self::Confused => "CONFUSED",
            Self::Heart => "HEART",
            Self::Rocket => "ROCKET",
            Self::Eyes => "EYES",
        }
    }

    /// Short display glyph for popups and virtual text.
    #[must_use]
    pub const fn emoji(self) -> &'static str {
        match self {
            Self::ThumbsUp => "👍",
            Self::ThumbsDown => "👎",
            Self::Laugh => "😄",
            Self::Hooray => "🎉",
            Self::Confused => "😕",
            Self::Heart => "❤️",
            Self::Rocket => "🚀",
            Self::Eyes => "👀",
        }
    }
}

/// Aggregated count for one reaction kind on a message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reaction {
    /// Which reaction this count represents.
    pub content: ReactionContent,
    /// How many accounts reacted with it.
    pub count: u32,
    /// Whether the current reviewer reacted with it.
    pub viewer_has_reacted: bool,
}

/// The verdict chosen when submitting a pull-request review.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReviewEvent {
    /// Post general feedback without explicit approval.
    Comment,
    /// Approve merging the pull request.
    Approve,
    /// Request changes before merging.
    RequestChanges,
}

impl ReviewEvent {
    /// Parses `"COMMENT"`, `"APPROVE"`, or `"REQUEST_CHANGES"`, returning
    /// `None` otherwise, for example when reading review submission inputs.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "COMMENT" => Some(Self::Comment),
            "APPROVE" => Some(Self::Approve),
            "REQUEST_CHANGES" => Some(Self::RequestChanges),
            _ => None,
        }
    }

    /// Returns GitHub's GraphQL `PullRequestReviewEvent` spelling, for example
    /// when submitting a pull-request review mutation.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Comment => "COMMENT",
            Self::Approve => "APPROVE",
            Self::RequestChanges => "REQUEST_CHANGES",
        }
    }
}

/// An account `@` completion offers while composing a comment.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MentionCandidate {
    /// Handle without a leading `@`, such as `alice` or `renovate[bot]`.
    pub login: String,
    /// Whether the account has already participated in this pull request.
    pub is_participant: bool,
}

/// One pending draft comment listed in a review-submission preview, for example
/// in a confirmation dialog before publishing a review.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitDraft {
    /// The thread holding the draft.
    pub thread_id: String,
    /// The draft message's id.
    pub message_id: String,
    /// Where the draft is attached, so a frontend can jump to it from the preview.
    pub anchor: Anchor,
    /// One-line snippet of the draft body.
    pub snippet: String,
}

/// Pending draft summaries and submission guards for a review-submission
/// prompt, such as disabling approval on self-reviews or blocking while
/// comments are still syncing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubmitPreview {
    /// Number of pending draft comments in the review.
    pub draft_count: usize,
    /// Every pending draft message, in display order.
    pub drafts: Vec<SubmitDraft>,
    /// False when the authenticated viewer authored the pull request.
    pub can_approve_or_request_changes: bool,
    /// Reason submission must wait (when any comment is still `pending`,
    /// `queued`, or `failed`), or `None` when ready to submit.
    pub blocked_reason: Option<String>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::Anchor;

    #[test]
    fn reaction_contents_parse_and_serialize_as_github_spells_them() {
        for content in ReactionContent::ALL {
            let text = content.as_str();
            assert_eq!(ReactionContent::parse(text), Some(content));
            assert_eq!(serde_json::to_value(content).unwrap(), json!(text));
            assert_ne!(content.emoji(), "");
        }
        assert_eq!(ReactionContent::parse("PARTY"), None);
    }

    #[test]
    fn review_events_parse_and_serialize_in_screaming_snake_case() {
        assert_eq!(ReviewEvent::parse("COMMENT"), Some(ReviewEvent::Comment));
        assert_eq!(ReviewEvent::parse("APPROVE"), Some(ReviewEvent::Approve));
        assert_eq!(
            ReviewEvent::parse("REQUEST_CHANGES"),
            Some(ReviewEvent::RequestChanges)
        );
        assert_eq!(ReviewEvent::parse("DISMISS"), None);
        assert_eq!(
            serde_json::to_value(ReviewEvent::RequestChanges).unwrap(),
            json!("REQUEST_CHANGES")
        );
    }

    #[test]
    fn submit_preview_uses_camel_case_keys() {
        let preview = SubmitPreview {
            draft_count: 1,
            drafts: vec![SubmitDraft {
                thread_id: "T1".into(),
                message_id: "M1".into(),
                anchor: Anchor::line("src/a.rs", 4),
                snippet: "nit: rename".into(),
            }],
            can_approve_or_request_changes: true,
            blocked_reason: None,
        };
        let value = serde_json::to_value(&preview).unwrap();
        assert_eq!(value["draftCount"], 1);
        assert_eq!(value["drafts"][0]["threadId"], "T1");
        assert_eq!(value["drafts"][0]["messageId"], "M1");
        assert_eq!(value["drafts"][0]["snippet"], "nit: rename");
        assert_eq!(value["canApproveOrRequestChanges"], true);
        assert!(value["blockedReason"].is_null());
    }

    #[test]
    fn mention_candidate_uses_camel_case_keys() {
        let candidate = MentionCandidate {
            login: "pablo".into(),
            is_participant: true,
        };
        assert_eq!(
            serde_json::to_value(&candidate).unwrap(),
            json!({ "login": "pablo", "isParticipant": true })
        );
    }
}
