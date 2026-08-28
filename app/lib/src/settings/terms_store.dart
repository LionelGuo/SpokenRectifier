/// The settings window's terms seam: the hotword dictionary file, read
/// and written directly through the Rust bridge — the very same calls
/// the quick panel's quick-add and quick-remove make (同源同文件, ticket
/// 19), plus the rename the editor adds. File-level and engine-
/// independent: the engine re-reads the file when the next session
/// opens, which is what makes every edit here live for that session.
/// Injectable so widget tests run with an in-memory dictionary and no
/// Rust dylib.

library;

import '../rust/api.dart' as rust show appendTerm, removeTerm, termsList, updateTerm;

/// Hotword-dictionary persistence as the terms domain needs it.
abstract class TermsStore {
  /// The dictionary as the loader reads it, in file order (a missing or
  /// unreadable file is an empty dictionary).
  Future<List<String>> load();

  /// Add one term (the quick panel's quick-add, the same bridge call;
  /// idempotent, blank rejected).
  Future<void> add(String term);

  /// Rename a term in place, keeping its position (an error when the
  /// new name already exists or the old one is gone).
  Future<void> update(String oldTerm, String newTerm);

  /// Remove a term (the quick panel's quick-remove, the same bridge
  /// call; a no-op when absent).
  Future<void> remove(String term);
}

/// The production store over the flutter_rust_bridge calls.
class RustTermsStore implements TermsStore {
  const RustTermsStore();

  @override
  Future<List<String>> load() => rust.termsList();

  @override
  Future<void> add(String term) => rust.appendTerm(term: term);

  @override
  Future<void> update(String oldTerm, String newTerm) =>
      rust.updateTerm(old: oldTerm, new_: newTerm);

  @override
  Future<void> remove(String term) => rust.removeTerm(term: term);
}
