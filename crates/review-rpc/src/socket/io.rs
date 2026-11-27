//! Bounded line framing and stop-aware socket I/O helpers for the Unix domain
//! socket server.

use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::Value;

pub(super) const CLIENT_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
pub(super) const CLIENT_LINE_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_SOCKET_LINE_BYTES: usize = 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub(super) enum LineRead {
    Line(String),
    Eof,
    Stopped,
    TimedOut,
    TooLong,
    InvalidUtf8,
}

pub(super) fn read_bounded_line(
    stream: &mut UnixStream,
    buffer: &mut Vec<u8>,
    stopped: &AtomicBool,
) -> std::io::Result<LineRead> {
    read_bounded_line_with_limits(
        stream,
        buffer,
        stopped,
        MAX_SOCKET_LINE_BYTES,
        CLIENT_IDLE_TIMEOUT,
        CLIENT_LINE_TIMEOUT,
    )
}

fn read_bounded_line_with_limits(
    stream: &mut UnixStream,
    buffer: &mut Vec<u8>,
    stopped: &AtomicBool,
    max_bytes: usize,
    idle_timeout: Duration,
    line_timeout: Duration,
) -> std::io::Result<LineRead> {
    if stopped.load(Ordering::Acquire) {
        return Ok(LineRead::Stopped);
    }
    if let Some(outcome) = take_buffered_line(buffer, max_bytes, false) {
        return Ok(outcome);
    }
    let line_started = Instant::now();
    let mut last_activity = line_started;
    let mut chunk = [0_u8; 4096];
    while last_activity.elapsed() < idle_timeout && line_started.elapsed() < line_timeout {
        if stopped.load(Ordering::Acquire) {
            return Ok(LineRead::Stopped);
        }
        match stream.read(&mut chunk) {
            Ok(0) => {
                return Ok(take_buffered_line(buffer, max_bytes, true).unwrap_or(LineRead::Eof));
            }
            Ok(read_count) => {
                last_activity = Instant::now();
                buffer.extend_from_slice(&chunk[..read_count]);
                if let Some(outcome) = take_buffered_line(buffer, max_bytes, false) {
                    return Ok(outcome);
                }
                if buffer.len() > max_bytes {
                    return Ok(LineRead::TooLong);
                }
            }
            Err(error) if is_retryable_io_error(error.kind()) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(LineRead::TimedOut)
}

fn take_buffered_line(buffer: &mut Vec<u8>, max_bytes: usize, is_eof: bool) -> Option<LineRead> {
    if let Some(newline_index) = buffer.iter().position(|byte| *byte == b'\n') {
        if newline_index + 1 > max_bytes {
            return Some(LineRead::TooLong);
        }
        let line_bytes: Vec<u8> = buffer.drain(..=newline_index).collect();
        return Some(bytes_to_line_read(line_bytes));
    }
    if is_eof && !buffer.is_empty() {
        if buffer.len() > max_bytes {
            return Some(LineRead::TooLong);
        }
        let line_bytes = std::mem::take(buffer);
        return Some(bytes_to_line_read(line_bytes));
    }
    None
}

fn bytes_to_line_read(bytes: Vec<u8>) -> LineRead {
    String::from_utf8(bytes).map_or(LineRead::InvalidUtf8, LineRead::Line)
}

const fn is_retryable_io_error(kind: ErrorKind) -> bool {
    matches!(
        kind,
        ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
    )
}

pub(super) fn write_socket_reply(
    stream: &mut UnixStream,
    message: &Value,
    stopped: &AtomicBool,
) -> Result<()> {
    write_socket_reply_with_timeout(stream, message, stopped, CLIENT_IDLE_TIMEOUT)
}

fn write_socket_reply_with_timeout(
    stream: &mut UnixStream,
    message: &Value,
    stopped: &AtomicBool,
    write_timeout: Duration,
) -> Result<()> {
    let mut line = serde_json::to_vec(message).context("encoding socket reply")?;
    line.push(b'\n');
    let started = Instant::now();
    let mut written = 0;
    while written < line.len() {
        if stopped.load(Ordering::Acquire) {
            bail!("socket server stopped while writing reply");
        }
        if started.elapsed() >= write_timeout {
            bail!("timed out writing socket reply");
        }
        match stream.write(&line[written..]) {
            Ok(0) => bail!("socket closed while writing reply"),
            Ok(bytes_written) => written += bytes_written,
            Err(error) if is_retryable_io_error(error.kind()) => {}
            Err(error) => return Err(error).context("writing socket reply"),
        }
    }
    stream.flush().context("flushing socket reply")
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use serde_json::json;

    use super::*;

    fn fill_socket_send_buffer(stream: &mut UnixStream) {
        stream.set_nonblocking(true).unwrap();
        let chunk = [b'x'; 8192];
        loop {
            match stream.write(&chunk) {
                Ok(0) => break,
                Ok(_) => {}
                Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                Err(error) => panic!("unexpected write error filling buffer: {error}"),
            }
        }
        stream.set_nonblocking(false).unwrap();
        stream
            .set_write_timeout(Some(Duration::from_millis(10)))
            .unwrap();
    }

    #[test]
    fn bounded_line_reader_rejects_oversized_and_non_utf8_lines() {
        let stopped = AtomicBool::new(false);
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_millis(10)))
            .unwrap();
        writer.write_all(b"123456789\n").unwrap();
        let mut buffer = Vec::new();
        let too_long = read_bounded_line_with_limits(
            &mut reader,
            &mut buffer,
            &stopped,
            5,
            Duration::from_millis(200),
            Duration::from_millis(500),
        )
        .unwrap();
        assert_eq!(too_long, LineRead::TooLong);

        buffer.clear();
        writer.write_all(&[0xff, 0xfe, b'\n']).unwrap();
        let bad_utf8 = read_bounded_line_with_limits(
            &mut reader,
            &mut buffer,
            &stopped,
            64,
            Duration::from_millis(200),
            Duration::from_millis(500),
        )
        .unwrap();
        assert_eq!(bad_utf8, LineRead::InvalidUtf8);
    }

    #[test]
    fn bounded_line_reader_enforces_idle_and_total_line_timeouts() {
        let stopped = AtomicBool::new(false);
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        reader
            .set_read_timeout(Some(Duration::from_millis(10)))
            .unwrap();
        let mut buffer = Vec::new();
        let idle = read_bounded_line_with_limits(
            &mut reader,
            &mut buffer,
            &stopped,
            64,
            Duration::from_millis(25),
            Duration::from_millis(500),
        )
        .unwrap();
        assert_eq!(idle, LineRead::TimedOut);

        let trickle_handle = thread::spawn(move || {
            for _ in 0..8 {
                let _ = writer.write_all(b"a");
                thread::sleep(Duration::from_millis(15));
            }
        });
        let trickle = read_bounded_line_with_limits(
            &mut reader,
            &mut buffer,
            &stopped,
            64,
            Duration::from_millis(200),
            Duration::from_millis(50),
        )
        .unwrap();
        assert_eq!(trickle, LineRead::TimedOut);
        let _ = trickle_handle.join();
    }

    #[test]
    fn write_socket_reply_aborts_on_timeout_and_stop_when_peer_stalls() {
        let stopped = Arc::new(AtomicBool::new(false));
        let (mut writer, _reader) = UnixStream::pair().unwrap();
        fill_socket_send_buffer(&mut writer);

        let timed_out = write_socket_reply_with_timeout(
            &mut writer,
            &json!({ "ok": true }),
            &stopped,
            Duration::from_millis(25),
        );
        assert!(timed_out.is_err());

        let cancel_flag = Arc::clone(&stopped);
        let cancel_handle = thread::spawn(move || {
            thread::sleep(Duration::from_millis(20));
            cancel_flag.store(true, Ordering::Release);
        });
        let started = Instant::now();
        let aborted = write_socket_reply_with_timeout(
            &mut writer,
            &json!({ "ok": true }),
            &stopped,
            Duration::from_secs(5),
        );
        assert!(aborted.is_err());
        assert!(started.elapsed() < Duration::from_secs(1));
        let _ = cancel_handle.join();
    }
}
