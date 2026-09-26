//! ExMaude NIF — Rust-side management of a Maude subprocess.
//!
//! Each `MaudeProcess` owns a child process plus a dedicated reader thread
//! that streams raw output chunks onto a `crossbeam_channel`. NIF entry points
//! drain the channel with `recv_timeout`, which gives us per-command deadlines
//! that `std::io` does not offer for child stdout pipes.
//!
//! Byte-level (not line-level) reads are necessary because Maude emits its
//! `Maude>` prompt **without a trailing newline**, so `read_line` would block
//! forever while waiting for the next byte from the user.
//!
//! All blocking entry points (`start`, `execute_with_timeout`,
//! `execute_with_limit`, `stop`) run on the `DirtyIo` scheduler — the work is
//! I/O wait on the Maude pipe, not CPU.
//!
//! ## Safety
//!
//! NIFs share the BEAM's OS process. A segfault in this crate crashes the
//! entire VM. Rustler wraps every `#[rustler::nif]` body in
//! `std::panic::catch_unwind`, so Rust `panic!`s become Elixir exceptions,
//! but we still avoid `unwrap` and convert poisoned mutexes to returned
//! errors as a matter of hygiene.

use crossbeam_channel::{bounded, Receiver, RecvTimeoutError, Sender};
use rustler::{Error, NifResult, ResourceArc};
use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

mod atoms {
    rustler::atoms! {
        timeout,
        response_too_large,
        eof,
        io_error,
        lock_poisoned,
    }
}

const PROMPT: &[u8] = b"Maude> ";
const DEFAULT_MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const READER_BUF_SIZE: usize = 4096;
const READER_CHANNEL_CAPACITY: usize = 64;
const READER_JOIN_TIMEOUT: Duration = Duration::from_millis(200);
const STARTUP_TIMEOUT_MS: u64 = 10_000;
static LAST_SPAWNED_PID: AtomicU32 = AtomicU32::new(0);

enum ReaderMsg {
    Data(Vec<u8>),
    Io(String),
    Eof,
}

/// Wrapper around the Maude subprocess and its output reader thread.
///
/// Maude's stdout and stderr share one OS pipe. Combining the descriptors in
/// the child preserves write order: if separate reader threads were merged in
/// user space, a prompt from stdout could overtake an error from stderr and
/// leak that error into the following command's response.
pub struct MaudeProcess {
    child: Mutex<Option<Child>>,
    writer: Mutex<Option<Sender<WriteRequest>>>,
    rx: Receiver<ReaderMsg>,
    readers: Mutex<Vec<JoinHandle<()>>>,
    pending: Mutex<Vec<u8>>,
}

#[rustler::resource_impl]
impl rustler::Resource for MaudeProcess {}

struct WriteRequest {
    command: String,
    reply: Sender<Result<(), String>>,
}

impl Drop for MaudeProcess {
    fn drop(&mut self) {
        // Resource destructors may run on ordinary BEAM schedulers. Kill is
        // nonblocking; process reaping and thread joins belong off-scheduler.
        self.writer
            .get_mut()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        let child = self
            .child
            .get_mut()
            .unwrap_or_else(|e| e.into_inner())
            .take();
        let readers = std::mem::take(self.readers.get_mut().unwrap_or_else(|e| e.into_inner()));
        if let Some(mut child) = child {
            let _ = child.kill();
            let _ = thread::Builder::new()
                .name("maude-reaper".into())
                .spawn(move || {
                    terminate_child(&mut child);
                    for reader in readers {
                        join_with_timeout(reader, READER_JOIN_TIMEOUT);
                    }
                });
        }
    }
}

/// Probe used by `ExMaude.Backend.available?(:nif)` to detect whether
/// Rustler has populated the native function table.
#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

#[rustler::nif]
fn last_spawned_pid() -> u32 {
    LAST_SPAWNED_PID.load(Ordering::Relaxed)
}

/// Start a new Maude subprocess.
#[rustler::nif(schedule = "DirtyIo")]
fn start(maude_path: String) -> NifResult<ResourceArc<MaudeProcess>> {
    start_process(maude_path, STARTUP_TIMEOUT_MS)
}

#[rustler::nif(schedule = "DirtyIo")]
fn start_with_timeout(
    maude_path: String,
    startup_timeout_ms: u64,
) -> NifResult<ResourceArc<MaudeProcess>> {
    start_process(maude_path, startup_timeout_ms)
}

