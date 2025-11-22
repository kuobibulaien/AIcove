import 'dart:convert';
import 'package:http/http.dart' as http;
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
      final response = await _client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'input': texts,
          'model': model,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final List<dynamic> dataList = data['data'];
        
        // Ensure the order matches input by sorting by index if necessary, 
        // but OpenAI usually returns in order.
        return dataList.map((item) {
          final List<dynamic> embedding = item['embedding'];
          return embedding.map((e) => (e as num).toDouble()).toList();
        }).toList();
      } else {
        throw Exception('OpenAI API Error: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to connect to Embedding API: $e');
    }
  }
}
