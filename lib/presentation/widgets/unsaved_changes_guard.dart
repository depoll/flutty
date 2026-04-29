import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Blocks route pops while a page has unsaved changes.
class UnsavedChangesGuard extends StatefulWidget {
  /// Creates a guard that asks for confirmation before discarding changes.
  const UnsavedChangesGuard({
    required this.hasUnsavedChanges,
    required this.child,
    this.title = 'Discard changes?',
    this.message =
        'You have unsaved changes. If you leave now, those changes will be lost.',
    this.keepEditingLabel = 'Keep editing',
    this.discardLabel = 'Discard',
    super.key,
  });

  /// Whether leaving the current route would discard unsaved user changes.
  final bool hasUnsavedChanges;

  /// The guarded page content.
  final Widget child;

  /// Dialog title shown when the user tries to leave.
  final String title;

  /// Dialog body shown when the user tries to leave.
  final String message;

  /// Label for the action that keeps the user on the page.
  final String keepEditingLabel;

  /// Label for the destructive action that discards changes.
  final String discardLabel;

  @override
  State<UnsavedChangesGuard> createState() => _UnsavedChangesGuardState();
}

class _UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  bool _allowNextPop = false;
  bool _isShowingPrompt = false;

  bool get _canPop => _allowNextPop || !widget.hasUnsavedChanges;

  @override
  void didUpdateWidget(covariant UnsavedChangesGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hasUnsavedChanges && _allowNextPop) {
      _allowNextPop = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop || _canPop || _isShowingPrompt) {
        return;
      }
      unawaited(_confirmDiscardAndPop());
    },
    child: widget.child,
  );

  Future<void> _confirmDiscardAndPop() async {
    _isShowingPrompt = true;
    final shouldDiscard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.title),
        content: Text(widget.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(widget.keepEditingLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(widget.discardLabel),
          ),
        ],
      ),
    );
    _isShowingPrompt = false;

    if (!mounted || shouldDiscard != true) {
      return;
    }

    setState(() => _allowNextPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_popGuardedRoute());
      });
    });
  }

  Future<void> _popGuardedRoute() async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop();
      return;
    }
    await navigator.maybePop();
  }
}
