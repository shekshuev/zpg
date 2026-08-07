import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import '../../shared/models/db_connection.dart';

class LauncherScreen extends StatefulWidget {
  const LauncherScreen({super.key});

  @override
  State<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends State<LauncherScreen> {
  String _searchQuery = '';

  final List<DbConnection> _connections = const [
    DbConnection(
      id: '1',
      name: 'local',
      env: 'local',
      host: 'localhost',
      port: 5432,
      user: 'postgres',
      database: 'postgres',
    ),
    DbConnection(
      id: '2',
      name: 'production_replica',
      env: 'prod',
      host: 'db.internal.zpg.io',
      port: 5432,
      user: 'readonly',
      database: 'main_db',
    ),
  ];

  Future<void> _spawnStudioWindow(DbConnection conn) async {
    final controller = await WindowController.create(
      WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: jsonEncode(conn.toJson()),
      ),
    );

    await controller.show();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _connections.where((c) {
      final q = _searchQuery.toLowerCase();
      return c.name.toLowerCase().contains(q) ||
          c.host.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          Container(
            width: 260,
            color: const Color(0xFF28282D),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: const Color(0xFF10B981).withValues(alpha: 0.3),
                        width: 2),
                  ),
                  child: const Icon(Icons.bolt_rounded,
                      size: 48, color: Color(0xFF10B981)),
                ),
                const SizedBox(height: 12),
                const Text('zpg Studio',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const Text('Version 0.1.0',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 38,
                  child: ElevatedButton.icon(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3A3A42),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(19)),
                    ),
                    icon: const Icon(Icons.power_input_rounded, size: 16),
                    label: const Text('Create Connection',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    height: 32,
                    child: TextField(
                      onChanged: (val) => setState(() => _searchQuery = val),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Search for connection...',
                        prefixIcon: const Icon(Icons.search,
                            size: 16, color: Colors.grey),
                        contentPadding: EdgeInsets.zero,
                        fillColor: const Color(0xFF141416),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final conn = filtered[index];
                        final isLocal = conn.env == 'local';

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              onTap: () => _spawnStudioWindow(conn),
                              leading: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: const Text('Pg',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white)),
                              ),
                              title: Row(
                                children: [
                                  Text(conn.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13)),
                                  const SizedBox(width: 6),
                                  Text(
                                    '(${conn.env})',
                                    style: TextStyle(
                                      color: isLocal
                                          ? const Color(0xFF10B981)
                                          : Colors.amber,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                  '${conn.host}:${conn.port} • ${conn.user}',
                                  style: const TextStyle(
                                      color: Colors.grey, fontSize: 11)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
