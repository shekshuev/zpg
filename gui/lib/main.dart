import 'package:flutter/material.dart';
import 'shared/ffi/engine.dart';

void main() {
  runApp(const ZpgApp());
}

class ZpgApp extends StatelessWidget {
  const ZpgApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'zpg Studio',
      debugShowCheckedModeBanner: false,
      home: ZpgMainScreen(),
    );
  }
}

class ZpgMainScreen extends StatefulWidget {
  const ZpgMainScreen({super.key});

  @override
  State createState() => _ZpgMainScreenState();
}

class _ZpgMainScreenState extends State {
  int? _result;

  void _callZig() {
    setState(() {
      _result = zpgTestAdd(40, 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('zpg Studio',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Answer from Zig: ${_result ?? "empty"}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _callZig,
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child:
                  const Text('40 + 2 via FFI', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