fn start_process(
    maude_path: String,
    startup_timeout_ms: u64,
) -> NifResult<ResourceArc<MaudeProcess>> {
    let (output_reader, output_writer) =
        os_pipe::pipe().map_err(|e| io_error(format!("output pipe failed: {e}")))?;
    let error_writer = output_writer
        .try_clone()
        .map_err(|e| io_error(format!("output pipe clone failed: {e}")))?;

    let mut child = Command::new(&maude_path)
        .args(["-no-banner", "-no-wrap", "-no-advise", "-interactive"])
        .stdin(Stdio::piped())
        .stdout(Stdio::from(output_writer))
        .stderr(Stdio::from(error_writer))
        .spawn()
        .map_err(|e| io_error(format!("spawn failed: {e}")))?;

    LAST_SPAWNED_PID.store(child.id(), Ordering::Relaxed);

    let Some(stdin) = child.stdin.take() else {
        terminate_child(&mut child);
        return Err(io_error("failed to capture stdin"));
    };

    // Bound unread native output so a busy interpreter cannot outrun the NIF
    // caller and allocate an unbounded queue between scheduler turns.
    let (tx, rx) = bounded::<ReaderMsg>(READER_CHANNEL_CAPACITY);
    let output_handle = spawn_reader(Box::new(output_reader), tx, "output");

    let (writer_tx, writer_rx) = bounded::<WriteRequest>(1);
    let writer_handle = spawn_writer(stdin, writer_rx);
    let process = MaudeProcess {
        child: Mutex::new(Some(child)),
        writer: Mutex::new(Some(writer_tx)),
        rx,
        readers: Mutex::new(vec![output_handle, writer_handle]),
        pending: Mutex::new(Vec::new()),
    };

    if let Err(error) = read_until_prompt(&process, startup_timeout_ms, DEFAULT_MAX_RESPONSE_BYTES)
    {
        shutdown_process(&process);
        return Err(error);
    }

    Ok(ResourceArc::new(process))
}

/// Execute a Maude command, returning everything before the next prompt.
///
/// `timeout_ms` is the per-command deadline. On timeout, the subprocess is
/// left running but in an indeterminate state — the Elixir wrapper stops
/// the worker so the pool replaces it with a fresh process.
#[rustler::nif(schedule = "DirtyIo")]
fn execute_with_timeout(
    process: ResourceArc<MaudeProcess>,
    command: String,
    timeout_ms: u64,
) -> NifResult<String> {
    execute_command(&process, command, timeout_ms, DEFAULT_MAX_RESPONSE_BYTES)
}

/// Execute with an explicit response-size ceiling supplied by the Elixir
/// worker. The old three-argument NIF remains for compatibility with direct
/// tests and defaults to the documented 16 MiB limit.
#[rustler::nif(schedule = "DirtyIo")]
fn execute_with_limit(
    process: ResourceArc<MaudeProcess>,
    command: String,
    timeout_ms: u64,
    max_response_bytes: u64,
) -> NifResult<String> {
    let limit = usize::try_from(max_response_bytes)
        .map_err(|_| response_too_large_error(DEFAULT_MAX_RESPONSE_BYTES))?;
    execute_command(&process, command, timeout_ms, limit)
}

/// Stop the subprocess.
#[rustler::nif(schedule = "DirtyIo")]
fn stop(process: ResourceArc<MaudeProcess>) -> NifResult<()> {
    shutdown_process(&process);
    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
fn child_pid(process: ResourceArc<MaudeProcess>) -> NifResult<u32> {
    let child = process.child.lock().map_err(|_| poison_error("child"))?;
    child.as_ref().map(Child::id).ok_or_else(eof_error)
}

fn wait_with_timeout(child: &mut Child, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => return,
        }
    }
}

/// Check whether the subprocess is still running.
#[rustler::nif(schedule = "DirtyIo")]
fn alive(process: ResourceArc<MaudeProcess>) -> bool {
    let Ok(mut child) = process.child.lock() else {
        return false;
    };

    child
        .as_mut()
        .is_some_and(|child| matches!(child.try_wait(), Ok(None)))
}

