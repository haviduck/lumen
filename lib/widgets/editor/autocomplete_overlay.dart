import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class EditorAutocompleteList extends StatefulWidget
    implements PreferredSizeWidget {
  static const double _itemHeight = 28;
  static const double _maxHeight = 180;
  static const double _width = 280;

  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;

  const EditorAutocompleteList({
    super.key,
    required this.notifier,
    required this.onSelected,
  });

  @override
  Size get preferredSize {
    final height = math.min(_itemHeight * widgetPromptCount, _maxHeight) + 2;
    return Size(_width, height);
  }

  int get widgetPromptCount => notifier.value.prompts.length;

  @override
  State<EditorAutocompleteList> createState() => _EditorAutocompleteListState();
}

class _EditorAutocompleteListState extends State<EditorAutocompleteList> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(EditorAutocompleteList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notifier != widget.notifier) {
      oldWidget.notifier.removeListener(_onChanged);
      widget.notifier.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.notifier.value;
    return Container(
      width: EditorAutocompleteList._width,
      constraints: BoxConstraints.loose(widget.preferredSize),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.borderStrong, width: 0.5),
        boxShadow: DuckTheme.shadowSoft,
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: value.prompts.length,
        itemExtent: EditorAutocompleteList._itemHeight,
        itemBuilder: (context, index) {
          final prompt = value.prompts[index];
          final selected = index == value.index;
          return InkWell(
            onTap: () {
              widget.onSelected(value.copyWith(index: index).autocomplete);
            },
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: selected ? DuckColors.editorLineHighlight : null,
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: _promptSpan(prompt, value.input),
              ),
            ),
          );
        },
      ),
    );
  }

  InlineSpan _promptSpan(CodePrompt prompt, String input) {
    final base = TextStyle(
      fontFamily: DuckTheme.monoFont,
      fontSize: 12,
      color: DuckColors.fgPrimary,
    );
    final word = _highlightInput(
      value: prompt.word,
      input: input,
      baseStyle: base,
    );

    if (prompt is CodeFieldPrompt) {
      return TextSpan(
        children: [
          word,
          TextSpan(
            text: ' ${prompt.type}',
            style: base.copyWith(color: DuckColors.fgMuted),
          ),
        ],
      );
    }
    if (prompt is CodeFunctionPrompt) {
      return TextSpan(
        children: [
          word,
          TextSpan(
            text: '(...) -> ${prompt.type}',
            style: base.copyWith(color: DuckColors.fgMuted),
          ),
        ],
      );
    }
    return word;
  }

  InlineSpan _highlightInput({
    required String value,
    required String input,
    required TextStyle baseStyle,
  }) {
    if (input.isEmpty) return TextSpan(text: value, style: baseStyle);
    final index = value.toLowerCase().indexOf(input.toLowerCase());
    if (index < 0) return TextSpan(text: value, style: baseStyle);
    return TextSpan(
      children: [
        TextSpan(text: value.substring(0, index), style: baseStyle),
        TextSpan(
          text: value.substring(index, index + input.length),
          style: baseStyle.copyWith(
            color: DuckColors.accentCyan,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: value.substring(index + input.length), style: baseStyle),
      ],
    );
  }
}
