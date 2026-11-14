use crate::{stdin_ansi_parser::SyncOutput, write_render_output};
use std::io::{self, Write};

#[derive(Default)]
struct TerminalWriter {
    output: Vec<u8>,
    fail_after: Option<usize>,
    fail_on_flush: bool,
    flushed: bool,
}

impl Write for TerminalWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let remaining = self
            .fail_after
            .map(|limit| limit.saturating_sub(self.output.len()))
            .unwrap_or(usize::MAX);
        if remaining == 0 {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "terminal closed"));
        }
        // Short writes also occur on healthy terminals.
        let written = bytes.len().min(remaining).min(3);
        self.output.extend_from_slice(&bytes[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.flushed = true;
        if self.fail_on_flush {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "terminal closed"));
        }
        Ok(())
    }
}

fn render_cases() -> [(Option<SyncOutput>, &'static [u8]); 3] {
    [
        (None, b"hello"),
        (Some(SyncOutput::CSI), b"\x1b[?2026hhello\x1b[?2026l"),
        (Some(SyncOutput::DCS), b"\x1bP=1s\x1bhello\x1bP=2s\x1b"),
    ]
}

#[test]
fn render_preserves_output_and_flushes_with_partial_writes() {
    for (sync, expected) in render_cases() {
        let mut writer = TerminalWriter::default();

        write_render_output(&mut writer, "hello", sync).unwrap();

        assert_eq!(writer.output, expected);
        assert!(writer.flushed);
    }
}

#[test]
fn render_returns_errors_when_terminal_closes_during_any_output_stage() {
    for (sync, expected) in render_cases() {
        // Include failure in the synchronization prefix, text, and suffix.
        for fail_after in 0..expected.len() {
            let mut writer = TerminalWriter {
                fail_after: Some(fail_after),
                ..TerminalWriter::default()
            };

            let error = write_render_output(&mut writer, "hello", sync).unwrap_err();

            assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
            assert_eq!(writer.output, expected[..fail_after]);
            assert!(!writer.flushed);
        }
    }
}

#[test]
fn render_returns_errors_when_terminal_closes_during_flush() {
    for (sync, expected) in render_cases() {
        let mut writer = TerminalWriter {
            fail_on_flush: true,
            ..TerminalWriter::default()
        };

        let error = write_render_output(&mut writer, "hello", sync).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        assert_eq!(writer.output, expected);
        assert!(writer.flushed);
    }
}
