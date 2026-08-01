use std::env;
use std::fs::File;
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::Deserialize;

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ChildLifecycle {
    Starting,
    Ready,
    Waiting,
    Blocked,
    Degraded,
    Stopped,
    Failed,
    Done,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ChildProcess {
    pid: u32,
    creation_identity: String,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ChildBackend {
    kind: String,
    workspace_id: String,
    pane_id: String,
}

#[derive(Debug, Deserialize)]
struct ChildTranscript {
    adapter: String,
    id: String,
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
struct ChildConversation {
    harness: String,
    session_id: String,
    transcript: ChildTranscript,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ChildStatus {
    verb: String,
    #[serde(default)]
    note: Option<String>,
    #[serde(default)]
    at: Option<DateTime<Utc>>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ChildAttestation {
    method: String,
    #[serde(default)]
    observed_at: Option<DateTime<Utc>>,
}

#[allow(dead_code)]
#[derive(Debug, Deserialize)]
struct ChildCurrent {
    schema: String,
    container_id: String,
    parent_container_id: String,
    epoch: u64,
    published_at: DateTime<Utc>,
    lifecycle: ChildLifecycle,
    child_type: String,
    #[serde(default)]
    task_id: Option<String>,
    #[serde(default)]
    process: Option<ChildProcess>,
    #[serde(default)]
    backend: Option<ChildBackend>,
    #[serde(default)]
    conversation: Option<ChildConversation>,
    #[serde(default)]
    harness: Option<String>,
    #[serde(default)]
    worktree: Option<PathBuf>,
    #[serde(default)]
    status: Option<ChildStatus>,
    #[serde(default)]
    attestation: Option<ChildAttestation>,
}

fn required_arg(args: &mut impl Iterator<Item = String>, name: &str) -> String {
    args.next().unwrap_or_else(|| panic!("missing {name}"))
}

fn main() {
    let mut args = env::args().skip(1);
    let path = required_arg(&mut args, "json path");
    let mode = required_arg(&mut args, "mode");
    let current: ChildCurrent =
        serde_json::from_reader(File::open(path).expect("open child-current"))
            .expect("deserialize ChildCurrent");

    match mode.as_str() {
        "absent" => assert!(current.conversation.is_none()),
        "present" => {
            let expected_harness = required_arg(&mut args, "harness");
            let expected_session = required_arg(&mut args, "session_id");
            let expected_adapter = required_arg(&mut args, "adapter");
            let expected_id = required_arg(&mut args, "transcript id");
            let expected_path = PathBuf::from(required_arg(&mut args, "transcript path"));
            let conversation = current.conversation.expect("conversation present");
            assert_eq!(conversation.harness, expected_harness);
            assert_eq!(conversation.session_id, expected_session);
            assert_eq!(conversation.transcript.adapter, expected_adapter);
            assert_eq!(conversation.transcript.id, expected_id);
            assert_eq!(conversation.transcript.path, expected_path);
        }
        _ => panic!("unknown mode: {mode}"),
    }
}
