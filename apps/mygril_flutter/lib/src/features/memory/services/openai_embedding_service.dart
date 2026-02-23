import 'package:http/http.dart' as http;
import '../../../core/network/json_http_client.dart';
import 'embedding_service.dart';

class OpenAIEmbeddingService implements EmbeddingService {
  final String apiKey;
  final String baseUrl;
  final String model;
  final http.Client _client;

  OpenAIEmbeddingService({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'text-embedding-3-small',
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<List<double>> getEmbedding(String text) async {
    final embeddings = await getEmbeddings([text]);
    if (embeddings.isEmpty) {
      throw Exception('Failed to get embedding: Empty response');
    }
    return embeddings.first;
  }

  @override
  Future<List<List<double>>> getEmbeddings(List<String> texts) async {
    final url = Uri.parse('$baseUrl/embeddings');

    try {
      final response = await JsonHttpClient.postJson(
        uri: url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        jsonBody: {
          'input': texts,
          'model': model,
        },
        client: _client,
      );
      final dataList = (response.data['data'] as List?) ?? const [];

      // Ensure the order matches input by sorting by index if necessary,
      // but OpenAI usually returns in order.
      return dataList.map((item) {
        final map = item as Map<String, dynamic>;
        final List<dynamic> embedding = map['embedding'] as List<dynamic>;
        return embedding.map((e) => (e as num).toDouble()).toList();
      }).toList();
    } on JsonHttpRequestException catch (e) {
      if (e.statusCode != null) {
        throw Exception('OpenAI API Error: ${e.statusCode} ${e.responseBody}');
      }
      throw Exception('Failed to connect to Embedding API: $e');
    } catch (e) {
      throw Exception('Failed to connect to Embedding API: $e');
    }
  }
}
