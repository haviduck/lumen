import 'package:flutter/foundation.dart';

/// Imperative API for the inter-agent network mesh.
///
/// Anyone (Signal on agent failure, the council protocol on dispatch,
/// debug/dev tooling) can fire a packet between two agents without
/// having to push a synthetic [CouncilEvent] into the session.
///
/// The traffic layer listens to this controller and animates packets
/// along the persistent edge graph drawn by the painter.
///
/// Lifetime contract: packets self-prune after [packetTtl]; callers
/// never have to clean up.
enum NetworkPacketKind { message, reply, error }

class NetworkPacket {
  final int id;
  final String fromId;
  final String toId;
  final NetworkPacketKind kind;
  final DateTime spawnedAt;
  final double speedScale;

  NetworkPacket({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.kind,
    required this.spawnedAt,
    this.speedScale = 1.0,
  });
}

class NetworkController extends ChangeNotifier {
  static const Duration packetTtl = Duration(milliseconds: 2400);
  static const Duration errorPacketTtl = Duration(milliseconds: 1600);

  int _nextId = 0;
  final List<NetworkPacket> _packets = <NetworkPacket>[];

  List<NetworkPacket> get packets => List.unmodifiable(_packets);

  /// Emit a single packet from [fromId] → [toId].
  ///
  /// * `message` (default): cyan packet, normal speed.
  /// * `reply`: mint packet, slightly faster, slightly thinner trail.
  /// * `error`: red packet, fast, strobing, bigger halo. Signal calls
  ///   this on `agent_error`.
  void pulse(
    String fromId,
    String toId, {
    NetworkPacketKind kind = NetworkPacketKind.message,
  }) {
    if (fromId.isEmpty || toId.isEmpty || fromId == toId) return;
    _prune();
    final speedScale = switch (kind) {
      NetworkPacketKind.error => 1.55,
      NetworkPacketKind.reply => 1.15,
      NetworkPacketKind.message => 1.0,
    };
    _packets.add(
      NetworkPacket(
        id: _nextId++,
        fromId: fromId,
        toId: toId,
        kind: kind,
        spawnedAt: DateTime.now(),
        speedScale: speedScale,
      ),
    );
    if (kind == NetworkPacketKind.error) {
      // Error pulses fire a short triple-burst so failures read as
      // "something is wrong on this edge", not a normal message.
      Future.delayed(const Duration(milliseconds: 140), () {
        if (_disposed) return;
        _packets.add(
          NetworkPacket(
            id: _nextId++,
            fromId: fromId,
            toId: toId,
            kind: kind,
            spawnedAt: DateTime.now(),
            speedScale: speedScale,
          ),
        );
        notifyListeners();
      });
      Future.delayed(const Duration(milliseconds: 320), () {
        if (_disposed) return;
        _packets.add(
          NetworkPacket(
            id: _nextId++,
            fromId: fromId,
            toId: toId,
            kind: kind,
            spawnedAt: DateTime.now(),
            speedScale: speedScale,
          ),
        );
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void _prune() {
    final now = DateTime.now();
    _packets.removeWhere((p) {
      final ttl = p.kind == NetworkPacketKind.error
          ? errorPacketTtl
          : packetTtl;
      return now.difference(p.spawnedAt) > ttl;
    });
  }

  /// Painter calls this each frame to keep the in-memory list bounded.
  /// Public so the traffic layer can prune without notifying.
  void prune() => _prune();

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    _packets.clear();
    super.dispose();
  }
}
