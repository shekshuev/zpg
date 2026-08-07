class DbConnection {
  final String id;
  final String name;
  final String env;
  final String host;
  final int port;
  final String user;
  final String? password;
  final String database;

  const DbConnection({
    required this.id,
    required this.name,
    this.env = 'local',
    required this.host,
    this.port = 5432,
    required this.user,
    this.password,
    required this.database,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'env': env,
        'host': host,
        'port': port,
        'user': user,
        'password': password,
        'database': database,
      };

  factory DbConnection.fromJson(Map<String, dynamic> json) => DbConnection(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        env: json['env'] ?? 'local',
        host: json['host'] ?? 'localhost',
        port: json['port'] is int
            ? json['port']
            : int.tryParse(json['port'].toString()) ?? 5432,
        user: json['user'] ?? 'postgres',
        password: json['password'],
        database: json['database'] ?? 'postgres',
      );
}
