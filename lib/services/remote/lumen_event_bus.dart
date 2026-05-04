import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../providers/chat_controller.dart';
import '../chat_persistence_service.dart';

/// Live-event fan-out for the Remote Access feature.
///
/// Bridges `ChatController.notifyListeners()` (a coarse "something
/// changed" signal, throttled to ~33ms during streaming) into
/// semantic events that paired devices subscribe to over a single
/// WebSocket. The bus diffs a lightweight snapshot of controller
/// state against the previous one to decide which events to emit —
/// so we don't have to touch the 2700-line controller to add a new
/// stream API. The diff cost per notify is O(visible sessions +
/// messages-in-active-session) which is negligible at personal
/// scale.
///
/// **Status:** loopback-only. Subscribed clients receive every
/// event the bus emits — there's no per-client filtering yet (the
/// auth pass introduces device-scoped filtering when it lands).
///
/// Lifecycle:
///
///   bus.attach(chatController);  // start listening + take baseline
///   bus.addClient(channel);       // each WS connection registers
///   bus.removeClient(channel);    // on close
///   bus.detach();                 // on app shutdown
///
/// Adding a client also triggers a one-shot `connected` envelope so
/// the client knows it's live without waiting for the next
/// notifyListeners.
class LumenEventBus {
  ChatController? _chat;
  final Set<WebSocketChannel> _clients = <WebSocketChannel>{};
  _Snapshot? _last;

  /// Optional per-client subprotocol, returned on the connected
  /// envelope so a future Android client can detect protocol skew
  /// against an older desktop.
  static const int kProtocolVersion = 1;

  /// Number of connected clients. Useful for the Settings UI status
  /// row in a later pass ("3 paired devices listening").
  int get clientCount => _clients.length;

  /// True once a chat controller is attached. Pre-attach `addClient`
  /// calls still work — the client just won't see any state diffs
  /// until `attach` runs (only the `connected` envelope).
  bool get isAttached => _chat != null;

  void attach(ChatController chat) {
    if (_chat == chat) return;
    detach();
    _chat = chat;
    _last = _capture(chat);
    chat.addListener(_onChatNotify);
  }

  void detach() {
    _chat?.removeListener(_onChatNotify);
    _chat = null;
    _last = null;
  }

  void addClient(WebSocketChannel ch) {
    _clients.add(ch);
    _sendTo(ch, _connectedEnvelope());
    final chat = _chat;
    if (chat != null) {
      _sendTo(ch, _stateChangedEvent(chat));
    }
  }

  void removeClient(WebSocketChannel ch) {
    _clients.remove(ch);
  }

  void disposeBus() {
    detach();
    for (final c in _clients) {
      try {
        c.sink.close();
      } catch (_) {
        // Sink already closed by the client side or the http server.
      }
    }
    _clients.clear();
  }

  Map<String, dynamic> _connectedEnvelope() => {
        'kind': 'connected',
        'protocolVersion': kProtocolVersion,
        'clientCount': _clients.length,
      };

  Map<String, dynamic> _stateChangedEvent(ChatController chat) => {
        'kind': 'state_changed',
        'isGenerating': chat.isGenerating,
        'currentSessionId': chat.currentSession?.id,
        'currentWorkspace': chat.currentWorkspace,
      };

  void _onChatNotify() {
    final chat = _chat;
    if (chat == null) return;
    final next = _capture(chat);
    final prev = _last ?? next;
    _last = next;

    final events = <Map<String, dynamic>>[];
    _diffState(prev, next, events);
    _diffSessionList(prev, next, events);
    _diffActiveMessages(prev, next, events);

    if (events.isEmpty) return;
    _broadcast(events);
  }

  void _diffState(
    _Snapshot prev,
    _Snapshot next,
    List<Map<String, dynamic>> out,
  ) {
    if (prev.isGenerating != next.isGenerating ||
        prev.currentSessionId != next.currentSessionId ||
        prev.currentWorkspace != next.currentWorkspace) {
      out.add({
        'kind': 'state_changed',
        'isGenerating': next.isGenerating,
        'currentSessionId': next.currentSessionId,
        'currentWorkspace': next.currentWorkspace,
      });
    }

    if (prev.currentWorkspace != next.currentWorkspace) {
      // Workspace switch wholesale changes the visible chat list.
      // Send a `chats_replaced` snapshot so clients don't have to
      // diff individual created/deleted events to figure it out.
      out.add({
        'kind': 'chats_replaced',
        'currentWorkspace': next.currentWorkspace,
        'chats': next.chatSummaries,
      });
    }
  }

  void _diffSessionList(
    _Snapshot prev,
    _Snapshot next,
    List<Map<String, dynamic>> out,
  ) {
    // chats_replaced already covered the whole list — skip granular
    // diffs in that case to avoid duplicate noise.
    if (prev.currentWorkspace != next.currentWorkspace) return;

    for (final id in next.chats.keys) {
      final p = prev.chats[id];
      final n = next.chats[id]!;
      if (p == null) {
        out.add({
          'kind': 'chat_created',
          'chat': n.summary,
        });
      } else if (p.title != n.title || p.updatedAt != n.updatedAt) {
        out.add({
          'kind': 'chat_updated',
          'chatId': id,
          'title': n.title,
          'updatedAt': n.updatedAt.toIso8601String(),
          'model': n.model,
        });
      }
    }
    for (final id in prev.chats.keys) {
      if (!next.chats.containsKey(id)) {
        out.add({
          'kind': 'chat_deleted',
          'chatId': id,
        });
      }
    }
  }

