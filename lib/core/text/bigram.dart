/// 中文 bigram 分词（与 SwiftUI 版 `V2Memory.bigram` 行为一致）。
///
/// 规则：
/// - CJK 连续段内相邻两字成词，单字段落保留单字；
/// - 拉丁/数字连续段整体小写作为一个 token；
/// - 其他字符一律视为分隔符。
///
/// 该函数输出直接用于 FTS 索引与关键词命中计算，改动会同时影响
/// "已写入的索引"与"新查询"，必须保持与旧版一致。
library;

/// CJK 判定范围与 Swift 版一致（不含扩展 B 区）。
bool _isCjk(int rune) {
  return (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF);
}

/// Unicode 字母或数字。
///
/// 使用 Unicode 属性转义，尽量等价于 Swift 的 `isLetter || isNumber`。
final RegExp _letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

bool _isLetterOrNumber(int rune) {
  // ASCII 快路径，避免每个字符都走正则
  if ((rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A)) {
    return true;
  }
  return _letterOrNumber.hasMatch(String.fromCharCode(rune));
}

/// 生成 bigram 文本，token 之间以单个空格分隔。
String bigram(String text) {
  final tokens = <String>[];
  final cjkRun = <int>[];
  final wordRun = <int>[];

  void flushCjk() {
    if (cjkRun.length == 1) {
      tokens.add(String.fromCharCode(cjkRun[0]));
    } else if (cjkRun.length > 1) {
      for (var i = 0; i < cjkRun.length - 1; i++) {
        tokens.add(String.fromCharCodes([cjkRun[i], cjkRun[i + 1]]));
      }
    }
    cjkRun.clear();
  }

  void flushWord() {
    if (wordRun.isNotEmpty) {
      tokens.add(String.fromCharCodes(wordRun).toLowerCase());
      wordRun.clear();
    }
  }

  for (final rune in text.runes) {
    if (_isCjk(rune)) {
      flushWord();
      cjkRun.add(rune);
    } else if (_isLetterOrNumber(rune)) {
      flushCjk();
      wordRun.add(rune);
    } else {
      flushCjk();
      flushWord();
    }
  }
  flushCjk();
  flushWord();

  return tokens.join(' ');
}
