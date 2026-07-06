use std::process::ExitCode;

use clap::Parser as _;
use wezterm_git_status_bridge::Cli;

fn main() -> ExitCode {
    match wezterm_git_status_bridge::run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            print_error(&error);
            ExitCode::FAILURE
        }
    }
}

#[expect(
    clippy::print_stderr,
    reason = "CLI errors should be visible to the user"
)]
fn print_error(error: &dyn std::fmt::Display) {
    eprintln!("{error}");
}
