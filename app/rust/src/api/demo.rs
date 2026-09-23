//! The fake-engine demo seam: scripted speech feeding and the fake
//! inserter's introspection (headless demos and tests).

use anyhow::anyhow;

use spokenrectifier_engine::fakes::AsrFeed;

use super::state::{global, Global, InserterSlot, SpeechSource};

/// Everything the fake inserter received, in order (demo introspection).
/// The production inserter does not record; insertion outcomes arrive on
/// the event stream instead (`TextInserted` / `Error`).
pub fn inserted_texts() -> anyhow::Result<Vec<String>> {
    match &global()?.inserter {
        InserterSlot::Fake(fake) => Ok(fake.inserted_texts()),
        InserterSlot::Real(_) => Err(anyhow!(
            "the production inserter does not record inserted texts"
        )),
    }
}

/// Open the next fake ASR session and allow `fake_say` / `fake_silence` to
/// feed it. Call before `execute(BridgeCommand::StartSession)`.
pub fn fake_begin_session() -> anyhow::Result<()> {
    let g = global()?;
    let SpeechSource::Fake { scripter, feed } = &g.source else {
        return Err(anyhow!(
            "engine is in microphone mode; fake speech is unavailable"
        ));
    };
    *feed.lock().unwrap() = Some(scripter.begin_session());
    Ok(())
}

/// The open fake-session feed, shared by `fake_say` / `fake_silence`.
fn open_fake_feed(g: &Global) -> anyhow::Result<AsrFeed> {
    let SpeechSource::Fake { feed, .. } = &g.source else {
        return Err(anyhow!(
            "engine is in microphone mode; fake speech is unavailable"
        ));
    };
    feed.lock()
        .unwrap()
        .clone()
        .ok_or_else(|| anyhow!("no fake session open; call fake_begin_session first"))
}

/// Feed one scripted phrase (partial, then final) into the open session.
pub fn fake_say(text: String) -> anyhow::Result<()> {
    let g = global()?;
    let feed = open_fake_feed(g)?;
    g.rt.block_on(feed.say(&text));
    Ok(())
}

/// Feed one scripted cumulative-silence event (milliseconds) into the open
/// session.
pub fn fake_silence(elapsed_ms: u64) -> anyhow::Result<()> {
    let g = global()?;
    let feed = open_fake_feed(g)?;
    g.rt.block_on(feed.silence(elapsed_ms));
    Ok(())
}
