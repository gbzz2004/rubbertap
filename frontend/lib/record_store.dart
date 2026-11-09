// Keeps harvest records usable on a farm with weak or no signal.
//
// - The last list loaded from Supabase is saved on the phone, so the
//   Production tab still shows the records without internet.
// - A NEW record saved without internet is kept on the phone ("waiting to
//   send") and sent automatically the next time the app reaches Supabase.
// Editing and deleting need internet (they change records already sent).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

const _cacheKey = 'production_logs_cache_v1';
const _cacheAtKey = 'production_logs_cache_at_v1';
const _pendingKey = 'production_logs_pending_v1';

/// True when [e] means "no internet / server not reachable".
bool isOffline(Object e) {
  if (e is SocketException || e is TimeoutException || e is HttpException) {
    return true;
  }
  final text = e.toString();
  return text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused') ||
      text.contains('Connection closed') ||
      text.contains('Network is unreachable') ||
      text.contains('ClientException');
}

/// A message a farmer can understand, for any error.
String plainError(Object e) => isOffline(e)
    ? 'No internet connection. Please try again when there is signal.'
    : 'Something went wrong. Please try again.';

class RecordStore {
  /// Remember the records last loaded from Supabase.
  static Future<void> saveCache(List<Map<String, dynamic>> logs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(logs));
      await prefs.setString(_cacheAtKey, DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// The remembered records and when they were saved (null if none).
  static Future<(List<Map<String, dynamic>>, DateTime?)> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return (<Map<String, dynamic>>[], null);
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      return (list, DateTime.tryParse(prefs.getString(_cacheAtKey) ?? ''));
    } catch (_) {
      return (<Map<String, dynamic>>[], null);
    }
  }

  /// New records saved on the phone that are not in Supabase yet.
  static Future<List<Map<String, dynamic>>> pending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _savePending(List<Map<String, dynamic>> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKey, jsonEncode(list));
  }

  /// Keep a new record on the phone until it can be sent.
  static Future<void> addPending(Map<String, dynamic> data) async {
    final list = await pending();
    list.add({
      ...data,
      'local_id': DateTime.now().microsecondsSinceEpoch.toString(),
    });
    await _savePending(list);
  }

  /// Send waiting records, oldest first. Stops at the first failure and
  /// keeps the rest. Returns how many were sent.
  static Future<int> syncPending() async {
    final list = await pending();
    var sent = 0;
    while (list.isNotEmpty) {
      final row = Map<String, dynamic>.from(list.first)..remove('local_id');
      try {
        await supabase.from('production_logs').insert(row);
      } catch (_) {
        break;
      }
      list.removeAt(0);
      sent++;
      await _savePending(list);
    }
    return sent;
  }
}
