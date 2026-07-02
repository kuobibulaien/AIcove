class BackgroundContextSpec {
  final int lastMessages;
  final bool includeUser;
  final bool includeAssistant;
  final bool includeSystem;
  final bool includeTimestamps;

  const BackgroundContextSpec({
    this.lastMessages = 10,
    this.includeUser = true,
    this.includeAssistant = true,
    this.includeSystem = false,
    this.includeTimestamps = false,
  });

  bool includesRole(String role) {
    switch (role.trim().toLowerCase()) {
      case 'user':
        return includeUser;
      case 'assistant':
        return includeAssistant;
      case 'system':
        return includeSystem;
      default:
        return false;
    }
  }

  int get normalizedLastMessages => lastMessages < 1 ? 1 : lastMessages;

  BackgroundContextSpec copyWith({
    int? lastMessages,
    bool? includeUser,
    bool? includeAssistant,
    bool? includeSystem,
    bool? includeTimestamps,
  }) {
    return BackgroundContextSpec(
      lastMessages: lastMessages ?? this.lastMessages,
      includeUser: includeUser ?? this.includeUser,
      includeAssistant: includeAssistant ?? this.includeAssistant,
      includeSystem: includeSystem ?? this.includeSystem,
      includeTimestamps: includeTimestamps ?? this.includeTimestamps,
    );
  }
}
