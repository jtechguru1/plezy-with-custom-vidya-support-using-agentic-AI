import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../profiles/profile_registry.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'connection_persistence.dart';

/// Two-step form to add a VIDYA server:
///   1. Enter server URL + username + password.
///   2. Authenticate via `POST /api/auth/token`.
///   3. Persist via [ConnectionRegistry] and bind to the active profile.
class AddVidyaScreen extends StatefulWidget {
  final Profile? targetProfile;

  const AddVidyaScreen({super.key, this.targetProfile});

  @override
  State<AddVidyaScreen> createState() => _AddVidyaScreenState();
}

class _AddVidyaScreenState extends State<AddVidyaScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _urlFocus = FocusNode(debugLabel: 'AddVidya:Url');
  final _usernameFocus = FocusNode(debugLabel: 'AddVidya:Username');
  final _passwordFocus = FocusNode(debugLabel: 'AddVidya:Password');
  final _signInFocus = FocusNode(debugLabel: 'AddVidya:SignIn');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _urlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _signInFocus.dispose();
    super.dispose();
  }

  String _normalizeUrl(String input) {
    var url = input.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    return url;
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await runAsync<void>(
      () async {
        final normalizedUrl = _normalizeUrl(_urlController.text);
        final username = _usernameController.text.trim();
        final password = _passwordController.text;

        final uri = Uri.parse('$normalizedUrl/api/auth/token');
        final response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'username': username, 'password': password}),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode != 200) {
          throw Exception('Server returned ${response.statusCode}');
        }

        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final token = json['token'] as String? ?? '';
        if (token.isEmpty) throw Exception('No token in response');

        final user = json['user'] as Map<String, dynamic>? ?? {};
        final userId = (user['id'] ?? '').toString();
        final userName = user['username'] as String? ?? username;
        final authority = Uri.tryParse(normalizedUrl)?.authority ?? '';
        final serverName = authority.isNotEmpty ? authority : 'VIDYA';

        final now = DateTime.now();
        final connection = VidyaAccountConnection(
          id: 'vidya-${const Uuid().v4()}',
          baseUrl: normalizedUrl,
          serverName: serverName,
          userId: userId,
          userName: userName,
          accessToken: token,
          createdAt: now,
          lastAuthenticatedAt: now,
        );

        if (!mounted) return;
        await _persistAndExit(connection);
      },
      errorMapper: (e) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        return 'Sign in failed: $msg';
      },
    );
  }

  Future<void> _persistAndExit(VidyaAccountConnection connection) async {
    if (!mounted) return;
    final activeProvider = context.read<ActiveProfileProvider>();
    await activeProvider.initialize();
    if (!mounted) return;

    final targetProfile = widget.targetProfile;
    var boundProfile = targetProfile ?? activeProvider.active;

    if (boundProfile == null) {
      final now = DateTime.now();
      final profile = Profile.local(
        id: 'local-${const Uuid().v4()}',
        displayName: connection.userName.isNotEmpty ? connection.userName : connection.serverName,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
      );
      await context.read<ProfileRegistry>().upsert(profile);
      await activeProvider.activate(profile);
      if (!mounted) return;
      boundProfile = activeProvider.active ?? profile;
    }

    final bindProfile = boundProfile;
    final boundToActive = bindProfile.id == activeProvider.activeId;

    await persistAndBindConnection(
      context: context,
      connection: connection,
      bindToProfile: ProfileConnection(
        profileId: bindProfile.id,
        connectionId: connection.id,
        userToken: connection.accessToken,
        userIdentifier: connection.userId,
        tokenAcquiredAt: DateTime.now(),
      ),
      addToManager: null,
    );

    if (!mounted) return;
    if (boundToActive) {
      await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: const Text('Connect to VIDYA'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FocusableTextFormField(
                    controller: _urlController,
                    focusNode: _urlFocus,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _usernameFocus.requestFocus(),
                    onNavigateDown: () => _usernameFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.x:31415',
                      prefixIcon: AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _usernameController,
                    focusNode: _usernameFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
                    onNavigateUp: () => _urlFocus.requestFocus(),
                    onNavigateDown: () => _passwordFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: AppIcon(Symbols.person_rounded, fill: 1),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: true,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => unawaited(_signIn()),
                    onNavigateUp: () => _usernameFocus.requestFocus(),
                    onNavigateDown: () => _signInFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: AppIcon(Symbols.lock_rounded, fill: 1),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FocusableButton(
                    focusNode: _signInFocus,
                    useBackgroundFocus: true,
                    onNavigateUp: () => _passwordFocus.requestFocus(),
                    onPressed: busy ? null : () => unawaited(_signIn()),
                    child: FilledButton.icon(
                      onPressed: busy ? null : () => unawaited(_signIn()),
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
                      label: const Text('Sign in'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