  void _diffActiveMessages(
    _Snapshot prev,
    _Snapshot next,
    List<Map<String, dynamic>> out,
  ) {
    // Only diff messages for the active session. Other sessions in
    // `controller.sessions` carry empty message lists by design (see
    // `ChatPersistenceService._rebuildIndex`), so message-level
    // events outside the active chat would be permanently silent.
    final active = next.activeSession;
    if (active == null) return;
    if (prev.currentSessionId != next.currentSessionId) {
      // The user just switched chats. Don't emit per-message events
      // against the old chat's snapshot — clients can fetch the new
      // chat fresh via `GET /v1/chats/{id}`. The state_changed event
      // already told them which one is active now.
      return;
    }

    final prevMsgs = prev.activeMessages;
    final nextMsgs = next.activeMessages;

    for (final m in nextMsgs.entries) {
      final id = m.key;
      final n = m.value;
      final p = prevMsgs[id];
      if (p == null) {
        out.add({
          'kind': 'message_added',
          'chatId': active.id,
          'message': n.toJson(),
        });
      } else if (p.contentLength != n.contentLength ||
          p.imagesCount != n.imagesCount) {
        out.add({
          'kind': 'message_delta',
          'chatId': active.id,
          'messageId': id,
          'role': n.role,
          'content': n.content,
        });
      }
    }
    for (final id in prevMsgs.keys) {
      if (!nextMsgs.containsKey(id)) {
        out.add({
          'kind': 'message_deleted',
          'chatId': active.id,
          'messageId': id,
        });
      }
    }

    // Streaming finished signal: was generating, now isn't. Clients
    // use this to flip their local "thinking" indicator off and treat
    // the most recent assistant message as final.
    if (prev.isGenerating && !next.isGenerating) {
      String? lastAssistantId;
      for (final m in nextMsgs.values) {
        if (m.role == 'assistant') lastAssistantId = m.id;
      }
      if (lastAssistantId != null) {
        out.add({
          'kind': 'message_complete',
          'chatId': active.id,
          'messageId': lastAssistantId,
        });
      }
    }
  }

  void _broadcast(List<Map<String, dynamic>> events) {
    if (_clients.isEmpty) return;
    final encoded = events.map(jsonEncode).toList();
    final dead = <WebSocketChannel>[];
    for (final c in _clients) {
      try {
        for (final e in encoded) {
          c.sink.add(e);
        }
      } catch (_) {
        // Sink errored — most often "WebSocket already closed" from
        // a client that walked away without a close frame. Drop it
        // outside the loop so we don't mutate the set mid-iteration.
        dead.add(c);
      }
    }
    for (final c in dead) {
      _clients.remove(c);
    }
  }

  void _sendTo(WebSocketChannel ch, Map<String, dynamic> event) {
    try {
      ch.sink.add(jsonEncode(event));
    } catch (_) {
      // Same drop-on-error policy as broadcast. The next add to the
      // same dead sink in `_broadcast` will register the failure.
    }
  }

  _Snapshot _capture(ChatController chat) {
    final sessions = chat.sessions;
    final chats = <String, _ChatSig>{};
    final summaries = <Map<String, dynamic>>[];
    for (final s in sessions) {
      final sig = _ChatSig(
        id: s.id,
        title: s.title,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
        workspacePath: s.workspacePath,
        model: s.model,
      );
      chats[s.id] = sig;
      // Reuse `_ChatSig.summary` so `chats_replaced` and
      // `chat_created` payloads can never drift in shape — they
      // both go through the same getter. Schema must also match
      // `_chatSummary` in `lumen_routes.dart` so REST and WS
      // clients consume one shape.
      summaries.add(sig.summary);
    }

    final active = chat.currentSession;
    final activeMessages = <String, _MessageSig>{};
    if (active != null) {
      for (final m in active.messages) {
        activeMessages[m.id] = _MessageSig(
          id: m.id,
          role: m.role,
          content: m.content,
          contentLength: m.content.length,
          imagesCount: m.imagesBase64.length,
          timestamp: m.timestamp,
        );
      }
    }

    return _Snapshot(
      isGenerating: chat.isGenerating,
      currentSessionId: active?.id,
      currentWorkspace: chat.currentWorkspace,
      chats: chats,
      activeSession: active,
      activeMessages: activeMessages,
      chatSummaries: summaries,
    );
  }
}

class _Snapshot {
  _Snapshot({
    required this.isGenerating,
    required this.currentSessionId,
    required this.currentWorkspace,
    required this.chats,
    required this.activeSession,
    required this.activeMessages,
    required this.chatSummaries,
  });

  final bool isGenerating;
  final String? currentSessionId;
  final String? currentWorkspace;
  final Map<String, _ChatSig> chats;
  final ChatSession? activeSession;
  final Map<String, _MessageSig> activeMessages;
  final List<Map<String, dynamic>> chatSummaries;
}

class _ChatSig {
  _ChatSig({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.workspacePath,
    required this.model,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? workspacePath;
  final String? model;

  /// Canonical chat-summary shape. Mirrors `_chatSummary` in
  /// `lumen_routes.dart` so a Lumen client can decode WS events
  /// and REST responses with the same parser. If you change one
  /// shape, change the other — there's no compile-time link.
  Map<String, dynamic> get summary => {
        'id': id,
        'title': title,
        'model': model,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'workspacePath': workspacePath,
      };
}

@immutable
class _MessageSig {
  const _MessageSig({
    required this.id,
    required this.role,
    required this.content,
    required this.contentLength,
    required this.imagesCount,
    required this.timestamp,
  });

  final String id;
  final String role;
  final String content;
  final int contentLength;
  final int imagesCount;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'content': content,
        'imagesCount': imagesCount,
        'timestamp': timestamp.toIso8601String(),
      };
}
