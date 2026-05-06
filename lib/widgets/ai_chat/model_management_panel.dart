import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class ModelManagementPanel extends StatefulWidget {
  final ChatController chat;
  final ValueChanged<String>? onPick;

  const ModelManagementPanel({super.key, required this.chat, this.onPick});

  @override
  State<ModelManagementPanel> createState() => _ModelManagementPanelState();
}

class _ModelManagementPanelState extends State<ModelManagementPanel> {
  String? _provider;

  @override
  void initState() {
    super.initState();
    final providers = _providers(widget.chat.availableModels);
    _provider = providers.isNotEmpty ? providers.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final providers = _providers(chat.availableModels);
    _provider ??= providers.isNotEmpty ? providers.first : null;
    final provider = _provider;
    final providerModels = provider == null
        ? const <String>[]
        : chat.availableModels
              .where((m) => _providerOf(m) == provider)
              .toList();

    return Row(
      children: [
        SizedBox(
          width: 180,
          child: _ProviderColumn(
            providers: providers,
            selected: provider,
            onPick: (p) => setState(() => _provider = p),
            countFor: (p) =>
                chat.availableModels.where((m) => _providerOf(m) == p).length,
            enabledCountFor: (p) => chat.availableModels
                .where(
                  (m) => _providerOf(m) == p && chat.enabledModels.contains(m),
                )
                .length,
          ),
        ),
        Container(width: 0.5, color: DuckColors.glassSeam),
        Expanded(
          child: _ProviderModelsColumn(
            provider: provider,
            models: providerModels,
            selected: chat.selectedModel,
            enabledModels: chat.enabledModels,
            onEnableAll: provider == null
                ? null
                : () async {
                    await chat.setProviderModelsEnabled(provider, true);
                    if (mounted) setState(() {});
                  },
            onDisableAll: provider == null
                ? null
                : () async {
                    await chat.setProviderModelsEnabled(provider, false);
                    if (mounted) setState(() {});
                  },
            onToggle: (model, enabled) async {
              await chat.setModelEnabled(model, enabled);
              if (mounted) setState(() {});
            },
            onPick: (model) {
              chat.setModel(model);
              widget.onPick?.call(model);
              setState(() {});
            },
          ),
        ),
      ],
    );
  }
}

class ModelManagementDialog extends StatelessWidget {
  final ChatController chat;

  const ModelManagementDialog({super.key, required this.chat});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 560,
        height: 520,
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(color: DuckColors.borderStrong, width: 0.5),
          boxShadow: DuckTheme.shadowSoft,
        ),
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 10),
                  const Text(S.chatModelManageTitle, style: DuckTheme.titleS),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ModelManagementPanel(
                chat: chat,
                onPick: (model) => Navigator.pop(context, model),
              ),
            ),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(S.close),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderColumn extends StatelessWidget {
  final List<String> providers;
  final String? selected;
  final ValueChanged<String> onPick;
  final int Function(String provider) countFor;
  final int Function(String provider) enabledCountFor;

  const _ProviderColumn({
    required this.providers,
    required this.selected,
    required this.onPick,
    required this.countFor,
    required this.enabledCountFor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(S.chatModelProvidersTitle, style: DuckTheme.titleS),
          const SizedBox(height: 8),
          for (final p in providers)
            _ProviderRow(
              provider: p,
              selected: p == selected,
              enabledCount: enabledCountFor(p),
              totalCount: countFor(p),
              onTap: () => onPick(p),
            ),
        ],
      ),
    );
  }
}

class _ProviderModelsColumn extends StatelessWidget {
  final String? provider;
  final List<String> models;
  final String selected;
  final Set<String> enabledModels;
  final Future<void> Function()? onEnableAll;
  final Future<void> Function()? onDisableAll;
  final Future<void> Function(String model, bool enabled) onToggle;
  final ValueChanged<String> onPick;

  const _ProviderModelsColumn({
    required this.provider,
    required this.models,
    required this.selected,
    required this.enabledModels,
    this.onEnableAll,
    this.onDisableAll,
    required this.onToggle,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider == null
                ? S.chatModelProviderModelsTitle
                : _prettyProvider(provider!),
            style: DuckTheme.titleS,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: onEnableAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                child: const Text(S.chatModelEnableAll),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: onDisableAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  foregroundColor: DuckColors.fgMuted,
                ),
                child: const Text(S.chatModelDisableAll),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, i) {
                final m = models[i];
                return _ModelRow(
                  model: _rawModelName(m),
                  selected: m == selected,
                  enabled: enabledModels.contains(m),
                  onPick: enabledModels.contains(m) ? () => onPick(m) : null,
                  onToggle: (v) => onToggle(m, v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  final String provider;
  final bool selected;
  final int enabledCount;
  final int totalCount;
  final VoidCallback onTap;

  const _ProviderRow({
    required this.provider,
    required this.selected,
    required this.enabledCount,
    required this.totalCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: Border.all(
            color: selected ? DuckColors.accentCyan : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _prettyProvider(provider),
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? DuckColors.fgPrimary : DuckColors.fgMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              '$enabledCount/$totalCount',
              style: const TextStyle(fontSize: 10, color: DuckColors.fgSubtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final String model;
  final bool selected;
  final bool enabled;
  final VoidCallback? onPick;
  final ValueChanged<bool>? onToggle;

  const _ModelRow({
    required this.model,
    required this.selected,
    required this.enabled,
    this.onPick,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? DuckColors.accentCyan.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 13,
              color: selected ? DuckColors.accentCyan : DuckColors.fgSubtle,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                model,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: enabled ? DuckColors.fgPrimary : DuckColors.fgSubtle,
                ),
              ),
            ),
            Transform.scale(
              scale: 0.72,
              child: Switch(
                value: enabled,
                onChanged: onToggle,
                activeThumbColor: DuckColors.accentCyan,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _providers(List<String> models) {
  final set = <String>{for (final m in models) _providerOf(m)};
  // `ollama-cloud` sits next to `ollama` so the two Ollama
  // namespaces appear adjacent in the Model Management sidebar.
  final order = [
    'ollama',
    'ollama-cloud',
    'gemini',
    'claude',
    'github',
    'copilot',
    'openai',
  ];
  return set.toList()..sort((a, b) {
    final ai = order.indexOf(a);
    final bi = order.indexOf(b);
    if (ai != -1 || bi != -1) {
      return (ai == -1 ? 999 : ai).compareTo(bi == -1 ? 999 : bi);
    }
    return a.compareTo(b);
  });
}

String _providerOf(String model) {
  final idx = model.indexOf(':');
  return idx > 0 ? model.substring(0, idx) : 'ollama';
}

String _rawModelName(String model) {
  final idx = model.indexOf(':');
  return idx > 0 ? model.substring(idx + 1) : model;
}

String _prettyProvider(String provider) {
  return switch (provider) {
    'ollama' => S.providerOllama,
    'ollama-cloud' => S.providerOllamaCloud,
    'gemini' => S.providerGemini,
    'claude' => S.providerClaude,
    'github' => S.providerGithub,
    'copilot' => S.providerCopilot,
    'openai' => S.providerOpenAI,
    _ => provider,
  };
}
