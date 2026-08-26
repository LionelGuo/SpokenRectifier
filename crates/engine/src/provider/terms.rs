//! Hotword dictionary source (glossary: 术语词表).
//!
//! The engine reads the dictionary when a session starts, so an edit takes
//! effect on the next session, never mid-session: the session's
//! recognition bias and its rectify term reference always agree. The two
//! injection paths split at the ASR port — providers that can bias
//! recognition receive the terms when the stream opens, and the rectify
//! prompt carries them as the term reference for every provider.

/// Where the engine reads the hotword dictionary at each session start.
pub trait TermSource: Send + Sync {
    /// The dictionary's terms in dictionary order. Implementations read
    /// fresh per call; an absent dictionary yields no terms.
    fn terms(&self) -> Vec<String>;
}
