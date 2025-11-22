import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import '../../../core/api_client.dart';
import '../../../core/app_logger.dart';
import '../../../features/chat/domain/message.dart';
import '../../plugins/memory/memory_config.dart';
import '../models/memory_entity.dart';
import '../repositories/memory_repository.dart';
import 'embedding_service.dart';
import 'openai_embedding_service.dart';

class MemoryService {
  final MemoryConfig config;
  final MemoryRepository _repository;
  late final EmbeddingService _embeddingService;
  final ApiClient _apiClient;

  MemoryService(this.config)
      : _repository = MemoryRepository.instance,
        _apiClient = ApiClient() {
    _embeddingService = OpenAIEmbeddingService(
      apiKey: config.embeddingApiKey,
      baseUrl: config.embeddingBaseUrl,
      model: config.embeddingModel,
    );
  }

  /// Summarize recent conversation and store as memory
  Future<void> summarizeAndStore(List<Message> messages) async {
    if (!config.enabled || messages.isEmpty) return;

    AppLogger.info('MemoryService', 'Starting memory summarization', metadata: {
      'messageCount': messages.length,
    });

    try {
      // 1. Prepare Prompt
      final conversationText = messages.map((m) => '${m.role}: ${m.content}').join('\n');
      final prompt = '${config.summarizePrompt}\n\nConversation:\n$conversationText';

      // 2. Call Summarization LLM
      final summary = await _callSummarizeLLM(prompt);
      if (summary == null || summary.trim().isEmpty || summary.toLowerCase().contains('no key facts')) {
         AppLogger.info('MemoryService', 'No relevant memories found to summarize.');
         return;
      }

      // 3. Split into individual facts (assuming LLM returns one fact per line)
      final facts = LineSplitter.split(summary)
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && !s.startsWith('- ')) // Remove bullet points if any
          .toList();

      if (facts.isEmpty) return;

      // 4. Get Embeddings
      final embeddings = await _embeddingService.getEmbeddings(facts);

      // 5. Store in DB
      for (int i = 0; i < facts.length; i++) {
        final fact = facts[i];
        final embedding = embeddings[i];
        
        final memory = MemoryEntity(
          id: const Uuid().v4(),
          content: fact,
          embedding: embedding,
          createdAt: DateTime.now(),
          importance: 1, // Default importance
        );

        await _repository.addMemory(memory);
        AppLogger.debug('MemoryService', 'Stored memory', metadata: {'content': fact});
      }
      
      AppLogger.info('MemoryService', 'Successfully stored ${facts.length} memories.');

    } catch (e) {
      AppLogger.error('MemoryService', 'Failed to summarize memories', metadata: {'error': e.toString()});
    }
  }

  Future<String?> _callSummarizeLLM(String prompt) async {
    final url = Uri.parse('${config.summarizeBaseUrl}/chat/completions');
    final client = http.Client();
    
    try {
      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.summarizeApiKey}',
        },
        body: jsonEncode({
          'model': config.summarizeModel,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.3,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data['choices'] != null && (data['choices'] as List).isNotEmpty) {
          return data['choices'][0]['message']['content'] as String?;
        }
      } else {
        AppLogger.error('MemoryService', 'LLM Call Failed: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      AppLogger.error('MemoryService', 'LLM Call Failed', metadata: {'error': e.toString()});
    } finally {
      client.close();
    }
    return null;
  }
  
  Future<List<MemoryEntity>> search(String query) async {
    try {
      final embedding = await _embeddingService.getEmbedding(query);
      return await _repository.search(embedding);
    } catch (e) {
      AppLogger.error('MemoryService', 'Search Failed', metadata: {'error': e.toString()});
      return [];
    }
  }
}
