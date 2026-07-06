use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

use thiserror::Error;

use crate::payload::{RepositoryStatus, StatusFlags};

#[derive(Debug, Error)]
pub enum GitStatusError {
    #[error("failed to run git: {0}")]
    Io(#[from] std::io::Error),
}

pub fn collect(cwd: &Path) -> Result<Option<RepositoryStatus>, GitStatusError> {
    let Some(root) = git_output(cwd, ["rev-parse", "--show-toplevel"])? else {
        return Ok(None);
    };
    let Some(git_dir) = git_output(cwd, ["rev-parse", "--path-format=absolute", "--git-dir"])?
    else {
        return Ok(None);
    };
    let Some(common_dir) = git_output(
        cwd,
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?
    else {
        return Ok(None);
    };

    let (ref_name, detached) = match git_output(cwd, ["symbolic-ref", "--short", "HEAD"])? {
        Some(ref_name) => (ref_name, false),
        None => match git_output(cwd, ["rev-parse", "--short", "HEAD"])? {
            Some(ref_name) => (ref_name, true),
            None => return Ok(None),
        },
    };

    let git_dir = PathBuf::from(git_dir);
    let common_dir = PathBuf::from(common_dir);
    let mut flags = StatusFlags::default();
    flags.set_detached(detached);
    flags.set_dirty(is_dirty(cwd)?);
    flags.set_worktree(canonicalize_lossy(&git_dir) != canonicalize_lossy(&common_dir));
    flags
        .set_rebase(git_dir.join("rebase-merge").is_dir() || git_dir.join("rebase-apply").is_dir());
    flags.set_cherry_pick(git_dir.join("CHERRY_PICK_HEAD").is_file());

    Ok(Some(RepositoryStatus {
        repo: repo_name(&root),
        ref_name,
        flags,
    }))
}

fn git_output<const N: usize>(
    cwd: &Path,
    args: [&'static str; N],
) -> Result<Option<String>, GitStatusError> {
    let output = Command::new("git").args(args).current_dir(cwd).output()?;
    if !output.status.success() {
        return Ok(None);
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok((!value.is_empty()).then_some(value))
}

fn git_status_success(cwd: &Path, args: &[&str]) -> Result<bool, GitStatusError> {
    let status = Command::new("git").args(args).current_dir(cwd).status()?;
    Ok(status.success())
}

fn git_output_dynamic(cwd: &Path, args: &[&str]) -> Result<Option<String>, GitStatusError> {
    let output = Command::new("git").args(args).current_dir(cwd).output()?;
    if !output.status.success() {
        return Ok(None);
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    Ok((!value.is_empty()).then_some(value))
}

fn is_dirty(cwd: &Path) -> Result<bool, GitStatusError> {
    if !git_status_success(cwd, &["diff", "--quiet"])? {
        return Ok(true);
    }
    if !git_status_success(cwd, &["diff", "--quiet", "--cached"])? {
        return Ok(true);
    }

    let Some(untracked) = git_output_dynamic(
        cwd,
        &[
            "ls-files",
            "--others",
            "--exclude-standard",
            "--directory",
            "--no-empty-directory",
        ],
    )?
    else {
        return Ok(false);
    };

    Ok(!untracked.is_empty())
}

fn canonicalize_lossy(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

fn repo_name(root: &str) -> String {
    Path::new(root)
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or(root)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    use tempfile::TempDir;

    use super::collect;

    #[test]
    fn returns_absent_status_outside_git_repository() {
        let temp = TempDir::new().expect("create temp dir");

        let status = collect(temp.path()).expect("collect status");

        assert_eq!(status, None);
    }

    #[test]
    fn reports_branch_and_repository_name_for_clean_repository() {
        let repo = test_repo();

        let status = collect(repo.path())
            .expect("collect status")
            .expect("status");

        assert_eq!(status.repo, repo.name);
        assert_eq!(status.ref_name, "main");
        assert!(!status.flags.dirty());
        assert!(!status.flags.detached());
    }

    #[test]
    fn works_from_repository_subdirectory() {
        let repo = test_repo();
        let nested = repo.path().join("nested");
        fs::create_dir(&nested).expect("create nested dir");

        let status = collect(&nested).expect("collect status").expect("status");

        assert_eq!(status.repo, repo.name);
        assert_eq!(status.ref_name, "main");
    }

    #[test]
    fn marks_untracked_files_as_dirty() {
        let repo = test_repo();
        fs::write(repo.path().join("scratch.txt"), "scratch").expect("write untracked file");

        let status = collect(repo.path())
            .expect("collect status")
            .expect("status");

        assert!(status.flags.dirty());
    }

    #[test]
    fn marks_detached_head() {
        let repo = test_repo();
        git(repo.path(), ["checkout", "--detach", "HEAD"]);

        let status = collect(repo.path())
            .expect("collect status")
            .expect("status");

        assert!(status.flags.detached());
    }

    #[test]
    fn marks_git_worktree_checkout() {
        let repo = test_repo();
        let worktree = repo.temp.path().join("linked");
        git(
            repo.path(),
            [
                "worktree",
                "add",
                "-b",
                "linked-branch",
                worktree.to_str().unwrap(),
                "HEAD",
            ],
        );

        let status = collect(&worktree).expect("collect status").expect("status");

        assert!(status.flags.worktree());
    }

    #[test]
    fn marks_rebase_and_cherry_pick_state_files() {
        let repo = test_repo();
        fs::create_dir(repo.path().join(".git/rebase-merge")).expect("create rebase marker");
        fs::write(repo.path().join(".git/CHERRY_PICK_HEAD"), "head").expect("create marker");

        let status = collect(repo.path())
            .expect("collect status")
            .expect("status");

        assert!(status.flags.rebase());
        assert!(status.flags.cherry_pick());
    }

    struct TestRepo {
        temp: TempDir,
        name: String,
    }

    impl TestRepo {
        fn path(&self) -> &Path {
            self.temp.path()
        }
    }

    fn test_repo() -> TestRepo {
        let temp = TempDir::new().expect("create temp dir");
        git(temp.path(), ["init", "--initial-branch", "main"]);
        git(temp.path(), ["config", "user.name", "Test User"]);
        git(temp.path(), ["config", "user.email", "test@example.com"]);
        fs::write(temp.path().join("README.md"), "test").expect("write readme");
        git(temp.path(), ["add", "README.md"]);
        git(temp.path(), ["commit", "-m", "initial"]);

        let name = temp
            .path()
            .file_name()
            .and_then(|name| name.to_str())
            .expect("temp dir name")
            .to_owned();
        TestRepo { temp, name }
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
