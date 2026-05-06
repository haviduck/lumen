import 'dart:async';

typedef CouncilLockedOperation<T> = Future<T> Function();

class CouncilToolLock {
  CouncilToolLock({Set<String>? lockedToolIds})
    : lockedToolIds =
          lockedToolIds ??
          const {
            'create_file',
            'edit_file',
            'multi_edit',
            'edit_range',
            'append_file',
            'delete_file',
            'move_file',
            'copy_file',
            'run_cmd',
          };

  final Set<String> lockedToolIds;
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  bool shouldLock(String toolId) => lockedToolIds.contains(toolId);

  Future<T> run<T>(String toolId, CouncilLockedOperation<T> operation) async {
    if (!shouldLock(toolId)) return operation();

    final previous = _tails[toolId] ?? Future<void>.value();
    final gate = previous.catchError((_) {});
    final completer = Completer<void>();
    _tails[toolId] = completer.future;

    try {
      await gate;
      return await operation();
    } finally {
      completer.complete();
      if (identical(_tails[toolId], completer.future)) {
        _tails.remove(toolId);
      }
    }
  }
}
