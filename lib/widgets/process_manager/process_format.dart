/// Formatting helpers shared by the process manager rows and footer.
class ProcessFormat {
  ProcessFormat._();

  /// Human-readable bytes — `B / KB / MB / GB`. Avoids `package:intl`
  /// because the IDE doesn't depend on it; keeping the formatter
  /// trivial here means the table can render 500+ rows without a
  /// per-frame dependency on a heavyweight i18n graph.
  static String memory(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      final mb = bytes / (1024 * 1024);
      return mb >= 100
          ? '${mb.toStringAsFixed(0)} MB'
          : '${mb.toStringAsFixed(1)} MB';
    }
    final gb = bytes / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(2)} GB';
  }

  /// Truncates a command line to `max` chars with a centered ellipsis
  /// — keeps the executable head visible AND the trailing args. A
  /// pure `s.substring(0, max)` would always cut the args, hiding
  /// the "what is this process actually doing" part the user
  /// usually cares about.
  static String trimCommand(String? cmd, {int max = 140}) {
    if (cmd == null || cmd.isEmpty) return '';
    if (cmd.length <= max) return cmd;
    final head = (max * 0.55).round();
    final tail = max - head - 1;
    return '${cmd.substring(0, head)}…${cmd.substring(cmd.length - tail)}';
  }
}