fn spawn_reader(
    mut reader: Box<dyn Read + Send>,
    tx: Sender<ReaderMsg>,
    source: &'static str,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut buf = [0u8; READER_BUF_SIZE];

        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = tx.send(ReaderMsg::Eof);
                    return;
                }
                Ok(n) => {
                    if tx.send(ReaderMsg::Data(buf[..n].to_vec())).is_err() {
                        return;
                    }
                }
                Err(e) => {
                    let _ = tx.send(ReaderMsg::Io(format!("{source} read failed: {e}")));
                    return;
                }
            }
        }
    })
}

fn spawn_writer(mut stdin: ChildStdin, requests: Receiver<WriteRequest>) -> JoinHandle<()> {
    thread::spawn(move || {
        while let Ok(request) = requests.recv() {
            let result = writeln!(stdin, "{}", request.command)
                .and_then(|_| stdin.flush())
                .map_err(|e| e.to_string());
            let failed = result.is_err();
            let _ = request.reply.send(result);
            if failed {
                return;
            }
        }
    })
}

fn execute_command(
    process: &MaudeProcess,
    command: String,
    timeout_ms: u64,
    limit: usize,
) -> NifResult<String> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let writer = process
        .writer
        .lock()
        .map_err(|_| poison_error("writer"))?
        .as_ref()
        .cloned()
        .ok_or_else(eof_error)?;
    let (reply, result) = bounded(1);
    writer
        .send_timeout(
            WriteRequest { command, reply },
            deadline.saturating_duration_since(Instant::now()),
        )
        .map_err(|_| timeout_error(timeout_ms))?;
    match result.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(Ok(())) => read_until_deadline(process, timeout_ms, limit, deadline),
        Ok(Err(error)) => Err(io_error(error)),
        Err(_) => Err(timeout_error(timeout_ms)),
    }
}

/// Drain stdout chunks until a line-boundary prompt is found.
fn read_until_prompt(
    process: &MaudeProcess,
    timeout_ms: u64,
    max_response_bytes: usize,
) -> NifResult<String> {
    read_until_deadline(
        process,
        timeout_ms,
        max_response_bytes,
        Instant::now() + Duration::from_millis(timeout_ms),
    )
}

fn read_until_deadline(
    process: &MaudeProcess,
    timeout_ms: u64,
    max_response_bytes: usize,
    deadline: Instant,
) -> NifResult<String> {
    let mut buf = process
        .pending
        .lock()
        .map_err(|_| poison_error("pending"))?
        .split_off(0);

    let mut scan_start = 0;
    loop {
        if let Some(idx) = find_prompt_boundary(&buf, scan_start) {
            if idx > max_response_bytes {
                return Err(response_too_large_error(max_response_bytes));
            }

            let prefix = &buf[..idx];
            let text = std::str::from_utf8(prefix)
                .map_err(|error| io_error(format!("invalid UTF-8 in Maude output: {error}")))?
                .trim()
                .to_string();

            let remainder = buf[(idx + PROMPT.len())..].to_vec();
            *process
                .pending
                .lock()
                .map_err(|_| poison_error("pending"))? = remainder;

            return Ok(text);
        }

        if buf.len() > max_response_bytes.saturating_add(PROMPT.len()) {
            return Err(response_too_large_error(max_response_bytes));
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(timeout_error(timeout_ms));
        }

        match process.rx.recv_timeout(remaining) {
            Ok(ReaderMsg::Data(chunk)) => {
                scan_start = buf.len().saturating_sub(PROMPT.len() - 1);
                buf.extend_from_slice(&chunk);
            }
            Ok(ReaderMsg::Eof) => return Err(eof_error()),
            Ok(ReaderMsg::Io(msg)) => return Err(io_error(msg)),
            Err(RecvTimeoutError::Timeout) => return Err(timeout_error(timeout_ms)),
            Err(RecvTimeoutError::Disconnected) => return Err(eof_error()),
        }
    }
}

fn shutdown_process(process: &MaudeProcess) {
    process
        .writer
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    let child = process
        .child
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take();
    if let Some(mut child) = child {
        terminate_child(&mut child);
    }
    if let Ok(mut readers) = process.readers.lock() {
        for handle in readers.drain(..) {
            join_with_timeout(handle, READER_JOIN_TIMEOUT);
        }
    }
}

fn terminate_child(child: &mut Child) {
    if matches!(child.try_wait(), Ok(None)) {
        let _ = child.kill();
    }
    wait_with_timeout(child, READER_JOIN_TIMEOUT);
}

