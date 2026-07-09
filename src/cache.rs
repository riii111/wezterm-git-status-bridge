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

    let cwd_cache_dir = cache_dir.join("herdr-git-info-by-cwd");
    fs::create_dir_all(&cwd_cache_dir)?;
    atomic_write(
        &cwd_cache_dir.join(cwd_cache_key(&payload.cwd)),
        &payload.encode_line(),
    )?;

    Ok(())
}

/// Writes the default cache set plus the Herdr-focused cache read by the WezTerm Lua module.
pub fn write_payload_with_focused(cache_dir: &Path, payload: &Payload) -> Result<(), CacheError> {
    write_payload(cache_dir, payload)?;
    atomic_write(
        &cache_dir.join("herdr-git-info-focused"),
        &payload.encode_line(),
    )?;
    Ok(())
}

fn atomic_write(path: &Path, contents: &str) -> Result<(), std::io::Error> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".tmp.{}", std::process::id()));
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, contents)?;
    fs::rename(tmp, path)
}

fn sanitize_pane_id(pane_id: &str) -> String {
    let sanitized = pane_id.replace('/', "_");
    if sanitized.is_empty() || sanitized.chars().all(|character| character == '.') {
        "_".to_owned()
    } else {
        sanitized
    }
}

// Stable across writers/readers; not a cryptographic hash.
pub fn cwd_cache_key(cwd: &Path) -> String {
    fnv1a32_hex(&cwd.to_string_lossy())
}

fn fnv1a32_hex(value: &str) -> String {
    let mut hash: u32 = 2_166_136_261;
    for byte in value.as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(16_777_619);
    }
    format!("{hash:08x}")
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use tempfile::TempDir;

    use crate::payload::Payload;

    use super::{cwd_cache_key, write_payload, write_payload_with_focused};

    #[test]
    fn writes_global_per_pane_and_per_cwd_cache_files() {
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
        assert_eq!(
            fs::read_to_string(
                temp.path()
                    .join("herdr-git-info-by-cwd")
                    .join(cwd_cache_key(Path::new("/repo")))
            )
            .expect("read cwd cache"),
            payload.encode_line()
        );
    }

    #[test]
    fn focused_payload_keeps_separate_focused_cache() {
        let temp = TempDir::new().expect("create temp dir");
        let payload = Payload {
            at: 123,
            pane_id: "w1:p1".to_owned(),
            cwd: "/repo".into(),
            repository: None,
        };

        write_payload_with_focused(temp.path(), &payload).expect("write payload");

        assert_eq!(
            fs::read_to_string(temp.path().join("herdr-git-info-focused"))
                .expect("read focused cache"),
            payload.encode_line()
        );
        assert_eq!(
            fs::read_to_string(temp.path().join("herdr-git-info-by-pane/w1:p1"))
                .expect("read pane cache"),
            payload.encode_line()
        );
    }

    #[test]
    fn uses_safe_file_name_for_empty_or_dot_only_pane_id() {
        let temp = TempDir::new().expect("create temp dir");
        let payload = Payload {
            at: 123,
            pane_id: "..".to_owned(),
            cwd: "/repo".into(),
            repository: None,
        };

        write_payload(temp.path(), &payload).expect("write payload");

        assert!(temp.path().join("herdr-git-info-by-pane/_").is_file());
    }

    #[test]
    fn cwd_cache_key_is_stable_for_path() {
        assert_eq!(cwd_cache_key(Path::new("/repo")), "81f9fa62");
        assert_eq!(
            cwd_cache_key(Path::new("/repo")),
            cwd_cache_key(Path::new("/repo"))
        );
        assert_ne!(
            cwd_cache_key(Path::new("/repo")),
            cwd_cache_key(Path::new("/other"))
        );
    }
}
