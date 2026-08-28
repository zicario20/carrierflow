import 'dart:async';

import 'package:carrierflow_driver/core/bootstrap/driver_bootstrap.dart';
import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:carrierflow_driver/features/auth/auth_gate.dart';
import 'package:carrierflow_driver/features/tracking/tracking_background_work.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void carrierFlowTrackingBackgroundDispatcher() {
  Workmanager().executeTask((taskName, _) async {
    if (taskName != carrierFlowTrackingBackgroundWorkName) return true;
    return DriverBootstrap.runBackgroundTrackingWorkFromEnvironment();
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerCarrierFlowDriverPushBackgroundHandler();
  try {
    await Workmanager().initialize(carrierFlowTrackingBackgroundDispatcher);
  } on Object {
    // Android/iOS may decline initialization. The UI describes tracking as
    // best effort and the runtime never falls back to a background Dart timer.
  }
  final bootstrap = await DriverBootstrap.initializeFromEnvironment();
  runApp(CarrierFlowDriverApp(bootstrap: bootstrap));
}

class CarrierFlowDriverApp extends StatefulWidget {
  const CarrierFlowDriverApp({this.bootstrap, super.key});

  final DriverBootstrap? bootstrap;

  @override
  State<CarrierFlowDriverApp> createState() => _CarrierFlowDriverAppState();
}

class _CarrierFlowDriverAppState extends State<CarrierFlowDriverApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final syncLifecycle = widget.bootstrap?.syncLifecycle;
    if (syncLifecycle != null) unawaited(syncLifecycle.resume());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final syncLifecycle = widget.bootstrap?.syncLifecycle;
      if (syncLifecycle != null) unawaited(syncLifecycle.resume());
    }
    final trackingLifecycle = widget.bootstrap?.trackingLifecycle;
    if (trackingLifecycle != null) {
      unawaited(
        trackingLifecycle.updateAppVisibility(
          state == AppLifecycleState.resumed,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.bootstrap?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff2563eb),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xff2563eb),
          secondary: const Color(0xff3b82f6),
          tertiary: const Color(0xffea580c),
          surface: const Color(0xfff8fafc),
        );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => DriverStrings.of(context).appName,
      supportedLocales: const <Locale>[Locale('en'), Locale('es')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        DriverStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff8fafc),
        appBarTheme: const AppBarTheme(centerTitle: false),
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2563eb),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: AuthGate(
        authStateChanges:
            widget.bootstrap?.authStateChanges ??
            Stream<DriverSessionState>.value(const DriverSessionSignedOut()),
        ownAssignedLoadRepository:
            widget.bootstrap?.ownAssignedLoadRepository ??
            const SafeEmptyOwnAssignedLoadRepository(),
        ownLoadExecutionRepository:
            widget.bootstrap?.ownLoadExecutionRepository,
        loadStateSyncReconciler: widget.bootstrap?.loadStateSyncReconciler,
        pushRefreshService: widget.bootstrap?.pushRefreshService,
        trackingLifecycle: widget.bootstrap?.trackingLifecycle,
      ),
    );
  }
}
