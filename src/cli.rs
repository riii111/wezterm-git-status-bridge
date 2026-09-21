use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Args, Parser, Subcommand};
use thiserror::Error;

use crate::cache::{self, CacheError};
use crate::event::{self, EventError, PaneContext};
use crate::git_status::{self, GitStatusError};
use crate::payload::Payload;
use crate::setup::{self, SetupError};

#[derive(Debug)]
struct ResolvedContext {
    context: PaneContext,
    cache_write: CacheWrite,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CacheWrite {
    Default,
    HerdrFocused,
}

#[derive(Debug, Parser)]
#[command(version, about)]
pub struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[command(flatten)]
    update: UpdateArgs,
}

#[derive(Debug, Subcommand)]
enum Command {
    Setup(SetupArgs),
    Update(UpdateArgs),
}

#[derive(Args, Clone, Debug, Default)]
pub struct TerminalArgs {
    #[arg(long)]
    pub wezterm: bool,

    #[arg(long)]
    pub kitty: bool,
}

#[derive(Args, Clone, Debug, Default)]
pub struct SetupArgs {
    #[command(flatten)]
    pub terminal: TerminalArgs,

    #[arg(long, value_name = "DIR")]
    pub wezterm_config_dir: Option<PathBuf>,

    #[arg(long, value_name = "FILE")]
    pub wezterm_config_file: Option<PathBuf>,

    #[arg(long, value_name = "DIR")]
    pub kitty_config_dir: Option<PathBuf>,

    #[arg(long, value_name = "FILE")]
    pub kitty_config_file: Option<PathBuf>,

    #[arg(long)]
    pub herdr: bool,

    #[arg(long, value_name = "PATH")]
    pub herdr_bin: Option<PathBuf>,

    #[arg(long)]
    pub shell_hook: bool,

    #[arg(long)]
    pub no_shell_hook: bool,

    #[arg(long, value_name = "FILE")]
    pub zshrc: Option<PathBuf>,
}

#[derive(Args, Clone, Debug, Default)]
pub struct UpdateArgs {
    #[arg(long, value_name = "DIR")]
    pub cache_dir: Option<PathBuf>,

    #[arg(long, value_name = "JSON")]
    pub event_json: Option<String>,

    #[arg(long, value_name = "ID")]
    pub pane_id: Option<String>,

    #[arg(long, value_name = "DIR")]
    pub cwd: Option<PathBuf>,
}

#[derive(Debug, Error)]
pub enum CliError {
    #[error("both --pane-id and --cwd are required when either is provided")]
    PartialExplicitContext,
    #[error(transparent)]
    Event(#[from] EventError),
    #[error(transparent)]
    GitStatus(#[from] GitStatusError),
    #[error(transparent)]
    Cache(#[from] CacheError),
    #[error(transparent)]
    Setup(#[from] SetupError),
    #[error("system time is before UNIX epoch")]
    InvalidSystemTime,
}

pub fn run(cli: Cli) -> Result<(), CliError> {
    match cli.command {
        Some(Command::Setup(args)) => setup::run(&args).map_err(Into::into),
        Some(Command::Update(args)) => update(args),
        None => update(cli.update),
    }
}

fn update(args: UpdateArgs) -> Result<(), CliError> {
    let Some(resolved) = resolve_update_context(&args)? else {
        return Ok(());
    };
    let repository = git_status::collect(&resolved.context.cwd)?;
    let payload = Payload {
        at: unix_now()?,
        pane_id: resolved.context.pane_id,
        cwd: resolved.context.cwd,
        repository,
    };

    let cache_dir = args.cache_dir.unwrap_or_else(cache::default_cache_dir);
    match resolved.cache_write {
        CacheWrite::Default => {
            cache::write_payload(&cache_dir, &payload)?;
            cache::refresh_focused_payload_if_matching(&cache_dir, &payload)?;
        }
        CacheWrite::HerdrFocused => cache::write_payload_with_focused(&cache_dir, &payload)?,
    }
    Ok(())
}

fn resolve_update_context(args: &UpdateArgs) -> Result<Option<ResolvedContext>, CliError> {
    match (&args.pane_id, &args.cwd) {
        (Some(pane_id), Some(cwd)) => {
            return Ok(Some(ResolvedContext {
                context: PaneContext {
                    pane_id: pane_id.clone(),
                    cwd: cwd.clone(),
                },
                cache_write: CacheWrite::Default,
            }));
        }
        (None, None) => {}
        _ => return Err(CliError::PartialExplicitContext),
    }

    if let Some(context) = args
        .event_json
        .as_deref()
        .map(event::parse_event_json)
        .transpose()?
        .flatten()
    {
        return Ok(Some(ResolvedContext {
            context,
            cache_write: CacheWrite::HerdrFocused,
        }));
    }

    if let Some(context) = std::env::var("HERDR_PLUGIN_EVENT_JSON")
        .ok()
        .as_deref()
        .map(event::parse_event_json)
        .transpose()?
        .flatten()
    {
        return Ok(Some(ResolvedContext {
            context,
            cache_write: CacheWrite::HerdrFocused,
        }));
    }

    Ok(None)
}

fn unix_now() -> Result<u64, CliError> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CliError::InvalidSystemTime)?
        .as_secs())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use tempfile::TempDir;

    use super::{CliError, UpdateArgs, resolve_update_context, update};

    fn resolve_context(args: &UpdateArgs) -> Result<Option<super::PaneContext>, CliError> {
        Ok(resolve_update_context(args)?.map(|resolved| resolved.context))
    }

    #[test]
    fn update_writes_cache_from_explicit_context() {
        let cache = TempDir::new().expect("create cache dir");
        let cwd = TempDir::new().expect("create cwd");

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            pane_id: Some("w1:p1".to_owned()),
            cwd: Some(cwd.path().to_path_buf()),
            ..UpdateArgs::default()
        })
        .expect("update cache");

