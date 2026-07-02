library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ImageProviderRequest {
  const ImageProviderRequest({
    required this.provider,
    required this.model,
    required this.prompt,
    required this.width,
    required this.height,
    required this.count,
    required this.baseUrl,
    required this.apiKey,
    this.negativePrompt,
    this.steps,
    this.guidanceScale,
    this.seed,
    this.sampler,
    this.customConfig,
  });

  final String provider;
  final String model;
  final String prompt;
  final String? negativePrompt;
  final int width;
  final int height;
  final int count;
  final int? steps;
  final double? guidanceScale;
  final int? seed;
  final String? sampler;
  final String baseUrl;
  final String apiKey;
  final Map<String, dynamic>? customConfig;
}

class ImageProviderResponse {
  const ImageProviderResponse({
    required this.images,
    this.rawResponse,
  });

  final List<Uint8List> images;
  final Map<String, dynamic>? rawResponse;
}

abstract class ImageProviderAdapter {
  String get name;

  Future<ImageProviderResponse> generate({
    required http.Client client,
    required Duration timeout,
    required ImageProviderRequest request,
  });
}
