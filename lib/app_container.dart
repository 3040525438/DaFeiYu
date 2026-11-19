/// 依赖装配单点（对齐 SwiftUI 版 AppContainer）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'ai/diary_auto_service.dart';
import 'ai/memory_extraction_coordinator.dart';
import 'ai/recall_context_builder.dart';
import 'core/backup/backup_cipher.dart';
import 'core/backup/backup_service.dart';
import 'core/import/astrbot_importer.dart';
import 'core/time/current_time_context.dart';
import 'core/time/local_day.dart';
import 'data/db/app_database.dart';
import 'data/repositories/config_repositories.dart';
import 'data/repositories/conversation_repository.dart';
import 'data/repositories/diary_repository.dart';
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
    required this.diaries,
    required this.diaryAuto,
    required this.chat,
    required this.backup,
    required this.astrbot,
    required this.secureStorage,
  });

  final AppDatabase database;
  final ConversationRepository conversations;
  final MessageRepository messages;
  final ModelConfigRepository modelConfigs;
  final PersonaRepository personas;
  final MemoryRepository memories;
  final DiaryRepository diaries;
  final DiaryAutoService diaryAuto;
  final ChatOrchestrator chat;
  final BackupService backup;
  final AstrBotImporter astrbot;
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
    final diaries = DiaryRepository(database);
    final recall = RecallContextBuilder(database, memories, diaryLinesProvider: (DayRange? range) => _diaryLines(diaries, range));
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
    final diaryAuto = DiaryAutoService(database, diaries);
    final backup = BackupService(
      database: database,
      keyStore: SecureStorageKeyStore(storage: secureStorage),
    );
    final astrbot = AstrBotImporter(database);
    return AppContainer._(
      database: database,
      conversations: conversations,
      messages: messages,
      modelConfigs: modelConfigs,
      personas: personas,
      memories: memories,
      diaries: diaries,
      diaryAuto: diaryAuto,
      chat: chat,
      backup: backup,
      astrbot: astrbot,
      secureStorage: secureStorage,
    );
  }

  /// 日记召回钩子：默认取最近一周，最多 5 条（与原版 diaryLines 口径一致）。
  static Future<List<String>> _diaryLines(DiaryRepository diaries, DayRange? range) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final endKey = range?.end ?? DiaryAutoService.dayKeyFromMillis(now);
    final startKey = range?.start ?? _daysBefore(endKey, 6);
    return diaries.recallLines(startKey, endKey);
  }

  /// endKey 往前推 [days] 天的日期键。
  static String _daysBefore(String endKey, int days) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(endKey);
    if (match == null) return endKey;
    final date = DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
    return dayKey(addDays(date, -days));
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
