use std::process::Command;

use serde_json::Value;
use thiserror::Error;

use crate::event::{PaneContext, pane_context_from_value};

#[derive(Debug, Error)]
pub enum HerdrError {
    #[error("failed to run herdr pane list: {0}")]
    Io(#[from] std::io::Error),
    #[error("failed to parse herdr pane list JSON: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn focused_pane_from_cli(herdr_bin: &str) -> Result<Option<PaneContext>, HerdrError> {
    let output = Command::new(herdr_bin).args(["pane", "list"]).output()?;
    if !output.status.success() {
        return Ok(None);
    }

    focused_pane_from_json(&output.stdout)
}

pub fn focused_pane_from_json(json: &[u8]) -> Result<Option<PaneContext>, HerdrError> {
    let value: Value = serde_json::from_slice(json)?;
    let Some(panes) = value
        .get("result")
        .and_then(|result| result.get("panes"))
        .and_then(Value::as_array)
    else {
        return Ok(None);
    };

    Ok(panes
        .iter()
        .find(|pane| {
            pane.get("focused")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .and_then(pane_context_from_value))
}

#[cfg(test)]
mod tests {
    use super::focused_pane_from_json;

    #[test]
    fn reads_focused_pane_from_pane_list_response() {
        let context = focused_pane_from_json(
            br#"{
              "result": {
                "panes": [
                  {"pane_id":"w1:p1","focused":false,"foreground_cwd":"/old"},
                  {"pane_id":"w1:p2","focused":true,"foreground_cwd":"/current"}
                ]
              }
            }"#,
        )
        .expect("parse pane list")
        .expect("context");

        assert_eq!(context.pane_id, "w1:p2");
        assert_eq!(context.cwd, std::path::PathBuf::from("/current"));
    }

    #[test]
    fn returns_none_when_no_pane_is_focused() {
        let context =
            focused_pane_from_json(br#"{"result":{"panes":[]}}"#).expect("parse pane list");

        assert_eq!(context, None);
    }
}
