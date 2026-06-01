import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/aac_symbol.dart';
import '../providers/board_provider.dart';
import '../widgets/symbol_image.dart';

/// Lets the user assign any catalog symbol to each of the six board slots.
///
/// Slots are laid out the same way as the board grid (3 × 2), so the position
/// of a slot in this screen matches where it will appear on the AAC board.
/// Tapping a slot opens a bottom sheet listing the full catalog. Selection is
/// persisted by [BoardProvider] immediately on change.
class BoardEditorScreen extends StatelessWidget {
  const BoardEditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final board = context.watch<BoardProvider>();
    final selected = board.symbols;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        title: const Text('Edit Board'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.restore, color: Colors.orangeAccent),
            label: const Text(
              'Reset',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 14),
            ),
            onPressed: () async {
              await context.read<BoardProvider>().resetToDefault();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Board reset to defaults')),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tap a slot to change which symbol it shows.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.2,
                ),
                itemCount: boardSlotCount,
                itemBuilder: (context, index) {
                  return _SlotCard(
                    slotIndex: index,
                    symbol: selected[index],
                    onTap: () => _pickSymbol(context, index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSymbol(BuildContext context, int slotIndex) async {
    final board = context.read<BoardProvider>();
    final currentId = board.selectedIds[slotIndex];

    // Map id → slot number for any symbol already on the board *other* than
    // this slot's own. Used to disable duplicates in the picker.
    final usedElsewhere = <String, int>{
      for (var i = 0; i < board.selectedIds.length; i++)
        if (i != slotIndex) board.selectedIds[i]: i,
    };

    final pickedId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF16213E),
      isScrollControlled: true,
      builder: (sheetCtx) {
        return _CatalogPicker(
          catalog: board.catalog,
          currentId: currentId,
          usedElsewhere: usedElsewhere,
        );
      },
    );

    if (pickedId != null) {
      await board.setSlot(slotIndex, pickedId);
    }
  }
}

class _SlotCard extends StatelessWidget {
  final int slotIndex;
  final AacSymbol symbol;
  final VoidCallback onTap;

  const _SlotCard({
    required this.slotIndex,
    required this.symbol,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: symbol.color.withValues(alpha: 0.5), width: 2),
        ),
        padding: const EdgeInsets.all(10),
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${slotIndex + 1}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: Icon(Icons.edit, size: 14, color: Colors.white38),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SymbolImage(symbol: symbol, size: 44),
                  const SizedBox(height: 6),
                  Text(
                    symbol.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    symbol.category,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
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

class _CatalogPicker extends StatelessWidget {
  final List<AacSymbol> catalog;
  final String currentId;

  /// Symbol ids already on the board in other slots, mapped to those slot
  /// indices. These entries are rendered disabled so the user can't put the
  /// same word in two places.
  final Map<String, int> usedElsewhere;

  const _CatalogPicker({
    required this.catalog,
    required this.currentId,
    required this.usedElsewhere,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Choose a symbol',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: catalog.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Colors.white12),
                itemBuilder: (ctx, i) {
                  final s = catalog[i];
                  final isCurrent = s.id == currentId;
                  final usedSlot = usedElsewhere[s.id];
                  final isDisabled = usedSlot != null;
                  return ListTile(
                    enabled: !isDisabled,
                    leading: Opacity(
                      opacity: isDisabled ? 0.4 : 1.0,
                      child: SymbolImage(symbol: s, size: 36),
                    ),
                    title: Text(
                      s.label,
                      style: TextStyle(
                        color: isDisabled ? Colors.white38 : Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      isDisabled
                          ? 'Already on slot ${usedSlot + 1}'
                          : s.category,
                      style: TextStyle(
                        color: isDisabled ? Colors.white24 : Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    trailing: isCurrent
                        ? const Icon(Icons.check, color: Colors.cyanAccent)
                        : null,
                    onTap: isDisabled ? null : () => Navigator.pop(ctx, s.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
