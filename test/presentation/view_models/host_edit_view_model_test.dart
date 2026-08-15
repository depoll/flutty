// ignore_for_file: public_member_api_docs

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';
import 'package:monkeyssh/domain/models/host_kind.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/presentation/view_models/host_edit_view_model.dart';

HostEditDraft _draft({
  String label = 'Host',
  String hostname = 'example.com',
  String port = '22',
  String username = 'root',
  HostStartupMode startupMode = HostStartupMode.none,
  AutoConnectCommandMode autoConnectMode = AutoConnectCommandMode.none,
  String autoConnectCommand = '',
  String tmuxSession = '',
  String agentTmuxSession = '',
  String agentTmuxExtraFlags = '',
  String portProxyName = '',
  bool autoForwardPorts = false,
  RemoteMuxBackend selectedAgentMuxBackend = RemoteMuxBackend.monkeyMux,
  int? snippetId,
}) => (
  label: label,
  hostKind: HostKind.ssh,
  hostname: hostname,
  port: port,
  username: username,
  password: '',
  tags: '',
  autoConnectCommand: autoConnectCommand,
  tmuxSession: tmuxSession,
  tmuxWorkingDirectory: '',
  tmuxExtraFlags: '',
  agentWorkingDirectory: '',
  agentTmuxSession: agentTmuxSession,
  agentTmuxExtraFlags: agentTmuxExtraFlags,
  agentArguments: '',
  portProxyName: portProxyName,
  selectedAgentMuxBackend: selectedAgentMuxBackend,
  selectedKeyId: null,
  selectedGroupId: null,
  selectedJumpHostId: null,
  skipJumpHostOnSsids: null,
  selectedAutoConnectSnippetId: snippetId,
  selectedLightThemeId: null,
  selectedDarkThemeId: null,
  selectedFontFamily: null,
  selectedStartupMode: startupMode,
  selectedAutoConnectMode: autoConnectMode,
  selectedAgentLaunchTool: AgentLaunchTool.codex,
  isFavorite: false,
  disableTmuxStatusBar: false,
  disableAgentTmuxStatusBar: false,
  startClisInYoloMode: false,
  autoForwardPorts: autoForwardPorts,
);

void main() {
  group('HostEditViewModel', () {
    test('reports stable validation targets and messages', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final viewModel = container.read(
        hostEditViewModelProvider(null).notifier,
      );

      expect(
        viewModel.validateDraft(_draft(label: '')),
        isA<HostEditValidationIssue>()
            .having(
              (issue) => issue.target,
              'target',
              HostEditValidationTarget.label,
            )
            .having(
              (issue) => issue.message,
              'message',
              'Fix label to save this host',
            ),
      );
      expect(
        viewModel.validateDraft(
          _draft(portProxyName: '-invalid', autoForwardPorts: true),
        ),
        isA<HostEditValidationIssue>()
            .having(
              (issue) => issue.target,
              'target',
              HostEditValidationTarget.portProxyName,
            )
            .having(
              (issue) => issue.message,
              'message',
              'Fix proxy domain to save this host',
            ),
      );
      expect(
        viewModel.validateDraft(_draft(portProxyName: '-invalid')),
        isNull,
      );
      expect(
        viewModel.validateDraft(
          _draft(
            startupMode: HostStartupMode.customCommand,
            autoConnectMode: AutoConnectCommandMode.custom,
          ),
        ),
        isA<HostEditValidationIssue>()
            .having(
              (issue) => issue.target,
              'target',
              HostEditValidationTarget.customCommand,
            )
            .having(
              (issue) => issue.message,
              'message',
              'Fix custom command to save this host',
            ),
      );
      expect(
        viewModel.validateDraft(_draft(startupMode: HostStartupMode.monkeyMux)),
        isA<HostEditValidationIssue>()
            .having(
              (issue) => issue.target,
              'target',
              HostEditValidationTarget.tmuxSession,
            )
            .having(
              (issue) => issue.message,
              'message',
              'Fix MonkeyMux session name to save this host',
            ),
      );
      expect(
        viewModel.validateDraft(
          _draft(
            startupMode: HostStartupMode.snippet,
            autoConnectMode: AutoConnectCommandMode.snippet,
          ),
        ),
        isA<HostEditValidationIssue>()
            .having(
              (issue) => issue.target,
              'target',
              HostEditValidationTarget.snippet,
            )
            .having(
              (issue) => issue.message,
              'message',
              'Choose a startup snippet to save this host',
            ),
      );
    });

    test('tracks dirty state from the initial draft boundary', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final viewModel = container.read(
        hostEditViewModelProvider(null).notifier,
      );
      final initialDraft = _draft();

      viewModel.markInitialDraft(initialDraft);

      expect(viewModel.updateDraft(initialDraft), isFalse);
      expect(viewModel.updateDraft(_draft(label: 'Changed')), isTrue);
      expect(container.read(hostEditViewModelProvider(null)).isDirty, isTrue);
    });

    test('maps remote window startup modes to mux backends', () {
      expect(HostStartupMode.muxAuto.remoteMuxBackend, RemoteMuxBackend.auto);
      expect(
        HostStartupMode.monkeyMux.remoteMuxBackend,
        RemoteMuxBackend.monkeyMux,
      );
      expect(HostStartupMode.tmux.remoteMuxBackend, RemoteMuxBackend.tmux);
      expect(HostStartupMode.none.remoteMuxBackend, isNull);
    });
  });

  group('tmux status bar helpers', () {
    test('round trip hidden status bar checkbox flags', () {
      const storedFlags = r'-f ~/.tmux.conf \; set status off';

      expect(hasTmuxDisableStatusBarCommand(storedFlags), isTrue);
      expect(stripTmuxDisableStatusBarCommand(storedFlags), '-f ~/.tmux.conf');
      expect(
        resolveTmuxExtraFlags(
          extraFlags: '-f ~/.tmux.conf',
          disableStatusBar: true,
        ),
        storedFlags,
      );
    });
  });
}
