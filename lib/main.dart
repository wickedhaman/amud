import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'features/integrations/platform_runtime.dart';
import 'features/integrations/prayer_links.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hebcal/hebcal.dart';

import 'app.dart';
import 'core/analytics.dart';
import 'core/content.dart';
import 'core/fonts.dart';
import 'core/providers.dart';
import 'core/settings.dart';
import 'core/storage.dart';
import 'core/sync/sync_service.dart';
import 'features/alerts/alerts.dart';
import 'features/alerts/notification_backend.dart';
import 'features/home/card_registry.dart';
import 'features/update/update_service.dart';
import 'features/home/cards/builtin_cards.dart';
import 'features/integrations/seasonal_windows.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_Bootstrap(args: args));
}

/// Shows a first frame immediately, then opens storage and fonts in the
/// background. A slow disk or font load must never leave the phone blank.
class _Bootstrap extends StatefulWidget {
  final List<String> args;
  const _Bootstrap({required this.args});

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  Widget? _ready;
  Object? _error;
  ProviderContainer? _container;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    // Let the loading screen paint before doing any initialization work.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_initialize()));
  }

  Future<void> _initialize() async {
    if (_starting || _ready != null) return;
    _starting = true;
    if (mounted) setState(() => _error = null);
    try {
      if (!kIsWeb) AppLinks();
      initHebcal();
      final storage = await Storage.open();
      Content.attach(storage);

      final registry = CardRegistry();
      registerBuiltInCards(registry);
      registerSeasonalCards(registry);

      final initialLink = widget.args.map(Uri.tryParse).whereType<Uri>().map(routeFromLink).whereType<String>().firstOrNull;
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        cardRegistryProvider.overrideWithValue(registry),
      ]);
      await container.read(fontsProvider.notifier).loadAll();

      final onFlutterError = FlutterError.onError;
      FlutterError.onError = (details) {
        analytics.error(details.exception, fatal: false);
        onFlutterError?.call(details);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        analytics.error(error, fatal: true);
        return false;
      };

      if (!mounted) {
        container.dispose();
        return;
      }
      _container = container;
      setState(() => _ready = UncontrolledProviderScope(
            container: container,
            child: const PlatformRuntime(child: _Lifecycle(child: SiddurApp())),
          ));

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (initialLink != null) openFromOutside(container.read(routerProvider), initialLink);
        final settings = container.read(settingsProvider);
        analytics.trackScreens(container.read(routerProvider));
        analytics.event('app_launch', {'fonts': container.read(fontsProvider).length});
        unawaited(analytics.init(settings, storage));
        Future<void>.delayed(const Duration(seconds: 1), () {
          if (mounted) container.read(alertSchedulerProvider).reschedule();
        });
        container.read(syncProvider);
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) container.read(syncProvider.notifier).syncNow();
        });
        Future<void>.delayed(const Duration(seconds: 5), () {
          if (mounted) container.read(updateProvider.notifier).autoCheck();
        });
        Future<void>.delayed(const Duration(seconds: 8), () {
          if (mounted) checkContentUpdates(storage);
        });
      });
    } catch (e, stack) {
      debugPrint('Amud startup: $e\\n$stack');
      if (mounted) setState(() => _error = e);
    } finally {
      _starting = false;
    }
  }

  @override
  void dispose() {
    _container?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready != null) return _ready!;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: _error == null
                ? const Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    SizedBox(height: 14),
                    Text('Loading Amud'),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Amud could not finish starting.'),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: () => unawaited(_initialize()), child: const Text('Try again')),
                  ]),
          ),
        ),
      ),
    );
  }
}

/// Re-plans notifications when the app returns to the foreground (dates,
/// DST and the 64-notification iOS window move on).
class _Lifecycle extends ConsumerStatefulWidget {
  final Widget child;
  const _Lifecycle({required this.child});

  @override
  ConsumerState<_Lifecycle> createState() => _LifecycleState();
}

class _LifecycleState extends ConsumerState<_Lifecycle> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _taps = notificationTaps.stream.listen((route) {
      analytics.event('alert_tap', {'route': route});
      ref.read(routerProvider).go(route);
    });
  }

  StreamSubscription<String>? _taps;

  @override
  void dispose() {
    _taps?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      analytics.event('app_resume');
      analytics.checkIn();
      ref.invalidate(nowProvider);
      ref.read(alertSchedulerProvider).reschedule();
      ref.read(syncProvider.notifier).syncNow();
      // Back from the "Install unknown apps" setting during an update.
      ref.read(updateProvider.notifier).resumed();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
