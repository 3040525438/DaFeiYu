/// 依赖装配单点（对齐 SwiftUI 版 AppContainer）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'ai/memory_extraction_coordinator.dart';
import 'ai/recall_context_builder.dart';
import 'data/db/app_database.dart';
import 'data/repositories/config_repositories.dart';
import 'data/repositories/conversation_repository.dart';
import 'data/repositories/memory_repository.dart';
import 'data/repositories/message_repository.dart';
import 'features/chat/chat_orchestrator.dart';

/// 应用级依赖容器。
class AppContainer extends ChangeNotifier {
  AppContainer._({
    required this.database,
    required this.conversations,
    required this.messages,
    required this.modelConfigs,
    required this.personas,
    required this.memories,
    required this.chat,
    required this.secureStorage,
  });

  final AppDatabase database;
  final ConversationRepository conversations;
  final MessageRepository messages;
  final ModelConfigRepository modelConfigs;
  final PersonaRepository personas;
  final MemoryRepository memories;
  final ChatOrchestrator chat;
  final FlutterSecureStorage secureStorage;

  static Future<AppContainer> create() async {
    final dir = await getApplicationDocumentsDirectory();
    final database = await AppDatabase.open(dir.path);
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final conversations = ConversationRepository(database);
    final messages = MessageRepository(database);
    final modelConfigs = ModelConfigRepository(database);
    final personas = PersonaRepository(database);
    final memories = MemoryRepository(database);
    final recall = RecallContextBuilder(database, memories);
    final extraction = MemoryExtractionCoordinator(database);
    final chat = ChatOrchestrator(
      conversations: conversations,
      messages: messages,
      modelConfigs: modelConfigs,
      personas: personas,
      memories: memories,
      extraction: extraction,
      recallBuilder: recall,
      secureRead: (String keyRef) => secureStorage.read(key: keyRef),
    );
    return AppContainer._(
      database: database,
      conversations: conversations,
      messages: messages,
      modelConfigs: modelConfigs,
      personas: personas,
      memories: memories,
      chat: chat,
      secureStorage: secureStorage,
    );
  }

  /// 写入 API 密钥到安全存储。
  Future<void> saveApiKey(String keyRef, String apiKey) async {
    await secureStorage.write(key: keyRef, value: apiKey);
  }

  /// 读取 API 密钥。
  Future<String?> readApiKey(String keyRef) async {
    return secureStorage.read(key: keyRef);
  }

  @override
  void dispose() {
    database.close();
    super.dispose();
  }
}
