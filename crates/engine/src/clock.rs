//! Injectable time source.
//!
//! Ticket "engine API seam" only needs wall timestamps for events. The
//! latency budget (short ≤3 s, hard ceiling ≤25 s) will extend this trait
//! with sleep/timeout when the rectify pipeline and insertion land.

use std::time::Instant;

pub trait Clock: Send + Sync {
    /// Milliseconds since an arbitrary epoch; monotonic for real impls.
    fn now_ms(&self) -> u64;
}

/// Real clock backed by [`Instant`].
#[derive(Debug)]
pub struct TokioClock {
    epoch: Instant,
}

impl TokioClock {
    pub fn new() -> Self {
        Self {
            epoch: Instant::now(),
        }
    }
}

impl Default for TokioClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for TokioClock {
    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }
}
