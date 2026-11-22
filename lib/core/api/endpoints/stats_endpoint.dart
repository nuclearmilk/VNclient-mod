import '../../models/stats.dart';
import '../vndb_client.dart';

/// Encapsulates the `GET /stats` endpoint.
class StatsEndpoint {
  StatsEndpoint(this.client);

  final VndbClient client;

  Future<Map<String, dynamic>> getStatsRaw() {
    return client.get('/stats');
  }

  Future<Stats> getStats() async {
    final json = await getStatsRaw();
    return Stats.fromJson(json);
  }
}
