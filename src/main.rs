use std::io::{self, Write};
use std::process::ExitCode;

use clap::Parser as _;
use wezterm_git_status_bridge::Cli;

fn main() -> ExitCode {
    match wezterm_git_status_bridge::run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(io::stderr(), "{error}");
            ExitCode::FAILURE
        }
    }
}
