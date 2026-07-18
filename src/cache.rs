use std::fs::{self, File, OpenOptions};
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
    with_focused_cache_lock(cache_dir, || write_focused_payload(cache_dir, payload))
}

pub fn refresh_focused_payload_if_matching(
    cache_dir: &Path,
    payload: &Payload,
) -> Result<(), CacheError> {
    with_focused_cache_lock(cache_dir, || {
        if focused_pane_id(cache_dir)?.as_deref() == Some(payload.pane_id.as_str()) {
            write_focused_payload(cache_dir, payload)?;
        }
        Ok(())
    })
}

fn write_focused_payload(cache_dir: &Path, payload: &Payload) -> Result<(), CacheError> {
    atomic_write(
        &cache_dir.join("herdr-git-info-focused"),
        &payload.encode_line(),
    )
    .map_err(Into::into)
}

fn focused_pane_id(cache_dir: &Path) -> Result<Option<String>, CacheError> {
    let focused_path = cache_dir.join("herdr-git-info-focused");
    let contents = match fs::read_to_string(focused_path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };

    Ok(parse_focused_pane_id(&contents))
}

// The focused cache uses the payload wire format parsed by the WezTerm Lua module.
fn parse_focused_pane_id(contents: &str) -> Option<String> {
    let fields = contents.lines().next()?.split('\t').collect::<Vec<_>>();
    if fields.len() < 8 || fields[0] != "herdrgit1" || fields[1].parse::<u64>().is_err() {
        return None;
    }

    match fields[4] {
        "0" => {}
        "1" if !fields[5].is_empty() && !fields[6].is_empty() => {}
        _ => return None,
    }

    Some(fields[2].to_owned())
}

fn with_focused_cache_lock<T>(
    cache_dir: &Path,
    operation: impl FnOnce() -> Result<T, CacheError>,
) -> Result<T, CacheError> {
    let _lock = FocusedCacheLock::acquire(cache_dir)?;
    operation()
}

struct FocusedCacheLock(File);

impl FocusedCacheLock {
    fn acquire(cache_dir: &Path) -> Result<Self, CacheError> {
        fs::create_dir_all(cache_dir)?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(cache_dir.join("herdr-git-info-focused.lock"))?;
        lock.lock()?;
        Ok(Self(lock))
    }
}

impl Drop for FocusedCacheLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
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
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use tempfile::TempDir;

    use crate::payload::Payload;

    use super::{
        cwd_cache_key, focused_pane_id, with_focused_cache_lock, write_focused_payload,
        write_payload, write_payload_with_focused,
    };

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
    fn reads_focused_pane_id_from_valid_payload() {
        let temp = TempDir::new().expect("create temp dir");
        fs::write(
            temp.path().join("herdr-git-info-focused"),
            "herdrgit1\t123\tw1:p1\t/repo\t0\t\t\t\n",
        )
        .expect("write focused cache");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read focused pane id"),
            Some("w1:p1".to_owned())
        );
    }

    #[test]
    fn ignores_missing_or_invalid_focused_payload() {
        let temp = TempDir::new().expect("create temp dir");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read missing focused cache"),
            None
        );

        fs::write(
            temp.path().join("herdr-git-info-focused"),
            "invalid\t123\tw1:p1\t/repo\t0\t\t\t\n",
        )
        .expect("write invalid focused cache");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read invalid focused cache"),
            None
        );

        fs::write(
            temp.path().join("herdr-git-info-focused"),
            "herdrgit1\tnot-a-timestamp\tw1:p1\t/repo\t0\t\t\t\n",
        )
        .expect("write invalid timestamp cache");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read invalid timestamp cache"),
            None
        );

        fs::write(
            temp.path().join("herdr-git-info-focused"),
            "herdrgit1\t123\tw1:p1\t/repo\t1\t\tmain\t\n",
        )
        .expect("write incomplete present cache");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read incomplete present cache"),
            None
        );

        fs::write(
            temp.path().join("herdr-git-info-focused"),
            "herdrgit1\t123\tw1:p1\n",
        )
        .expect("write incomplete cache");

        assert_eq!(
            focused_pane_id(temp.path()).expect("read incomplete cache"),
            None
        );
    }

    #[test]
    fn focused_cache_lock_serializes_refresh_and_focus_updates() {
        let temp = TempDir::new().expect("create cache dir");
        let first = Payload {
            at: 123,
            pane_id: "w1:p1".to_owned(),
            cwd: "/first".into(),
            repository: None,
        };
        let second = Payload {
            at: 124,
            pane_id: "w1:p2".to_owned(),
            cwd: "/second".into(),
            repository: None,
        };
        write_payload_with_focused(temp.path(), &first).expect("write initial focused cache");

        let (first_locked_tx, first_locked_rx) = mpsc::channel();
        let (release_first_tx, release_first_rx) = mpsc::channel();
        let first_cache_dir = temp.path().to_path_buf();
        let first_payload = first;
        let first_update = thread::spawn(move || {
            with_focused_cache_lock(&first_cache_dir, || {
                assert_eq!(focused_pane_id(&first_cache_dir)?.as_deref(), Some("w1:p1"));
                first_locked_tx.send(()).expect("signal first lock");
                release_first_rx.recv().expect("release first lock");
                write_focused_payload(&first_cache_dir, &first_payload)
            })
        });
        first_locked_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("wait for first lock");

        let (second_started_tx, second_started_rx) = mpsc::channel();
        let (second_done_tx, second_done_rx) = mpsc::channel();
        let second_cache_dir = temp.path().to_path_buf();
        let second_update = thread::spawn(move || {
            second_started_tx.send(()).expect("signal second start");
            write_payload_with_focused(&second_cache_dir, &second)
                .expect("write second focused cache");
            second_done_tx.send(()).expect("signal second completion");
        });
        second_started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("wait for second update");
        assert!(
            second_done_rx
                .recv_timeout(Duration::from_millis(50))
                .is_err()
        );

        release_first_tx.send(()).expect("release first update");
        first_update
            .join()
            .expect("join first update")
            .expect("complete first update");
        second_done_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("wait for second completion");
        second_update.join().expect("join second update");

        assert_eq!(
            fs::read_to_string(temp.path().join("herdr-git-info-focused"))
                .expect("read focused cache"),
            "herdrgit1\t124\tw1:p2\t/second\t0\t\t\t\n"
        );
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
