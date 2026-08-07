import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'app/theme.dart';
import 'shared/models/db_connection.dart';
import 'features/launcher/launcher_screen.dart';
import 'features/studio/studio_screen.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final windowController = await WindowController.fromCurrentEngine();
  final rawArgs = windowController.arguments;

  if (rawArgs.isNotEmpty) {
    final connData = DbConnection.fromJson(jsonDecode(rawArgs));
    runApp(
      MaterialApp(
        title: 'zpg Studio — ${connData.name}',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.studioDarkTheme,
        home: StudioScreen(
          windowId: windowController.windowId,
          connection: connData,
        ),
      ),
    );
    return;
  }

  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(720, 480),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    skipTaskbar: false,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.setMinimizable(false);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    MaterialApp(
      title: 'zpg Studio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const LauncherScreen(),
    ),
  );
}
