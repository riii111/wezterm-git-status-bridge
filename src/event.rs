use std::path::PathBuf;

use serde_json::Value;
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaneContext {
    pub pane_id: String,
    pub cwd: PathBuf,
}

#[derive(Debug, Error)]
pub enum EventError {
    #[error("failed to parse Herdr plugin event JSON: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn parse_event_json(json: &str) -> Result<Option<PaneContext>, EventError> {
    if json.trim().is_empty() {
        return Ok(None);
    }

    let value: Value = serde_json::from_str(json)?;
    Ok(pane_context_from_value(&value))
}

pub fn pane_context_from_value(value: &Value) -> Option<PaneContext> {
    if let Some(context) = focused_pane_context_from_list(value) {
        return Some(context);
    }

    for path in [
        vec!["focused_pane"],
        vec!["result", "pane"],
        vec!["pane"],
        vec![],
    ] {
        let Some(candidate) = value_at(value, &path) else {
            continue;
        };
        if let Some(context) = pane_context_from_object(candidate) {
            return Some(context);
        }
    }

    None
}

fn focused_pane_context_from_list(value: &Value) -> Option<PaneContext> {
    value_at(value, &["result", "panes"])?
        .as_array()?
        .iter()
        .filter(|pane| {
            pane.get("focused")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .find_map(pane_context_from_object)
}

fn pane_context_from_object(value: &Value) -> Option<PaneContext> {
    let pane_id = string_at(value, &["pane_id"])?;
    let cwd = first_string(value, &[&["foreground_cwd"], &["cwd"]])?;

    Some(PaneContext {
        pane_id: pane_id.to_owned(),
        cwd: PathBuf::from(cwd),
    })
}

fn value_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
}

fn first_string<'a>(value: &'a Value, paths: &[&[&str]]) -> Option<&'a str> {
    paths.iter().find_map(|path| string_at(value, path))
}

fn string_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::parse_event_json;

    #[test]
    fn reads_pane_context_from_direct_pane_event() {
        let context = parse_event_json(
            r#"{"pane":{"pane_id":"w1:p1","foreground_cwd":"/repo","cwd":"/fallback"}}"#,
        )
        .expect("parse event")
        .expect("context");

        assert_eq!(context.pane_id, "w1:p1");
        assert_eq!(context.cwd, std::path::PathBuf::from("/repo"));
    }

    #[test]
    fn falls_back_to_focused_pane_context() {
        let context = parse_event_json(r#"{"focused_pane":{"pane_id":"w2:p3","cwd":"/focused"}}"#)
            .expect("parse event")
            .expect("context");

        assert_eq!(context.pane_id, "w2:p3");
        assert_eq!(context.cwd, std::path::PathBuf::from("/focused"));
    }

    #[test]
    fn does_not_mix_pane_id_and_cwd_from_different_objects() {
        let context = parse_event_json(
            r#"{"pane":{"pane_id":"w1:p1"},"focused_pane":{"pane_id":"w2:p2","cwd":"/focused"}}"#,
        )
        .expect("parse event")
        .expect("context");

        assert_eq!(context.pane_id, "w2:p2");
        assert_eq!(context.cwd, std::path::PathBuf::from("/focused"));
    }

    #[test]
    fn prefers_focused_pane_over_event_pane() {
        let context = parse_event_json(
            r#"{"pane":{"pane_id":"w1:p1","cwd":"/event"},"focused_pane":{"pane_id":"w2:p2","cwd":"/focused"}}"#,
        )
        .expect("parse event")
        .expect("context");

        assert_eq!(context.pane_id, "w2:p2");
        assert_eq!(context.cwd, std::path::PathBuf::from("/focused"));
    }

    #[test]
    fn reads_top_level_pane_context_from_pane_list_item() {
        let context = parse_event_json(r#"{"pane_id":"w3:p4","foreground_cwd":"/current"}"#)
            .expect("parse event")
            .expect("context");

        assert_eq!(context.pane_id, "w3:p4");
        assert_eq!(context.cwd, std::path::PathBuf::from("/current"));
    }

    #[test]
    fn reads_focused_pane_context_from_pane_list() {
        let context = parse_event_json(
            r#"{"result":{"panes":[{"pane_id":"w1:p1","cwd":"/old","focused":false},{"pane_id":"w2:p2","foreground_cwd":"/focused","focused":true}]}}"#,
        )
        .expect("parse event")
        .expect("context");

        assert_eq!(context.pane_id, "w2:p2");
        assert_eq!(context.cwd, std::path::PathBuf::from("/focused"));
    }

    #[test]
    fn returns_none_when_required_fields_are_missing() {
        let context = parse_event_json(r#"{"pane":{"pane_id":"w1:p1"}}"#).expect("parse event");

        assert_eq!(context, None);
    }
}
