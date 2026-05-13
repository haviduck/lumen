/// Role-signature dispatch helper
/// ===============================
///
/// The agent card used to render a single generic `_DigitalGridPainter`
/// regardless of role — a pentester card and a writer card looked
/// identical except for the text label. This module breaks that out
/// into per-role [CustomPainter]s that paint a distinct background
/// texture behind the voice panel + status block + transcript well, so
/// a glance at the council ring tells the user which specialist is
/// where without reading the labels.
///
/// Contract:
///   * Every signature is SUBTLE — alpha range typically 0.04–0.12 on
///     the patterns. The voice panel's primary narration and the
///     cadence spectrum take visual priority.
///   * Every signature animates softly via [idleT] (0..1 bounce from
///     the host card's `_idle` controller — landmine: do NOT add a
///     per-card vsync) and bumps slightly on `active`.
///   * Every painter's [shouldRepaint] returns true only when one of
///     the four shared parameters actually changed. Phase changes on
///     the orchestrator card piggy-back on [idleT] which ticks every
///     frame anyway, so no extra plumbing is required for repaint
///     freshness.
///   * Painters do NOT introduce any green hex literals. The
///     `council_no_green_test.dart` static guard would catch them.
///
/// Each file under this directory exports one painter plus a small
/// constants block (preferred accent + fallback accent) so the calling
/// site can override the accent ramp for tone overlays (errored /
/// done) while keeping the role's "vibe" intact.
library;

import 'package:flutter/material.dart';

import '../../../services/council/council_models.dart';
import 'role_signature_architect.dart';
import 'role_signature_custom.dart';
import 'role_signature_orchestrator.dart';
import 'role_signature_pentester.dart';
import 'role_signature_researcher.dart';
import 'role_signature_reviewer.dart';
import 'role_signature_tester.dart';
import 'role_signature_writer.dart';

/// Builds the appropriate [CustomPainter] for the agent card background
/// texture. The orchestrator gets a dedicated signature regardless of
/// [role] — it's the conductor, not a domain specialist.
CustomPainter buildRoleSignaturePainter({
  required RolePreset role,
  required bool active,
  required double idleT,
  required Color accent,
  required bool isOrchestrator,
  CouncilPhase? currentPhase,
}) {
  if (isOrchestrator) {
    return OrchestratorRoleSignaturePainter(
      active: active,
      idleT: idleT,
      accent: accent,
      currentPhase: currentPhase ?? CouncilPhase.discovery,
    );
  }
  switch (role) {
    case RolePreset.pentester:
      return PentesterRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.reviewer:
      return ReviewerRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.researcher:
      return ResearcherRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.architect:
      return ArchitectRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.tester:
      return TesterRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.writer:
      return WriterRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
    case RolePreset.custom:
      return CustomRoleSignaturePainter(
        active: active,
        idleT: idleT,
        accent: accent,
      );
  }
}
