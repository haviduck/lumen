import 'package:flutter/material.dart';

import '../../../providers/app_state.dart';
import '../../../providers/chat_controller.dart';

/// Result of running a slash command.
///
/// - [textToSend] is the message that goes into the chat pipeline. Set
///   to `null` to suppress sending entirely (e.g. command opens a UI
///   dialog instead).
/// - [clearComposer] tells the host to wipe the input box after the
///   command resolves. Most commands want this.
class SlashCommandResult {
  final String? textToSend;
  final bool clearComposer;

  const SlashCommandResult({this.textToSend, this.clearComposer = true});

  /// Convenience: command produced no message, just close the picker
  /// and leave the composer alone.
  static const SlashCommandResult noop = SlashCommandResult(
    textToSend: null,
    clearComposer: false,
  );
}

/// Context passed to a [SlashCommand] when it runs. Lets the command
/// peek at the chat controller, app state, and the original raw input
/// (e.g. `/handoff trailing args`) without needing to plumb all of
/// that through every call site.
class SlashCommandContext {
  final BuildContext buildContext;
  final ChatController chat;
  final AppState appState;

  /// Anything the user typed after the command name, with leading
  /// whitespace stripped. Empty for bare commands like `/handoff`.
  final String args;

  const SlashCommandContext({
    required this.buildContext,
    required this.chat,
    required this.appState,
    required this.args,
  });
}

/// One entry in the slash-command registry. Subclass per command —
/// keeps each command's expansion logic isolated and testable.
abstract class SlashCommand {
  /// Name without the leading `/`. Lowercase, alphanumeric + dashes.
  String get name;

  /// One-line description shown in the picker.
  String get description;

  /// Icon shown next to the name in the picker.
  IconData get icon;

  /// Run the command. Most commands return a [SlashCommandResult]
  /// with `textToSend` set to the expanded prompt that will be sent
  /// through the normal `ChatController.sendMessage` path.
  Future<SlashCommandResult> run(SlashCommandContext ctx);

  /// `true` when the command's name (or description) matches [query].
  /// Empty query matches everything — used when the user has typed
  /// just `/` and is browsing.
  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q);
  }
}

/// Process-wide registry of available slash commands. We deliberately
/// keep this static for v1 — there are not enough commands to justify
/// DI, and the chat panel needs synchronous access during keystroke
/// handling.
class SlashCommandRegistry {
  SlashCommandRegistry._();

  static final List<SlashCommand> _commands = <SlashCommand>[];

  /// Register a command. Idempotent on [SlashCommand.name].
  static void register(SlashCommand command) {
    _commands.removeWhere((c) => c.name == command.name);
    _commands.add(command);
  }

  /// All commands, sorted alphabetically by name. Picker filters on
  /// top of this list.
  static List<SlashCommand> all() {
    final sorted = List<SlashCommand>.from(_commands);
    sorted.sort((a, b) => a.name.compareTo(b.name));
    return sorted;
  }

  /// Find the command whose name exactly matches [name] (case
  /// insensitive). Returns `null` when nothing matches.
  static SlashCommand? findExact(String name) {
    final lowered = name.toLowerCase();
    for (final c in _commands) {
      if (c.name.toLowerCase() == lowered) return c;
    }
    return null;
  }

  /// Filtered, sorted list for a given query (the text after the `/`,
  /// before any whitespace). Used by the picker.
  static List<SlashCommand> filter(String query) {
    final out = all().where((c) => c.matches(query)).toList();
    out.sort((a, b) {
      final aStarts = a.name.startsWith(query.toLowerCase());
      final bStarts = b.name.startsWith(query.toLowerCase());
      if (aStarts != bStarts) return aStarts ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }
}

/// Parse a raw input string into a possible slash-command invocation.
/// Returns `null` when the input does not start with a `/`. The
/// command name is everything after the `/` up to the first
/// whitespace; everything else is `args`.
class SlashCommandInput {
  final String name;
  final String args;

  const SlashCommandInput({required this.name, required this.args});

  static SlashCommandInput? tryParse(String raw) {
    final text = raw.trimLeft();
    if (!text.startsWith('/')) return null;
    final rest = text.substring(1);
    if (rest.isEmpty) return const SlashCommandInput(name: '', args: '');
    final wsIdx = rest.indexOf(RegExp(r'\s'));
    if (wsIdx < 0) {
      return SlashCommandInput(name: rest, args: '');
    }
    return SlashCommandInput(
      name: rest.substring(0, wsIdx),
      args: rest.substring(wsIdx).trimLeft(),
    );
  }
}
