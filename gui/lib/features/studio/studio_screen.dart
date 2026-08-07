import 'package:flutter/material.dart';
import '../../shared/models/db_connection.dart';

class StudioScreen extends StatelessWidget {
  final String windowId;
  final DbConnection connection;

  const StudioScreen({
    super.key,
    required this.windowId,
    required this.connection,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
        backgroundColor: const Color(0xFF16181D),
        titleSpacing: 12,
        title: Row(
          children: [
            Text('zpg Studio — ${connection.name}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                  color: Color(0xFF10B981), shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Text('${connection.host}:${connection.port}/${connection.database}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
      body: Row(
        children: [
          Container(
            width: 220,
            color: const Color(0xFF16181D),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('TABLES',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.table_chart_outlined,
                            size: 16, color: Colors.grey),
                        title:
                            const Text('users', style: TextStyle(fontSize: 13)),
                        onTap: () {},
                      ),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.table_chart_outlined,
                            size: 16, color: Colors.grey),
                        title: const Text('orders',
                            style: TextStyle(fontSize: 13)),
                        onTap: () {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  flex: 4,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    child: const TextField(
                      maxLines: null,
                      expands: true,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 13),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: 'SELECT * FROM users LIMIT 100;',
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  flex: 6,
                  child: Container(
                    color: const Color(0xFF0F1115),
                    child: Center(
                      child: Text(
                        'Data Grid Placeholder (Window: $windowId)',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