#[cfg(test)]
thread_local! {
    static SCANNED_WINDOWS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn find_prompt_boundary(haystack: &[u8], start: usize) -> Option<usize> {
    haystack[start..]
        .windows(PROMPT.len())
        .enumerate()
        .map(|(offset, window)| (start + offset, window))
        .find_map(|(idx, window)| {
            #[cfg(test)]
            SCANNED_WINDOWS.with(|count| count.set(count.get() + 1));
            let at_line_start = idx == 0 || matches!(haystack[idx - 1], b'\n' | b'\r');
            (window == PROMPT && at_line_start).then_some(idx)
        })
}

fn join_with_timeout(handle: JoinHandle<()>, timeout: Duration) {
    // std::thread::JoinHandle has no timed join — poll cheaply for `is_finished`
    // and bail out after `timeout`. The reader is bounded by `read` on a piped
    // stdout that has already been closed by `child.kill()`, so this normally
    // returns instantly.
    let deadline = Instant::now() + timeout;

    while Instant::now() < deadline {
        if handle.is_finished() {
            let _ = handle.join();
            return;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

// Errors are returned to Elixir as `{:error, term}` (Rustler's standard
// `Error::Term` wrapping), where `term` is one of:
//
//   * `{:timeout, ms}`
//   * `{:response_too_large, max_response_bytes}`
//   * `:eof`
//   * `{:io_error, msg}`
//   * `{:lock_poisoned, what}`
//
// The wrapper module in `lib/ex_maude/backend/nif.ex` pattern-matches on these.

fn timeout_error(ms: u64) -> Error {
    Error::Term(Box::new((atoms::timeout(), ms)))
}

fn response_too_large_error(max_response_bytes: usize) -> Error {
    Error::Term(Box::new((
        atoms::response_too_large(),
        max_response_bytes as u64,
    )))
}

fn eof_error() -> Error {
    Error::Term(Box::new(atoms::eof()))
}

fn io_error(msg: impl Into<String>) -> Error {
    Error::Term(Box::new((atoms::io_error(), msg.into())))
}

fn poison_error(what: &'static str) -> Error {
    Error::Term(Box::new((atoms::lock_poisoned(), what.to_string())))
}

#[cfg(test)]
mod tests {
    use super::find_prompt_boundary;

    #[test]
    fn response_reader_scans_fragmented_output_in_linear_work() {
        use super::*;
        let (tx, rx) = bounded(64);
        let size = 128 * 1024;
        for _ in 0..32 {
            tx.send(ReaderMsg::Data(vec![b'x'; 4096])).unwrap();
        }
        for byte in b"\nMaude> " {
            tx.send(ReaderMsg::Data(vec![*byte])).unwrap();
        }
        let process = MaudeProcess {
            child: Mutex::new(None),
            writer: Mutex::new(None),
            rx,
            readers: Mutex::new(Vec::new()),
            pending: Mutex::new(Vec::new()),
        };
        SCANNED_WINDOWS.with(|count| count.set(0));
        let output = read_until_prompt(&process, 1000, size + 1).unwrap();
        assert_eq!(output, "x".repeat(size));
        SCANNED_WINDOWS.with(|count| assert!(count.get() < size * 2));
    }

    #[test]
    fn incremental_scan_finds_every_split_prompt() {
        let bytes = b"payload Maude> marker\nMaude> ";
        for split in 0..bytes.len() {
            assert_eq!(find_prompt_boundary(&bytes[..split], 0), None);
            let start = split.saturating_sub(super::PROMPT.len() - 1);
            assert_eq!(find_prompt_boundary(bytes, start), Some(22));
        }
    }

    #[test]
    fn finds_complete_prompt_at_line_boundaries() {
        assert_eq!(find_prompt_boundary(b"Maude> ", 0), Some(0));
        assert_eq!(find_prompt_boundary(b"result\nMaude> ", 0), Some(7));
        assert_eq!(find_prompt_boundary(b"result\rMaude> ", 0), Some(7));
    }

    #[test]
    fn ignores_partial_and_prompt_like_payload_text() {
        assert_eq!(find_prompt_boundary(b"Maude>", 0), None);
        assert_eq!(find_prompt_boundary(b"payload Maude> marker", 0), None);
        assert_eq!(find_prompt_boundary(b"result only", 0), None);
    }
}

rustler::init!("Elixir.ExMaude.Backend.NIF.Native");
