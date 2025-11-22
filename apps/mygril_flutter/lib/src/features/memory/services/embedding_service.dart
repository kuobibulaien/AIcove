abstract class EmbeddingService {
  /// Get embedding for a single text
  Future<List<double>> getEmbedding(String text);

  /// Get embeddings for multiple texts (batch)
  Future<List<List<double>>> getEmbeddings(List<String> texts);
}
