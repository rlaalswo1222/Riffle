import 'package:flutter/material.dart';

import 'app_info.dart';
import 'screens/library_screen.dart';
import 'ui/toss.dart';

void main() => runApp(const BarLinkApp());

class BarLinkApp extends StatelessWidget {
  const BarLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: Toss.theme(),
      home: const LibraryScreen(),
    );
  }
}
