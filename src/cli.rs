use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Args, Parser, Subcommand};
use thiserror::Error;

use crate::cache::{self, CacheError};
use crate::event::{self, EventError, PaneContext};
use crate::git_status::{self, GitStatusError};
use crate::herdr::{self, HerdrError};
use crate::payload::Payload;

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
    Update(UpdateArgs),
}

#[derive(Args, Clone, Debug, Default)]
pub struct UpdateArgs {
    #[arg(long, value_name = "DIR")]
    pub cache_dir: Option<PathBuf>,

    #[arg(long, value_name = "JSON")]
    pub event_json: Option<String>,

    #[arg(long, default_value = "herdr", value_name = "BIN")]
    pub herdr_bin: String,

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
    Herdr(#[from] HerdrError),
    #[error(transparent)]
    GitStatus(#[from] GitStatusError),
    #[error(transparent)]
    Cache(#[from] CacheError),
    #[error("system time is before UNIX epoch")]
    InvalidSystemTime,
}

pub fn run(cli: Cli) -> Result<(), CliError> {
    let args = match cli.command {
        Some(Command::Update(args)) => args,
        None => cli.update,
    };
    update(args)
}

fn update(args: UpdateArgs) -> Result<(), CliError> {
    let Some(context) = resolve_context(&args)? else {
        return Ok(());
    };
    let repository = git_status::collect(&context.cwd)?;
    let payload = Payload {
        at: unix_now()?,
        pane_id: context.pane_id,
        cwd: context.cwd,
        repository,
    };

    cache::write_payload(
        &args.cache_dir.unwrap_or_else(cache::default_cache_dir),
        &payload,
    )?;
    Ok(())
}

fn resolve_context(args: &UpdateArgs) -> Result<Option<PaneContext>, CliError> {
    match (&args.pane_id, &args.cwd) {
        (Some(pane_id), Some(cwd)) => {
            return Ok(Some(PaneContext {
                pane_id: pane_id.clone(),
                cwd: cwd.clone(),
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
        return Ok(Some(context));
    }

    if let Some(context) = std::env::var("HERDR_PLUGIN_EVENT_JSON")
        .ok()
        .as_deref()
        .map(event::parse_event_json)
        .transpose()?
        .flatten()
    {
        return Ok(Some(context));
    }

    Ok(herdr::focused_pane_from_cli(&args.herdr_bin)?)
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

    use tempfile::TempDir;

    use super::{CliError, UpdateArgs, resolve_context, update};

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
}
