use std::fs;
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::payload::Payload;

#[derive(Debug, Error)]
pub enum CacheError {
    #[error("failed to update cache: {0}")]
    Io(#[from] std::io::Error),
}

pub fn default_cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("wezterm")
}

pub fn write_payload(cache_dir: &Path, payload: &Payload) -> Result<(), CacheError> {
    fs::create_dir_all(cache_dir)?;
    atomic_write(&cache_dir.join("herdr-git-info"), &payload.encode_line())?;

    let pane_cache_dir = cache_dir.join("herdr-git-info-by-pane");
    fs::create_dir_all(&pane_cache_dir)?;
    atomic_write(
        &pane_cache_dir.join(sanitize_pane_id(&payload.pane_id)),
        &payload.encode_line(),
    )?;

    Ok(())
}

fn atomic_write(path: &Path, contents: &str) -> Result<(), std::io::Error> {
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, contents)?;
    fs::rename(tmp, path)
}

fn sanitize_pane_id(pane_id: &str) -> String {
    pane_id.replace('/', "_")
}

#[cfg(test)]
mod tests {
    use std::fs;

    use tempfile::TempDir;

    use crate::payload::Payload;

    use super::write_payload;

    #[test]
    fn writes_global_and_per_pane_cache_files() {
        let temp = TempDir::new().expect("create temp dir");
        let payload = Payload {
            at: 123,
            pane_id: "w1/p1".to_owned(),
            cwd: "/repo".into(),
            repository: None,
        };

        write_payload(temp.path(), &payload).expect("write payload");

        assert_eq!(
            fs::read_to_string(temp.path().join("herdr-git-info")).expect("read global cache"),
            payload.encode_line()
        );
        assert_eq!(
            fs::read_to_string(temp.path().join("herdr-git-info-by-pane/w1_p1"))
                .expect("read pane cache"),
            payload.encode_line()
        );
    }
}