        let global = fs::read_to_string(cache.path().join("herdr-git-info")).expect("read cache");
        assert!(global.contains("\tw1:p1\t"));
        assert!(global.contains("\t0\t\t\t\n"));
        assert!(!cache.path().join("herdr-git-info-focused").exists());
    }

    #[test]
    fn update_writes_present_repository_status() {
        let cache = TempDir::new().expect("create cache dir");
        let repo = git_repo();

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            pane_id: Some("w1:p1".to_owned()),
            cwd: Some(repo.path().to_path_buf()),
            ..UpdateArgs::default()
        })
        .expect("update cache");

        let global = fs::read_to_string(cache.path().join("herdr-git-info")).expect("read cache");
        assert!(global.contains("\tw1:p1\t"));
        assert!(global.contains("\t1\t"));
        assert!(global.contains("\tmain\t"));
    }

    #[test]
    fn event_json_update_writes_focused_cache() {
        let cache = TempDir::new().expect("create cache dir");
        let repo = git_repo();

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            event_json: Some(format!(
                r#"{{"pane":{{"pane_id":"w1:p1","cwd":"{}"}}}}"#,
                repo.path().display()
            )),
            ..UpdateArgs::default()
        })
        .expect("update cache");

        let focused = fs::read_to_string(cache.path().join("herdr-git-info-focused"))
            .expect("read focused cache");
        assert!(focused.contains("\tw1:p1\t"));
        assert!(focused.contains("\t1\t"));
        assert!(focused.contains("\tmain\t"));
    }

    #[test]
    fn explicit_update_refreshes_focused_for_matching_pane() {
        let cache = TempDir::new().expect("create cache dir");
        let focused_repo = git_repo();
        let updated_repo = git_repo();

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            event_json: Some(format!(
                r#"{{"pane":{{"pane_id":"w1:p1","cwd":"{}"}}}}"#,
                focused_repo.path().display()
            )),
            ..UpdateArgs::default()
        })
        .expect("write focused cache");

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            pane_id: Some("w1:p1".to_owned()),
            cwd: Some(updated_repo.path().to_path_buf()),
            ..UpdateArgs::default()
        })
        .expect("refresh focused cache");

        let focused = fs::read_to_string(cache.path().join("herdr-git-info-focused"))
            .expect("read focused cache");
        assert!(focused.contains(&format!("\t{}\t", updated_repo.path().display())));
    }

    #[test]
    fn explicit_update_keeps_focused_for_other_pane() {
        let cache = TempDir::new().expect("create cache dir");
        let focused_repo = git_repo();
        let updated_repo = git_repo();

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            event_json: Some(format!(
                r#"{{"pane":{{"pane_id":"w1:p1","cwd":"{}"}}}}"#,
                focused_repo.path().display()
            )),
            ..UpdateArgs::default()
        })
        .expect("write focused cache");
        let before = fs::read_to_string(cache.path().join("herdr-git-info-focused"))
            .expect("read focused cache");

        update(UpdateArgs {
            cache_dir: Some(cache.path().to_path_buf()),
            pane_id: Some("w1:p2".to_owned()),
            cwd: Some(updated_repo.path().to_path_buf()),
            ..UpdateArgs::default()
        })
        .expect("update other pane");

        assert_eq!(
            fs::read_to_string(cache.path().join("herdr-git-info-focused"))
                .expect("read focused cache"),
            before
        );
    }

    #[test]
    fn event_json_context_is_used() {
        let context = resolve_context(&UpdateArgs {
            event_json: Some(r#"{"pane":{"pane_id":"w1:p1","cwd":"/from-event"}}"#.to_owned()),
            ..UpdateArgs::default()
        })
        .expect("resolve context")
        .expect("context");

        assert_eq!(context.pane_id, "w1:p1");
        assert_eq!(context.cwd, Path::new("/from-event"));
    }

    #[test]
    fn returns_none_without_context_input() {
        let context = resolve_context(&UpdateArgs::default()).expect("resolve context");

        assert_eq!(context, None);
    }

    #[test]
    fn rejects_pane_id_without_cwd() {
        let error = resolve_context(&UpdateArgs {
            pane_id: Some("w1:p1".to_owned()),
            ..UpdateArgs::default()
        })
        .expect_err("partial context should fail");

        assert!(matches!(error, CliError::PartialExplicitContext));
    }

    #[test]
    fn rejects_cwd_without_pane_id() {
        let cwd = TempDir::new().expect("create cwd");

        let error = resolve_context(&UpdateArgs {
            cwd: Some(cwd.path().to_path_buf()),
            ..UpdateArgs::default()
        })
        .expect_err("partial context should fail");

        assert!(matches!(error, CliError::PartialExplicitContext));
    }

    fn git_repo() -> TempDir {
        let temp = TempDir::new().expect("create temp dir");
        git(temp.path(), ["init", "--initial-branch", "main"]);
        git(temp.path(), ["config", "user.name", "Test User"]);
        git(temp.path(), ["config", "user.email", "test@example.com"]);
        fs::write(temp.path().join("README.md"), "test").expect("write readme");
        git(temp.path(), ["add", "README.md"]);
        git(temp.path(), ["commit", "-m", "initial"]);
        temp
    }

    fn git<const N: usize>(cwd: &Path, args: [&str; N]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .status()
            .expect("run git");
        assert!(status.success());
    }
}
